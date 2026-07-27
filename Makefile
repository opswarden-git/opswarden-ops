# OpsWarden Ops — runner unique du repo (infra). Convention projet : ops = Make,
# app/web = Just (un seul runner par repo, jamais deux empilés).
# Cycle de vie : provision -> deploy -> harden -> verify -> destroy.
# Inclut aussi la qualité (fmt / validate / lint), repliée ici depuis l'ex-Justfile.
#
# Démarrage rapide (depuis ce dossier) :
#   cp .env.example .env && $EDITOR .env   # poser les jetons DO + Spaces
#   cp terraform/backend.hcl.example terraform/backend.hcl && $EDITOR terraform/backend.hcl
#   nix develop                            # ou: export $(grep -v '^#' .env | xargs)
#   make all TF_BACKEND_CONFIG=terraform/backend.hcl
#   make hosts && make smoke               # DNS local + smoke test
#
# Le serveur et le client web ont des manifests déployables. L'investigation et
# le worker restent optionnels/non implémentés. `deploy` pose l'infrastructure ;
# `deploy-app` pose explicitement la couche produit après contrôle des secrets.

# Recettes POSIX sh (pas de dépendance dure à /bin/bash : NixOS / images minimales).
TF_DIR         := terraform
# Kubeconfig par défaut : ~/.kube/config (ce que minikube, kubectl et k9s utilisent).
# DOKS est le cas particulier : Terraform écrit ./kubeconfig, utilisé par all/infra.
KUBECONFIG     ?= $(HOME)/.kube/config
export KUBECONFIG
DOKS_KUBECONFIG := $(CURDIR)/kubeconfig

# minikube écrit son contexte dans ~/.kube/config (le défaut). Deux nœuds
# permettent de tester le placement des services répliqués quand le réseau hôte
# le supporte.
MINIKUBE_NODES ?= 2
MINIKUBE_CNI ?= calico
MINIKUBE_CONTAINER_RUNTIME ?= containerd
CERT_MANAGER_VERSION ?= v1.20.3
TLS_ISSUER ?= letsencrypt-prod
APP_HOST ?= app.opswarden.dev
API_HOST ?= api.opswarden.dev
BACKUP_PREFIX ?= production/postgres
BACKUP_RETENTION ?= 30d

# Hôte produit. En local, `curl --resolve` le mappe vers l'IP minikube.
WEB_HOST ?= app.opswarden.dev

# Manifests groupés par phase de déploiement.
DATA       := k8s/postgres/postgres.configmap.yaml \
              k8s/postgres/postgres.volume.yaml k8s/postgres/postgres.sa.yaml \
              k8s/postgres/postgres.deployment.yaml k8s/postgres/postgres.service.yaml \
              k8s/redis/redis.configmap.yaml k8s/redis/redis.sa.yaml \
              k8s/redis/redis.deployment.yaml k8s/redis/redis.service.yaml
LB         := k8s/traefik/traefik.ingressclass.yaml k8s/traefik/traefik.rbac.yaml \
              k8s/traefik/traefik.deployment.yaml k8s/traefik/traefik.service.yaml
TRAEFIK_APP_RBAC := k8s/traefik/traefik.app-secrets.rbac.yaml
SERVER_SUPPORT := k8s/server/server.sa.yaml k8s/server/server.service.yaml \
                  k8s/server/server.ingress.yaml
SELF_HOSTED_WEB_SUPPORT := k8s/client-web/client-web.sa.yaml \
                           k8s/client-web/client-web.service.yaml \
                           k8s/client-web/client-web.ingress.yaml
BACKUP_SUPPORT := k8s/postgres/postgres-backup.sa.yaml \
                  k8s/postgres/postgres-backup.cronjob.yaml
DEFAULT_NETWORK_POLICIES := k8s/network-policies/default-deny.yaml \
                            k8s/network-policies/workloads.yaml
TRAEFIK_NETWORK_POLICY := k8s/network-policies/traefik.yaml
READY_MANIFESTS := $(DATA) $(LB)
K8S_MANIFESTS := $(shell find k8s -name '*.yaml' ! -name '*.sops.yaml' | sort)

