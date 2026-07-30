#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_CONTEXT=${EXPECTED_CONTEXT:-}
NAMESPACE=${NAMESPACE:-}

for name in EXPECTED_CONTEXT NAMESPACE; do
  if [ -z "${!name:-}" ]; then
    echo ">> ERREUR: $name est requis" >&2
    exit 1
  fi
done

if [ "$(kubectl config current-context)" != "$EXPECTED_CONTEXT" ]; then
  echo ">> ERREUR: contexte kubectl inattendu" >&2
  exit 1
fi

kubectl --context "$EXPECTED_CONTEXT" apply \
  -f k8s/metrics-server/metrics-server.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace kube-system \
  rollout status deployment/metrics-server --timeout=300s

for _ in $(seq 1 60); do
  if kubectl --context "$EXPECTED_CONTEXT" top nodes >/dev/null 2>&1 &&
    kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
      top pods -l app=server >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

kubectl --context "$EXPECTED_CONTEXT" top nodes
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  top pods -l app=server

kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" apply \
  -f k8s/server/server.hpa.yaml

for _ in $(seq 1 30); do
  current_cpu=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
    get hpa/server -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' \
    2>/dev/null || true)
  if [[ "$current_cpu" =~ ^[0-9]+$ ]]; then
    break
  fi
  sleep 5
done

if ! [[ "${current_cpu:-}" =~ ^[0-9]+$ ]]; then
  echo ">> ERREUR: le HPA ne reçoit aucune métrique CPU" >&2
  exit 1
fi

desired=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  get hpa/server -o jsonpath='{.status.desiredReplicas}')
current=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  get hpa/server -o jsonpath='{.status.currentReplicas}')

printf '>> Metrics API prête; HPA CPU=%s%% replicas=%s desired=%s\n' \
  "$current_cpu" "$current" "$desired"
