# OpsWarden Ops — runner unique du repo (infra). Convention projet : ops = Make,
# app/web = Just (un seul runner par repo, jamais deux empilés).
# Cycle de vie : provision -> deploy -> harden -> verify -> destroy.
# Inclut aussi la qualité (fmt / validate / lint), repliée ici depuis l'ex-Justfile.
#
# Démarrage rapide (depuis ce dossier) :
#   cp .env.example .env && $EDITOR .env   # poser DIGITALOCEAN_TOKEN
#   nix develop                            # ou: export $(grep -v '^#' .env | xargs)
#   make all                               # infra + deploy (couche prête)
#   make hosts && make smoke               # DNS local + smoke test
#
# Placeholder : les services applicatifs (server/client-web/investigation/worker)
# ne sont pas encore déployés. `deploy` n'applique que la couche prête
# (observability + postgres + redis + traefik) ; la couche app est commentée.

# Recettes POSIX sh (pas de dépendance dure à /bin/bash : NixOS / images minimales).
TF_DIR         := terraform
# Kubeconfig par défaut : ~/.kube/config (ce que minikube, kubectl et k9s utilisent).
# DOKS est le cas particulier : Terraform écrit ./kubeconfig, utilisé par all/infra.
KUBECONFIG     ?= $(HOME)/.kube/config
export KUBECONFIG
DOKS_KUBECONFIG := $(CURDIR)/kubeconfig

# minikube écrit son contexte dans ~/.kube/config (le défaut). 2 nœuds reflètent
# DOKS pour que l'anti-affinity required (2 replicas) marche tel quel.
MINIKUBE_NODES ?= 2

# Hôtes publics (placeholders : .example ne résout pas, mappé via /etc/hosts).
WEB_HOST ?= app.opswarden.example
API_HOST ?= api.opswarden.example

# Manifests groupés par phase de déploiement.
MONITORING := k8s/observability/cadvisor.daemonset.yaml
DATA       := k8s/postgres/postgres.configmap.yaml \
              k8s/postgres/postgres.volume.yaml k8s/postgres/postgres.sa.yaml \
              k8s/postgres/postgres.deployment.yaml k8s/postgres/postgres.service.yaml \
              k8s/redis/redis.configmap.yaml k8s/redis/redis.sa.yaml \
              k8s/redis/redis.deployment.yaml k8s/redis/redis.service.yaml
LB         := k8s/traefik/traefik.ingressclass.yaml k8s/traefik/traefik.rbac.yaml \
              k8s/traefik/traefik.deployment.yaml k8s/traefik/traefik.service.yaml
# Couche app (placeholders) — décommenter au fil des images publiées :
# APP      := k8s/server/ k8s/client-web/ k8s/investigation/ k8s/worker/
READY_MANIFESTS := $(MONITORING) $(DATA) $(LB)
K8S_MANIFESTS := $(shell find k8s -name '*.yaml' ! -name '*.sops.yaml' | sort)

.DEFAULT_GOAL := help
.PHONY: help all infra kubeconfig deploy db-check hosts smoke status destroy \
        fmt fmt-check validate dry-run tf-lint check-plaintext-secret-manifests \
        secrets-dry-run secrets-apply \
        metrics hpa pdb load harden soft-affinity hard-affinity \
        minikube minikube-up minikube-deploy minikube-hosts minikube-smoke minikube-down

help: ## Affiche cette aide
	@echo "OpsWarden Ops — cibles make :"
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

all: infra ## DOKS : provisionne le cluster puis déploie la couche prête
	$(MAKE) deploy KUBECONFIG=$(DOKS_KUBECONFIG)

## --- Cœur ------------------------------------------------------------------

infra: ## Provisionne le cluster DOKS via Terraform (écrit ./kubeconfig)
	cd $(TF_DIR) && terraform init -input=false && terraform apply -auto-approve
	@echo ">> Attente des nœuds Ready..."
	KUBECONFIG=$(DOKS_KUBECONFIG) kubectl wait --for=condition=Ready nodes --all --timeout=300s

kubeconfig: ## (Re)génère ./kubeconfig depuis l'état Terraform
	cd $(TF_DIR) && terraform apply -auto-approve -target=local_file.kubeconfig

