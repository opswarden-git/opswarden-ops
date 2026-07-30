#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_CONTEXT=${EXPECTED_CONTEXT:-}
NAMESPACE=${NAMESPACE:-}
API_ORIGIN=${API_ORIGIN:-}
load_pid=

for name in EXPECTED_CONTEXT NAMESPACE API_ORIGIN; do
  if [ -z "${!name:-}" ]; then
    echo ">> ERREUR: $name est requis" >&2
    exit 1
  fi
done

restore() {
  status=$?
  trap - EXIT
  if [ -n "$load_pid" ]; then
    kill -- "-$load_pid" 2>/dev/null || true
    wait "$load_pid" 2>/dev/null || true
  fi
  kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" apply \
    -f k8s/server/server.hpa.yaml >/dev/null

  for _ in $(seq 1 60); do
    desired=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
      get hpa/server -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)
    [ "$desired" = 2 ] && break
    sleep 5
  done
  if [ "$desired" != 2 ]; then
    echo ">> ERREUR: le HPA nominal n'est pas revenu à 2 réplicas" >&2
    status=1
  fi
  kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
    rollout status deployment/server --timeout=180s >/dev/null || status=1
  exit "$status"
}
trap restore EXIT

initial=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  get deployment/server -o jsonpath='{.status.readyReplicas}')
[ "$initial" = 2 ]

kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  patch hpa/server --type merge \
  -p '{"spec":{"maxReplicas":3,"behavior":{"scaleUp":{"stabilizationWindowSeconds":0},"scaleDown":{"stabilizationWindowSeconds":0}},"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":1}}}]}}' \
  >/dev/null

setsid env DURATION=120 CONCURRENCY=20 WEB_URL="${API_ORIGIN%/}/health" \
  ./scripts/load.sh >/dev/null 2>&1 &
load_pid=$!

scaled=0
for _ in $(seq 1 48); do
  desired=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
    get hpa/server -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)
  ready=$(kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
    get deployment/server -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  if [ "$desired" = 3 ] && [ "$ready" = 3 ]; then
    scaled=1
    break
  fi
  sleep 5
done

[ "$scaled" -eq 1 ]
curl --fail --show-error --silent "${API_ORIGIN%/}/health" >/dev/null
printf '>> HPA scale event proven: ready replicas 2 -> 3\n'