.DEFAULT_GOAL := help
.PHONY: help all backend-init infra kubeconfig deploy deploy-server deploy-self-hosted-web deploy-app deploy-app-local db-check hosts smoke status destroy \
        fmt fmt-check validate dry-run tf-lint check-plaintext-secret-manifests \
        validate-templates secret-dry-run secret-apply secrets-dry-run secrets-apply \
        backup-enable backup-run backup-verify backup-status \
        tls tls-status \
        metrics hpa pdb load harden soft-affinity hard-affinity \
        minikube minikube-up minikube-deploy minikube-hosts minikube-smoke minikube-down

help: ## Affiche cette aide
	@echo "OpsWarden Ops — cibles make :"
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

all: infra ## DOKS : provisionne le cluster sans déployer implicitement
	@echo ">> Cluster provisionné. Vérifiez le contexte puis lancez make deploy avec EXPECTED_CONTEXT et NAMESPACE."

## --- Cœur ------------------------------------------------------------------

backend-init: ## Initialise l'état Terraform distant Spaces (TF_BACKEND_CONFIG requis)
	@bash -c 'set -euo pipefail; \
	if [ -z "$${TF_BACKEND_CONFIG:-}" ]; then \
		echo ">> Erreur: TF_BACKEND_CONFIG doit pointer vers un fichier backend local"; \
		echo ">> Exemple: cp terraform/backend.hcl.example terraform/backend.hcl"; exit 1; \
	fi; \
	if [ ! -f "$$TF_BACKEND_CONFIG" ]; then \
		echo ">> Erreur: backend introuvable: $$TF_BACKEND_CONFIG"; exit 1; \
	fi; \
	BACKEND_FILE=$$(realpath "$$TF_BACKEND_CONFIG"); \
	if [ -z "$${AWS_ACCESS_KEY_ID:-}" ] || [ -z "$${AWS_SECRET_ACCESS_KEY:-}" ] \
		|| [ "$$AWS_ACCESS_KEY_ID" = "METTRE_ICI_LA_CLE_SPACES" ] \
		|| [ "$$AWS_SECRET_ACCESS_KEY" = "METTRE_ICI_LE_SECRET_SPACES" ]; then \
		echo ">> Erreur: AWS_ACCESS_KEY_ID et AWS_SECRET_ACCESS_KEY (clés Spaces) sont requises"; exit 1; \
	fi; \
	if [ -f "$(TF_DIR)/terraform.tfstate" ] || [ -f "$(TF_DIR)/terraform.tfstate.backup" ]; then \
		echo ">> Erreur: état local détecté; migrez-le explicitement après sauvegarde au lieu de le réinitialiser"; \
		echo ">> Commande contrôlée: terraform -chdir=$(TF_DIR) init -migrate-state -backend-config=$$BACKEND_FILE"; exit 1; \
	fi; \
	terraform -chdir=$(TF_DIR) init -input=false -reconfigure -backend-config="$$BACKEND_FILE"'

infra: backend-init ## Initialise l'état distant puis provisionne le cluster DOKS
	cd $(TF_DIR) && terraform apply -auto-approve
	@echo ">> Attente des nœuds Ready..."
	KUBECONFIG=$(DOKS_KUBECONFIG) kubectl wait --for=condition=Ready nodes --all --timeout=300s

kubeconfig: backend-init ## (Re)génère ./kubeconfig depuis l'état Terraform
	cd $(TF_DIR) && terraform apply -auto-approve -target=local_sensitive_file.kubeconfig

deploy: ## Applique la couche prête (data + traefik), dans l'ordre
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
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply $(addprefix -f ,$(DATA))
	@echo ">> Attente de postgres & redis..."
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" rollout status deploy/postgres --timeout=180s
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" rollout status deploy/redis --timeout=120s
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public create configmap traefik-config \
		--from-literal=WATCH_NAMESPACE="$${NAMESPACE}" --dry-run=client -o yaml \
		| kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public apply -f -
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public apply $(addprefix -f ,$(LB))
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply -f $(TRAEFIK_APP_RBAC)
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply \
		$(addprefix -f ,$(DEFAULT_NETWORK_POLICIES))
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public apply \
		-f $(TRAEFIK_NETWORK_POLICY)
	@if [ "$${LOCAL_PRIMARY_ONLY:-0}" = "1" ]; then \
		TRAEFIK_PATCH='{"spec":{"replicas":1,"template":{"spec":{"nodeSelector":{"minikube.k8s.io/primary":"true"},"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}'; \
		kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public patch deploy/traefik --type=merge -p "$$TRAEFIK_PATCH"; \
	fi
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public rollout status deploy/traefik --timeout=120s
	@echo ">> Infrastructure prête. Lancez 'make deploy-server' après publication de l'image et création du secret applicatif."