deploy: ## Applique la couche prête (observability + data + traefik), dans l'ordre
	@bash -c 'set -euo pipefail; \
	if [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ]; then \
		echo ">> Erreur: EXPECTED_CONTEXT et NAMESPACE doivent être définis (ex: EXPECTED_CONTEXT=minikube NAMESPACE=default)"; \
		exit 1; \
	fi; \
	CTX=$$(kubectl config current-context); \
	if [ "$$CTX" != "$$EXPECTED_CONTEXT" ]; then \
		echo ">> Erreur: Le contexte courant ($$CTX) ne correspond pas au contexte attendu ($$EXPECTED_CONTEXT)"; \
		exit 1; \
	fi; \
	if ! kubectl --context "$$EXPECTED_CONTEXT" --namespace "$$NAMESPACE" get secret postgres-secret >/dev/null 2>&1; then \
		echo ">> ERREUR: Le secret postgres-secret est introuvable sur le cluster."; \
		echo ">> Veuillez appliquer le secret SOPS avant de déployer :"; \
		echo ">>   make secrets-dry-run EXPECTED_CONTEXT=$$EXPECTED_CONTEXT NAMESPACE=$$NAMESPACE"; \
		echo ">>   make secrets-apply EXPECTED_CONTEXT=$$EXPECTED_CONTEXT NAMESPACE=$$NAMESPACE CONFIRM=APPLY_POSTGRES_SECRET"; \
		exit 1; \
	fi'
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply -f $(MONITORING)
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply $(addprefix -f ,$(DATA))
	@echo ">> Attente de postgres & redis..."
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" rollout status deploy/postgres --timeout=180s
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" rollout status deploy/redis --timeout=120s
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public apply $(addprefix -f ,$(LB))
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public rollout status deploy/traefik --timeout=120s
	@echo ">> Couche app (server/client-web/investigation/worker) : placeholders, non déployée."

db-check: ## Vérifie la connectivité Postgres (le schéma est géré par opswarden-server)
	@POD=$$(kubectl get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}'); \
	echo ">> Test connexion sur le pod $$POD"; \
	kubectl exec -i $$POD -c postgres -- sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -c "SELECT 1;"'

hosts: ## Mappe l'IP d'un nœud -> hôtes web/api dans /etc/hosts (sudo)
	@NODES=$$(kubectl get nodes -o jsonpath='{ $$.items[*].status.addresses[?(@.type=="ExternalIP")].address }'); \
	IP=$$(echo $$NODES | awk '{print $$1}'); \
	echo ">> $$IP -> $(WEB_HOST) $(API_HOST)"; \
	echo "$$IP $(WEB_HOST) $(API_HOST)" | sudo tee -a /etc/hosts

smoke: ## Smoke test bout-en-bout (Traefik + routes app best-effort)
	WEB_HOST=$(WEB_HOST) API_HOST=$(API_HOST) ./scripts/smoke.sh

status: ## État du cluster (pods / services / ingress, namespaces utiles)
	kubectl get pods -o wide
	kubectl get svc,ingress
	kubectl -n kube-public get pods,svc -o wide
	kubectl -n kube-system get ds cadvisor

destroy: ## Détruit le cluster DOKS
	cd $(TF_DIR) && terraform destroy -auto-approve

## --- Qualité (ex-Justfile, ce que vérifie la CI) ---------------------------

fmt: ## Formate yaml/md/json (prettier) + terraform fmt
	npx --yes prettier --write "**/*.{yaml,yml,md,json}"
	terraform -chdir=$(TF_DIR) fmt

fmt-check: ## Vérifie le formatage sans rien modifier (miroir CI)
	npx --yes prettier --check "**/*.{yaml,yml,md,json}"
	terraform -chdir=$(TF_DIR) fmt -check

validate: check-plaintext-secret-manifests ## Valide les manifests k8s hors-cluster (kubeconform) + terraform
	terraform -chdir=$(TF_DIR) init -backend=false -input=false
	terraform -chdir=$(TF_DIR) validate
	kubeconform -strict -ignore-missing-schemas -summary $(K8S_MANIFESTS)

