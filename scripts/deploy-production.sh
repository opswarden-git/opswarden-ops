#!/usr/bin/env bash
# Guarded application rollout used by the production GitHub environment.
set -Eeuo pipefail

EXPECTED_CONTEXT=${EXPECTED_CONTEXT:-}
NAMESPACE=${NAMESPACE:-}
SERVER_IMAGE=${SERVER_IMAGE:-}
PUBLIC_ORIGIN=${PUBLIC_ORIGIN:-}
API_ORIGIN=${API_ORIGIN:-}
RELEASE_ID=${RELEASE_ID:-${GITHUB_SHA:-}}

required=(EXPECTED_CONTEXT NAMESPACE SERVER_IMAGE PUBLIC_ORIGIN API_ORIGIN RELEASE_ID)
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

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release-state.sh
source "$script_dir/release-state.sh"
release_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/opswarden-release.XXXXXX")
release_state_init "$EXPECTED_CONTEXT" "$release_dir"

release_state_snapshot observability serviceaccount kube-state-metrics
release_state_snapshot observability role kube-state-metrics-backup-reader
release_state_snapshot observability rolebinding kube-state-metrics-backup-reader
release_state_snapshot observability deployment kube-state-metrics
release_state_snapshot observability service kube-state-metrics
release_state_snapshot observability configmap prometheus-config
release_state_snapshot observability configmap grafana-dashboard-opswarden-alertmanager
release_state_snapshot observability configmap grafana-datasources
release_state_snapshot observability configmap grafana-dashboards-provisioning
release_state_snapshot observability configmap loki-config
release_state_snapshot observability configmap alloy-config
release_state_snapshot observability deployment loki
release_state_snapshot observability deployment alloy
release_state_snapshot observability deployment grafana
release_state_snapshot observability service loki
release_state_snapshot observability service alloy
release_state_snapshot observability networkpolicy loki-ingress
release_state_snapshot observability serviceaccount alloy
release_state_snapshot default role alloy-pod-logs
release_state_snapshot default rolebinding alloy-pod-logs
release_state_snapshot "$NAMESPACE" networkpolicy allow-prometheus-server-metrics
release_state_snapshot "$NAMESPACE" deployment server
release_state_snapshot "$NAMESPACE" horizontalpodautoscaler server
release_state_snapshot "$NAMESPACE" poddisruptionbudget server
release_state_snapshot kube-public poddisruptionbudget traefik

previous_server=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  get deployment/server -o jsonpath='{.spec.template.spec.containers[?(@.name=="server")].image}' 2>/dev/null || true)
rollout_started=0

rollback() {
  status=$?
  trap - ERR
  echo ">> Échec du déploiement; restauration de l'unité de release" >&2
  if ! release_state_restore; then
    echo ">> ATTENTION: la restauration d'au moins une ressource a échoué" >&2
  fi
  if [ "$rollout_started" -eq 1 ] && [ -n "$previous_server" ]; then
    kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
      rollout status deployment/server --timeout=180s
    kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
      rollout restart deployment/prometheus
    kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
      rollout status deployment/prometheus --timeout=180s
    kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
      rollout restart deployment/grafana
    kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
      rollout status deployment/grafana --timeout=180s
  else
    echo ">> Le rollout serveur n'avait pas commencé; configuration restaurée" >&2
  fi
  release_state_cleanup
  exit "$status"
}
trap rollback ERR

echo ">> Configuration de l'observabilité Alertmanager"
kubectl --context "$EXPECTED_CONTEXT" apply \
  -f k8s/observability/kube-state-metrics.rbac.yaml \
  -f k8s/observability/kube-state-metrics.deployment.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
  rollout status deployment/kube-state-metrics --timeout=180s
# A bound PVC has controller-assigned immutable fields. Create it once, but do
# not re-apply its creation manifest during ordinary releases.
if ! kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
  get persistentvolumeclaim/loki-data >/dev/null 2>&1; then
  kubectl --context "$EXPECTED_CONTEXT" apply \
    -f k8s/observability/loki.pvc.yaml
fi
# These manifests declare their own namespaces. In particular, alloy.yaml
# contains observability workloads plus the default-namespace RBAC needed to
# read application pod logs, so forcing one namespace would reject that RBAC.
kubectl --context "$EXPECTED_CONTEXT" apply \
  -f k8s/observability/logging.configmap.yaml \
  -f k8s/observability/loki.yaml \
  -f k8s/observability/alloy.yaml \
  -f k8s/observability/grafana-config.yaml \
  -f k8s/observability/prometheus.configmap.yaml \
  -f k8s/observability/opswarden-alertmanager-dashboard.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
  rollout status deployment/loki --timeout=300s
kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
  rollout status deployment/alloy --timeout=300s
kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
  rollout restart deployment/grafana
kubectl --context "$EXPECTED_CONTEXT" --namespace observability \
  rollout status deployment/grafana --timeout=180s
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

kubectl --context "$EXPECTED_CONTEXT" --namespace observability annotate --overwrite \
  configmap/prometheus-config configmap/grafana-dashboard-opswarden-alertmanager \
  configmap/grafana-datasources configmap/grafana-dashboards-provisioning \
  configmap/loki-config configmap/alloy-config \
  persistentvolumeclaim/loki-data \
  deployment/kube-state-metrics deployment/loki deployment/alloy deployment/grafana \
  "opswarden.dev/release=$RELEASE_ID"
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" annotate --overwrite \
  deployment/server horizontalpodautoscaler/server poddisruptionbudget/server \
  "opswarden.dev/release=$RELEASE_ID" \
  "opswarden.dev/migration-policy=expand-contract"
kubectl --context "$EXPECTED_CONTEXT" --namespace kube-public annotate --overwrite \
  poddisruptionbudget/traefik "opswarden.dev/release=$RELEASE_ID"

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

  backup_state=$(curl --fail --silent \
    'http://127.0.0.1:19090/api/v1/query?query=kube_cronjob_info%7Bcronjob%3D%22postgres-backup%22%7D')
  jq -e '
    .status == "success"
    and any(.data.result[]; .value[1] == "1")
  ' <<<"$backup_state" >/dev/null

  rules=$(curl --fail --silent http://127.0.0.1:19090/api/v1/rules)
  jq -e '
    [.data.groups[].rules[].name] as $names
    | ($names | index("OpsWardenAlertmanagerDeliveryFailed")) != null
    and ($names | index("OpsWardenAlertmanagerRejectionsHigh")) != null
    and ($names | index("OpsWardenAlertmanagerDuplicateRatioHigh")) != null
    and ($names | index("OpsWardenBackupCronJobMissing")) != null
    and ($names | index("OpsWardenBackupCronJobSuspended")) != null
    and ($names | index("OpsWardenBackupJobFailed")) != null
    and ($names | index("OpsWardenBackupNeverSucceeded")) != null
    and ($names | index("OpsWardenBackupStale")) != null
    and ($names | index("OpsWardenLokiUnavailable")) != null
    and ($names | index("OpsWardenAlloyUnavailable")) != null
  ' <<<"$rules" >/dev/null

  logging_targets=$(curl --fail --silent \
    'http://127.0.0.1:19090/api/v1/query?query=up%7Bjob%3D~%22loki%7Calloy%22%7D')
  jq -e '
    .status == "success"
    and ([.data.result[] | select(.value[1] == "1")] | length) == 2
  ' <<<"$logging_targets" >/dev/null
)

trap - ERR
release_state_cleanup
echo ">> Déploiement production vérifié"