deploy-server: ## Déploie le serveur Rust nominal (secret applicatif requis)
	@bash -c 'set -euo pipefail; \
	if [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ]; then \
		echo ">> Erreur: EXPECTED_CONTEXT et NAMESPACE doivent être définis"; exit 1; \
	fi; \
	if [ -z "$${SERVER_IMAGE:-}" ]; then \
		echo ">> Erreur: SERVER_IMAGE doit être définie"; exit 1; \
	fi; \
	if [ -z "$${PUBLIC_ORIGIN:-}" ] || [ -z "$${API_ORIGIN:-}" ]; then \
		echo ">> Erreur: PUBLIC_ORIGIN et API_ORIGIN doivent être définies"; exit 1; \
	fi; \
	if [ "$${ALLOW_INSECURE_ORIGIN:-0}" != "1" ]; then \
		echo "$$PUBLIC_ORIGIN" | grep -Eq "^https://[^[:space:]]+$$" \
			|| { echo ">> Erreur: PUBLIC_ORIGIN doit utiliser HTTPS"; exit 1; }; \
		echo "$$API_ORIGIN" | grep -Eq "^https://[^[:space:]]+$$" \
			|| { echo ">> Erreur: API_ORIGIN doit utiliser HTTPS"; exit 1; }; \
	fi; \
	if [ "$${ALLOW_MUTABLE_IMAGES:-0}" != "1" ]; then \
		echo "$$SERVER_IMAGE" | grep -Eq "^ghcr\.io/opswarden-git/opswarden-server@sha256:[0-9a-f]{64}$$" \
			|| { echo ">> Erreur: SERVER_IMAGE doit être une référence GHCR par digest sha256"; exit 1; }; \
	fi; \
	CTX=$$(kubectl config current-context); \
	if [ "$$CTX" != "$$EXPECTED_CONTEXT" ]; then \
		echo ">> Erreur: contexte courant $$CTX != $$EXPECTED_CONTEXT"; exit 1; \
	fi; \
	if ! kubectl --context "$$EXPECTED_CONTEXT" --namespace "$$NAMESPACE" get secret opswarden-server-secret >/dev/null 2>&1; then \
		echo ">> ERREUR: secret opswarden-server-secret absent"; \
		echo ">> Créez-le avec SOPS à partir de k8s/server/server.secret.example.yaml"; exit 1; \
	fi'
	kubectl create configmap server-config --namespace "$${NAMESPACE}" \
		--from-literal=OPSWARDEN_WEB_ORIGIN="$${PUBLIC_ORIGIN}" \
		--from-literal=OPSWARDEN_TRUSTED_PROXY_HOPS=1 \
		--from-literal=GOOGLE_OAUTH_REDIRECT_URI="$${API_ORIGIN}/api/auth/google/callback" \
		--from-literal=GITHUB_OAUTH_REDIRECT_URI="$${API_ORIGIN}/api/service-oauth/github/callback" \
		--dry-run=client -o yaml \
		| kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply -f -
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply $(addprefix -f ,$(SERVER_SUPPORT))
	kubectl set image --local -f k8s/server/deployment.yaml server="$${SERVER_IMAGE}" -o yaml \
		| kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply -f -
	@if [ "$${LOCAL_PRIMARY_ONLY:-0}" = "1" ]; then \
		PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"minikube.k8s.io/primary":"true"}}}}}'; \
		TRAEFIK_PATCH='{"spec":{"replicas":1,"template":{"spec":{"nodeSelector":{"minikube.k8s.io/primary":"true"},"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}'; \
		kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" patch deploy/server --type=merge -p "$$PATCH"; \
		kubectl --context "$${EXPECTED_CONTEXT}" --namespace kube-public patch deploy/traefik --type=merge -p "$$TRAEFIK_PATCH"; \
	fi
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" rollout status deploy/server --timeout=180s

deploy-self-hosted-web: ## Déploie le client Next.js optionnel dans Kubernetes
	@bash -c 'set -euo pipefail; \
	if [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ] || [ -z "$${WEB_IMAGE:-}" ]; then \
		echo ">> Erreur: EXPECTED_CONTEXT, NAMESPACE et WEB_IMAGE sont requis"; exit 1; fi; \
	if [ "$${ALLOW_MUTABLE_IMAGES:-0}" != "1" ]; then \
		echo "$$WEB_IMAGE" | grep -Eq "^ghcr\.io/opswarden-git/opswarden-client-web@sha256:[0-9a-f]{64}$$" \
			|| { echo ">> Erreur: WEB_IMAGE doit être une référence GHCR par digest sha256"; exit 1; }; fi; \
	[ "$$(kubectl config current-context)" = "$$EXPECTED_CONTEXT" ] \
		|| { echo ">> Erreur: contexte Kubernetes inattendu"; exit 1; }'
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply $(addprefix -f ,$(SELF_HOSTED_WEB_SUPPORT))
	kubectl set image --local -f k8s/client-web/deployment.yaml client-web="$${WEB_IMAGE}" -o yaml \
		| kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply -f -
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" rollout status deploy/client-web --timeout=180s

deploy-app: deploy-server deploy-self-hosted-web ## Déploie le mode Kubernetes self-hosted complet

deploy-app-local: ## Déploie les images locales avec le contournement réseau NixOS/minikube
	$(MAKE) deploy-app EXPECTED_CONTEXT=minikube NAMESPACE=default \
		SERVER_IMAGE=opswarden-server:local-check \
		WEB_IMAGE=opswarden-client-web:local-check \
		PUBLIC_ORIGIN=http://app.opswarden.dev:30021 \
		API_ORIGIN=http://app.opswarden.dev:30021 \
		ALLOW_MUTABLE_IMAGES=1 ALLOW_INSECURE_ORIGIN=1 LOCAL_PRIMARY_ONLY=1

tls: ## Installe cert-manager et active Let's Encrypt (CONFIRM=ENABLE_PUBLIC_TLS)
	@bash -c 'set -euo pipefail; \
	if [ "$${CONFIRM:-}" != "ENABLE_PUBLIC_TLS" ]; then \
		echo ">> Erreur: confirmation requise: CONFIRM=ENABLE_PUBLIC_TLS"; exit 1; \
	fi; \
	if [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ] || [ -z "$${ACME_EMAIL:-}" ]; then \
		echo ">> Erreur: EXPECTED_CONTEXT, NAMESPACE et ACME_EMAIL doivent être définis"; exit 1; \
	fi; \
	CTX=$$(kubectl config current-context); \
	if [ "$$CTX" != "$$EXPECTED_CONTEXT" ]; then \
		echo ">> Erreur: contexte courant $$CTX != $$EXPECTED_CONTEXT"; exit 1; \
	fi; \
	command -v helm >/dev/null || { echo ">> Erreur: helm introuvable"; exit 1; }; \
	command -v envsubst >/dev/null || { echo ">> Erreur: envsubst introuvable (paquet gettext)"; exit 1; }'
	helm --kube-context "$${EXPECTED_CONTEXT}" upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
		--version $(CERT_MANAGER_VERSION) --namespace cert-manager --create-namespace \
		--set crds.enabled=true --wait --timeout 5m
	TLS_ISSUER=$(TLS_ISSUER) ACME_EMAIL="$${ACME_EMAIL}" \
		envsubst '$${TLS_ISSUER} $${ACME_EMAIL}' \
		< k8s/cert-manager/letsencrypt.clusterissuer.yaml.tmpl \
		| kubectl --context "$${EXPECTED_CONTEXT}" apply -f -
	kubectl --context "$${EXPECTED_CONTEXT}" wait \
		--for=condition=Ready clusterissuer/$(TLS_ISSUER) --timeout=2m
	TLS_ISSUER=$(TLS_ISSUER) API_HOST=$(API_HOST) NAMESPACE="$${NAMESPACE}" \
		envsubst '$${TLS_ISSUER} $${API_HOST} $${NAMESPACE}' \
		< k8s/server/server.ingress.tls.yaml.tmpl \
		| kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply -f -
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" \
		wait --for=condition=Ready certificate/opswarden-api-tls --timeout=5m

tls-status: ## Affiche l'état cert-manager, du certificat et de l'Ingress
	kubectl get clusterissuer $(TLS_ISSUER)
	kubectl get certificate,certificaterequest,order,challenge -A
	kubectl get ingress -A

backup-enable: ## Active les sauvegardes chiffrées Spaces (CONFIRM=ENABLE_BACKUPS)
	@bash -c 'set -euo pipefail; \
	if [ "$${CONFIRM:-}" != "ENABLE_BACKUPS" ]; then \
		echo ">> Erreur: confirmation requise: CONFIRM=ENABLE_BACKUPS"; exit 1; \
	fi; \
	if [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ] \
		|| [ -z "$${BACKUP_BUCKET:-}" ] || [ -z "$${BACKUP_ENDPOINT:-}" ]; then \
		echo ">> Erreur: EXPECTED_CONTEXT, NAMESPACE, BACKUP_BUCKET et BACKUP_ENDPOINT sont requis"; exit 1; \
	fi; \
	echo "$${BACKUP_BUCKET}" | grep -Eq "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$$" \
		|| { echo ">> Erreur: BACKUP_BUCKET invalide"; exit 1; }; \
	echo "$${BACKUP_ENDPOINT}" | grep -Eq "^https://[a-z0-9-]+\.digitaloceanspaces\.com$$" \
		|| { echo ">> Erreur: BACKUP_ENDPOINT doit être une URL régionale Spaces HTTPS"; exit 1; }; \
	echo "$(BACKUP_PREFIX)" | grep -Eq "^[A-Za-z0-9][A-Za-z0-9._/-]*$$" \
		&& ! echo "$(BACKUP_PREFIX)" | grep -Eq "(^|/)\.\.(/|$$)" \
		|| { echo ">> Erreur: BACKUP_PREFIX invalide"; exit 1; }; \
	echo "$(BACKUP_RETENTION)" | grep -Eq "^[1-9][0-9]*(h|d|w|M|y)$$" \
		|| { echo ">> Erreur: BACKUP_RETENTION invalide (ex: 30d)"; exit 1; }; \
	CTX=$$(kubectl config current-context); \
	[ "$$CTX" = "$$EXPECTED_CONTEXT" ] \
		|| { echo ">> Erreur: contexte courant $$CTX != $$EXPECTED_CONTEXT"; exit 1; }; \
	for secret in postgres-secret postgres-backup-secret; do \
		kubectl --context "$$EXPECTED_CONTEXT" --namespace "$$NAMESPACE" get secret "$$secret" >/dev/null 2>&1 \
			|| { echo ">> Erreur: secret $$secret absent"; exit 1; }; \
	done'
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" create configmap postgres-backup-config \
		--from-literal=BACKUP_BUCKET="$${BACKUP_BUCKET}" \
		--from-literal=BACKUP_PREFIX="$(BACKUP_PREFIX)" \
		--from-literal=BACKUP_RETENTION="$(BACKUP_RETENTION)" \
		--from-literal=RCLONE_CONFIG_S3_ENDPOINT="$${BACKUP_ENDPOINT}" \
		--dry-run=client -o yaml | kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply -f -
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply $(addprefix -f ,$(BACKUP_SUPPORT))

backup-run: ## Déclenche immédiatement un backup depuis le CronJob
	@bash -c 'set -euo pipefail; \
	if [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ]; then \
		echo ">> Erreur: EXPECTED_CONTEXT et NAMESPACE sont requis"; exit 1; fi; \
	CTX=$$(kubectl config current-context); [ "$$CTX" = "$$EXPECTED_CONTEXT" ] \
		|| { echo ">> Erreur: contexte courant $$CTX != $$EXPECTED_CONTEXT"; exit 1; }'
	@JOB="postgres-backup-manual-$$(date -u +%Y%m%d%H%M%S)"; \
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" create job "$$JOB" --from=cronjob/postgres-backup; \
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" wait --for=condition=Complete "job/$$JOB" --timeout=130m; \
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" logs "job/$$JOB" --all-containers=true

backup-verify: ## Télécharge, déchiffre et restaure le dernier backup dans un Postgres isolé
	@bash -c 'set -euo pipefail; \
	if [ "$${CONFIRM:-}" != "VERIFY_LATEST_BACKUP" ]; then \
		echo ">> Erreur: confirmation requise: CONFIRM=VERIFY_LATEST_BACKUP"; exit 1; fi; \
	if [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ]; then \
		echo ">> Erreur: EXPECTED_CONTEXT et NAMESPACE sont requis"; exit 1; fi; \
	CTX=$$(kubectl config current-context); [ "$$CTX" = "$$EXPECTED_CONTEXT" ] \
		|| { echo ">> Erreur: contexte courant $$CTX != $$EXPECTED_CONTEXT"; exit 1; }'
	@JOB=$$(kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" \
		create -f k8s/postgres/postgres-backup-verify.job.yaml -o jsonpath='{.metadata.name}'); \
	echo ">> Job de restauration isolée: $$JOB"; \
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" wait --for=condition=Complete "job/$$JOB" --timeout=130m; \
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" logs "job/$$JOB" --all-containers=true

backup-status: ## Affiche CronJob, derniers Jobs et événements de sauvegarde
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" get cronjob/postgres-backup
	kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" get jobs -l 'app in (postgres-backup,postgres-backup-verify)'

db-check: ## Vérifie la connectivité Postgres (le schéma est géré par opswarden-server)
	@POD=$$(kubectl get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}'); \
	echo ">> Test connexion sur le pod $$POD"; \
	kubectl exec -i $$POD -c postgres -- sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -c "SELECT 1;"'

hosts: ## Mappe l'IP d'un nœud -> hôtes web/api dans /etc/hosts (sudo)
	@NODES=$$(kubectl get nodes -o jsonpath='{ $$.items[*].status.addresses[?(@.type=="ExternalIP")].address }'); \
	IP=$$(echo $$NODES | awk '{print $$1}'); \
	echo ">> $$IP -> $(WEB_HOST)"; \
	echo "$$IP $(WEB_HOST)" | sudo tee -a /etc/hosts

smoke: ## Smoke test bout-en-bout (Traefik + routes app best-effort)
	WEB_HOST=$(WEB_HOST) ./scripts/smoke.sh

status: ## État du cluster (pods / services / ingress, namespaces utiles)
	kubectl get pods -o wide
	kubectl get svc,ingress
	kubectl -n kube-public get pods,svc -o wide
	@kubectl -n kube-system get ds cadvisor 2>/dev/null || echo ">> cAdvisor optionnel non déployé"

destroy: backend-init ## Détruit le cluster DOKS
	cd $(TF_DIR) && terraform destroy -auto-approve

## --- Qualité (ex-Justfile, ce que vérifie la CI) ---------------------------

fmt: ## Formate yaml/md/json (prettier) + terraform fmt
	npx --yes prettier --write "**/*.{yaml,yml,md,json}"
	terraform -chdir=$(TF_DIR) fmt

fmt-check: ## Vérifie le formatage sans rien modifier (miroir CI)
	npx --yes prettier --check "**/*.{yaml,yml,md,json}"
	terraform -chdir=$(TF_DIR) fmt -check

validate: check-plaintext-secret-manifests validate-templates ## Valide workflows, manifests k8s et Terraform
	actionlint
	terraform -chdir=$(TF_DIR) init -backend=false -input=false
	terraform -chdir=$(TF_DIR) validate
	kubeconform -strict -ignore-missing-schemas -summary $(K8S_MANIFESTS)

validate-templates: ## Rend et valide les manifests TLS paramétrés sans les appliquer
	@bash -c 'set -euo pipefail; \
	command -v envsubst >/dev/null || { echo ">> Erreur: envsubst introuvable"; exit 1; }; \
	TLS_ISSUER=letsencrypt-test ACME_EMAIL=test@example.invalid \
		envsubst '\''$${TLS_ISSUER} $${ACME_EMAIL}'\'' \
		< k8s/cert-manager/letsencrypt.clusterissuer.yaml.tmpl \
		| kubeconform -strict -ignore-missing-schemas -summary; \
	TLS_ISSUER=letsencrypt-test API_HOST=api.example.invalid NAMESPACE=default \
		envsubst '\''$${TLS_ISSUER} $${API_HOST} $${NAMESPACE}'\'' \
		< k8s/server/server.ingress.tls.yaml.tmpl \
		| kubeconform -strict -ignore-missing-schemas -summary'

dry-run: ## Simule l'application de la couche infrastructure contre un cluster vivant
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

metrics: ## Vérifie metrics-server sans installer une ressource distante mutable
	@kubectl top nodes >/dev/null 2>&1 \
		&& echo "metrics-server présent" \
		|| { echo ">> Erreur: metrics-server absent; activez l'addon minikube ou le service managé DOKS"; exit 1; }

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
	minikube start --nodes $(MINIKUBE_NODES) --driver=docker --cni=$(MINIKUBE_CNI) \
		--container-runtime=$(MINIKUBE_CONTAINER_RUNTIME) \
		--addons=metrics-server,default-storageclass,storage-provisioner

minikube-deploy: ## Déploie la couche prête sur le minikube courant
	$(MAKE) deploy EXPECTED_CONTEXT=minikube NAMESPACE=default LOCAL_PRIMARY_ONLY=1

minikube-hosts: ## Mappe l'IP minikube -> hôtes web/api (/etc/hosts ; NixOS-aware)
	@IP=$$(minikube ip); LINE="$$IP $(WEB_HOST)"; \
	echo "$$LINE" | sudo tee -a /etc/hosts 2>/dev/null \
	  || { echo ">> /etc/hosts en lecture seule (NixOS). Ajouter dans configuration.nix :"; \
	       echo "     networking.extraHosts = \"$$LINE\";"; \
	       echo ">> Ou vérifier sans /etc/hosts : make minikube-smoke"; }

minikube-smoke: ## Smoke test minikube sans /etc/hosts (curl --resolve)
	RESOLVE_IP=$$(minikube ip) WEB_HOST=$(WEB_HOST) ./scripts/smoke.sh

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

secret-dry-run: ## Valide un SECRET_FILE SOPS autorisé contre le cluster
	@bash -c 'set -euo pipefail; \
	command -v sops >/dev/null || { echo ">> Erreur: sops introuvable"; exit 1; }; \
	command -v yq >/dev/null || { echo ">> Erreur: yq introuvable"; exit 1; }; \
	command -v kubeconform >/dev/null || { echo ">> Erreur: kubeconform introuvable"; exit 1; }; \
	if [ -z "$${SECRET_FILE:-}" ] || [ -z "$${EXPECTED_CONTEXT:-}" ] || [ -z "$${NAMESPACE:-}" ]; then \
		echo ">> Erreur: SECRET_FILE, EXPECTED_CONTEXT et NAMESPACE sont requis"; exit 1; fi; \
	case "$$SECRET_FILE" in \
		k8s/postgres/postgres.secret.sops.yaml|k8s/postgres/postgres-backup.secret.sops.yaml|k8s/server/server.secret.sops.yaml) ;; \
		*) echo ">> Erreur: SECRET_FILE hors de la liste autorisée"; exit 1 ;; \
	esac; \
	[ -f "$$SECRET_FILE" ] || { echo ">> Erreur: $$SECRET_FILE introuvable"; exit 1; }; \
	CTX=$$(kubectl config current-context); [ "$$CTX" = "$$EXPECTED_CONTEXT" ] \
		|| { echo ">> Erreur: contexte courant $$CTX != $$EXPECTED_CONTEXT"; exit 1; }; \
	sops -d "$$SECRET_FILE" | yq "del(.metadata.namespace)" | kubeconform -strict -summary; \
	sops -d "$$SECRET_FILE" | yq "del(.metadata.namespace)" | kubectl --context "$$EXPECTED_CONTEXT" --namespace "$$NAMESPACE" apply --dry-run=server -f -'

secret-apply: secret-dry-run ## Applique SECRET_FILE (CONFIRM=APPLY_SOPS_SECRET)
	@bash -c 'set -euo pipefail; \
	if [ "$${CONFIRM:-}" != "APPLY_SOPS_SECRET" ]; then \
		echo ">> Erreur: confirmation requise: CONFIRM=APPLY_SOPS_SECRET"; exit 1; fi; \
	sops -d "$${SECRET_FILE}" | yq "del(.metadata.namespace)" | kubectl --context "$${EXPECTED_CONTEXT}" --namespace "$${NAMESPACE}" apply -f -'

secrets-dry-run: ## Déchiffre et valide le secret sur le cluster sans l'appliquer (bash requis)
	@bash -c 'set -euo pipefail; \
	command -v sops >/dev/null || { echo ">> Erreur: sops introuvable"; exit 1; }; \
	command -v yq >/dev/null || { echo ">> Erreur: yq introuvable"; exit 1; }; \
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
	sops -d k8s/postgres/postgres.secret.sops.yaml | yq "del(.metadata.namespace)" | kubeconform -strict -summary; \
	echo ">> Dry-run server side..."; \
	sops -d k8s/postgres/postgres.secret.sops.yaml | yq "del(.metadata.namespace)" | kubectl --context "$$CTX" --namespace "$$NAMESPACE" apply --dry-run=server -f -'

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
	sops -d k8s/postgres/postgres.secret.sops.yaml | yq "del(.metadata.namespace)" | kubectl --context "$$EXPECTED_CONTEXT" --namespace "$$NAMESPACE" apply -f -'