dry-run: ## Simule l'application réelle contre un cluster vivant (ignore placeholders)
	@echo ">> Server-side dry-run de la couche prête (observability + data + traefik)"
	@timeout 8s kubectl --request-timeout=3s cluster-info >/dev/null 2>/dev/null || { \
		echo ">> Cluster Kubernetes inaccessible via KUBECONFIG=$(KUBECONFIG)."; \
		echo ">> Lance minikube ou pointe KUBECONFIG vers DOKS, puis relance make dry-run."; \
		exit 1; \
	}
	kubectl --request-timeout=10s apply --dry-run=server $(addprefix -f ,$(READY_MANIFESTS))

tf-lint: ## Lint terraform (tflint)
	cd $(TF_DIR) && tflint || true

## --- Durcissement production -----------------------------------------------

metrics: ## Assure la présence de metrics-server (les clusters managés l'ont souvent)
	@kubectl top nodes >/dev/null 2>&1 && echo "metrics-server déjà présent" || \
		kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

pdb: ## Applique les PodDisruptionBudgets (traefik prêt ; server si déployé)
	kubectl apply -f k8s/traefik/traefik.pdb.yaml
	@kubectl get deploy server >/dev/null 2>&1 \
		&& kubectl apply -f k8s/server/server.pdb.yaml \
		|| echo ">> deploy/server absent — k8s/server/server.pdb.yaml prêt à appliquer plus tard."
	kubectl get pdb -A

hpa: metrics ## Applique le HPA du server (sauté tant que le Deployment n'existe pas)
	@kubectl get deploy server >/dev/null 2>&1 \
		&& { kubectl apply -f k8s/server/server.hpa.yaml; kubectl get hpa; } \
		|| echo ">> deploy/server absent — k8s/server/server.hpa.yaml prêt à appliquer plus tard."

load: ## Génère de la charge HTTP (test autoscaling) contre l'hôte web
	WEB_URL=http://$(WEB_HOST):30021 ./scripts/load.sh

soft-affinity: ## Relâche l'anti-affinity required->preferred (clusters nodes < replicas)
	./scripts/soft-affinity.sh on

hard-affinity: ## Restaure l'anti-affinity stricte (preferred->required)
	./scripts/soft-affinity.sh off

harden: pdb hpa ## Applique PDB + HPA (ce qui est prêt)

## --- Cluster local (minikube, sans DigitalOcean) ---------------------------

minikube: minikube-up minikube-deploy ## One-shot : cluster local + couche prête
	@echo ">> Fait. Ensuite : 'make minikube-smoke' pour vérifier."

minikube-up: ## Démarre minikube (driver docker) + metrics-server + storage
	minikube start --nodes $(MINIKUBE_NODES) --driver=docker \
		--addons=metrics-server,default-storageclass,storage-provisioner

minikube-deploy: ## Déploie la couche prête sur le minikube courant
	$(MAKE) deploy

minikube-hosts: ## Mappe l'IP minikube -> hôtes web/api (/etc/hosts ; NixOS-aware)
	@IP=$$(minikube ip); LINE="$$IP $(WEB_HOST) $(API_HOST)"; \
	echo "$$LINE" | sudo tee -a /etc/hosts 2>/dev/null \
	  || { echo ">> /etc/hosts en lecture seule (NixOS). Ajouter dans configuration.nix :"; \
	       echo "     networking.extraHosts = \"$$LINE\";"; \
	       echo ">> Ou vérifier sans /etc/hosts : make minikube-smoke"; }

minikube-smoke: ## Smoke test minikube sans /etc/hosts (curl --resolve)
	RESOLVE_IP=$$(minikube ip) WEB_HOST=$(WEB_HOST) API_HOST=$(API_HOST) ./scripts/smoke.sh

minikube-down: ## Supprime le cluster minikube local
	minikube delete

