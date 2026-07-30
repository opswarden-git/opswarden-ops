#!/usr/bin/env bash
# Guarded application rollout used by the production GitHub environment.
set -Eeuo pipefail

EXPECTED_CONTEXT=${EXPECTED_CONTEXT:-}
NAMESPACE=${NAMESPACE:-}
SERVER_IMAGE=${SERVER_IMAGE:-}
PUBLIC_ORIGIN=${PUBLIC_ORIGIN:-}
API_ORIGIN=${API_ORIGIN:-}

required=(EXPECTED_CONTEXT NAMESPACE SERVER_IMAGE PUBLIC_ORIGIN API_ORIGIN)
for name in "${required[@]}"; do
  if [ -z "${!name:-}" ]; then
    echo ">> ERREUR: $name est requis" >&2
    exit 1
  fi
done

if [ "$(kubectl config current-context)" != "$EXPECTED_CONTEXT" ]; then
  echo ">> ERREUR: le contexte kubectl courant n'est pas $EXPECTED_CONTEXT" >&2
  exit 1
fi

previous_server=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  get deployment/server -o jsonpath='{.spec.template.spec.containers[?(@.name=="server")].image}' 2>/dev/null || true)
rollout_started=0

rollback() {
  status=$?
  trap - ERR
  if [ "$rollout_started" -eq 1 ] && [ -n "$previous_server" ]; then
    echo ">> Échec du déploiement; rollback du serveur vers l'image précédente" >&2
    kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
      set image deployment/server server="$previous_server"
    kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
      rollout status deployment/server --timeout=180s
  else
    echo ">> Aucun déploiement antérieur complet disponible pour un rollback automatique" >&2
  fi
  exit "$status"
}
trap rollback ERR

echo ">> Configuration de l'observabilité Alertmanager"
kubectl --context "$EXPECTED_CONTEXT" --namespace observability apply \
  -f k8s/observability/prometheus.configmap.yaml \
  -f k8s/observability/opswarden-alertmanager-dashboard.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" apply \
  -f k8s/observability/opswarden-metrics.networkpolicy.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
  rollout restart deployment/prometheus
kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
  rollout status deployment/prometheus --timeout=180s

if kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  get cronjob/postgres-backup >/dev/null 2>&1; then
  echo ">> Sauvegarde pré-déploiement"
  make backup-run EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE"
fi

rollout_started=1
make deploy-server \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE" \
  SERVER_IMAGE="$SERVER_IMAGE" \
  PUBLIC_ORIGIN="$PUBLIC_ORIGIN" \
  API_ORIGIN="$API_ORIGIN"

kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" apply \
  -f k8s/server/server.pdb.yaml \
  -f k8s/server/server.hpa.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace kube-public apply \
  -f k8s/traefik/traefik.pdb.yaml

api_origin=${API_ORIGIN%/}
API_ONLY=1 \
  WEB_URL="$api_origin/health" \
  ABOUT_URL="$api_origin/about.json" \
  WS_URL="$api_origin/ws" \
  ./scripts/smoke.sh

(
  kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
    port-forward service/prometheus 19090:9090 >"$RUNNER_TEMP/prometheus-port-forward.log" 2>&1 &
  forward_pid=$!
  trap 'kill "$forward_pid" 2>/dev/null || true' EXIT

  for _ in $(seq 1 30); do
    if curl --fail --silent http://127.0.0.1:19090/-/ready >/dev/null; then
      break
    fi
    sleep 1
  done

  targets=$(curl --fail --silent \
    'http://127.0.0.1:19090/api/v1/query?query=up%7Bjob%3D%22opswarden-server%22%7D')
  jq -e '
    .status == "success"
    and any(.data.result[]; .value[1] == "1")
  ' <<<"$targets" >/dev/null

  rules=$(curl --fail --silent http://127.0.0.1:19090/api/v1/rules)
  jq -e '
    [.data.groups[].rules[].name] as $names
    | ($names | index("OpsWardenAlertmanagerDeliveryFailed")) != null
    and ($names | index("OpsWardenAlertmanagerRejectionsHigh")) != null
    and ($names | index("OpsWardenAlertmanagerDuplicateRatioHigh")) != null
  ' <<<"$rules" >/dev/null
)

trap - ERR
echo ">> Déploiement production vérifié"