## --- Gestion des secrets (SOPS/age) ----------------------------------------
check-plaintext-secret-manifests: ## Vérifie la présence de manifestes de secrets en clair (pas un scanner global)
	@echo ">> Vérification des manifestes de secrets en clair..."
	@if git ls-files | grep -E '\.secret\.yaml$$' | grep -v '\.sops\.'; then \
		echo ">> ERREUR : Des secrets en clair non autorisés sont suivis par Git."; \
		exit 1; \
	fi
	@if [ -f .sops.yaml ] && grep -q 'AGE-SECRET-KEY' .sops.yaml; then \
		echo ">> ERREUR : .sops.yaml contient une clé privée age"; \
		exit 1; \
	fi
	@echo ">> Contrôle structurel des fichiers SOPS..."
	@for f in $$(git ls-files | grep -E '\.secret\.sops\.yaml$$' || true); do \
		if [ -z "$$f" ]; then continue; fi; \
		if [ ! -s "$$f" ]; then echo ">> ERREUR: $$f est vide"; exit 1; fi; \
		if ! grep -q '^sops:' "$$f"; then echo ">> ERREUR: $$f ne contient pas la section sops:"; exit 1; fi; \
		if ! grep -q 'ENC\[AES256_GCM' "$$f"; then echo ">> ERREUR: $$f ne semble pas chiffré (ENC[AES256_GCM introuvable)"; exit 1; fi; \
		if grep -q 'AGE-SECRET-KEY' "$$f"; then echo ">> ERREUR: $$f contient une clé privée age en clair (AGE-SECRET-KEY)"; exit 1; fi; \
	done
	@echo ">> Les manifests SOPS chiffrés sont exclus de kubeconform."
	@echo ">> Utilisez make secrets-dry-run pour valider leur contenu déchiffré."

secrets-dry-run: ## Déchiffre et valide le secret sur le cluster sans l'appliquer (bash requis)
	@bash -c 'set -euo pipefail; \
	command -v sops >/dev/null || { echo ">> Erreur: sops introuvable"; exit 1; }; \
	command -v kubectl >/dev/null || { echo ">> Erreur: kubectl introuvable"; exit 1; }; \
	command -v kubeconform >/dev/null || { echo ">> Erreur: kubeconform introuvable"; exit 1; }; \
	if [ ! -f k8s/postgres/postgres.secret.sops.yaml ]; then \
		echo ">> Erreur: k8s/postgres/postgres.secret.sops.yaml est introuvable"; exit 1; \
	fi; \
	if [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ]; then \
		echo ">> Erreur: EXPECTED_CONTEXT et NAMESPACE doivent être définis"; \
		echo ">> Exemple: make secrets-dry-run EXPECTED_CONTEXT=minikube NAMESPACE=default"; exit 1; \
	fi; \
	CTX=$$(kubectl config current-context); \
	if [ "$$CTX" != "$$EXPECTED_CONTEXT" ]; then \
		echo ">> Erreur: Le contexte courant ($$CTX) ne correspond pas au contexte attendu ($$EXPECTED_CONTEXT)"; exit 1; \
	fi; \
	echo ">> Contexte cible: $$CTX (Namespace: $$NAMESPACE)"; \
	echo ">> Vérification du déchiffrement et du format..."; \
	sops -d k8s/postgres/postgres.secret.sops.yaml >/dev/null || { echo ">> Erreur de déchiffrement"; exit 1; }; \
	sops -d k8s/postgres/postgres.secret.sops.yaml | kubeconform -strict -summary; \
	echo ">> Dry-run server side..."; \
	sops -d k8s/postgres/postgres.secret.sops.yaml | kubectl --context "$$CTX" --namespace "$$NAMESPACE" apply --dry-run=server -f -'

secrets-apply: secrets-dry-run ## Déchiffre et applique le secret (requiert CONFIRM=APPLY_POSTGRES_SECRET)
	@bash -c 'set -euo pipefail; \
	if [ "$${CONFIRM:-}" != "APPLY_POSTGRES_SECRET" ]; then \
		echo ">> Erreur: Confirmation requise. Ajoutez CONFIRM=APPLY_POSTGRES_SECRET"; exit 1; \
	fi; \
	CURRENT_CTX=$$(kubectl config current-context); \
	if [ "$$CURRENT_CTX" != "$$EXPECTED_CONTEXT" ]; then \
		echo ">> Erreur: Le contexte a changé depuis le dry-run ($$CURRENT_CTX != $$EXPECTED_CONTEXT)"; exit 1; \
	fi; \
	echo ">> Application réelle du secret..."; \
	sops -d k8s/postgres/postgres.secret.sops.yaml | kubectl --context "$$EXPECTED_CONTEXT" --namespace "$$NAMESPACE" apply -f -'
