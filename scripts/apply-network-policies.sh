#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_CONTEXT=${EXPECTED_CONTEXT:-}
NAMESPACE=${NAMESPACE:-}
API_ORIGIN=${API_ORIGIN:-}
rollback_armed=0

for name in EXPECTED_CONTEXT NAMESPACE API_ORIGIN; do
  if [ -z "${!name:-}" ]; then
    echo ">> ERREUR: $name est requis" >&2
    exit 1
  fi
done

if [ "$(kubectl config current-context)" != "$EXPECTED_CONTEXT" ]; then
  echo ">> ERREUR: contexte kubectl inattendu" >&2
  exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release-state.sh
source "$script_dir/release-state.sh"
state_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/opswarden-network-policy.XXXXXX")
release_state_init "$EXPECTED_CONTEXT" "$state_dir"

rollback() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "$rollback_armed" -eq 1 ]; then
    echo ">> Échec du durcissement réseau; restauration des policies précédentes" >&2
    if ! release_state_restore; then
      echo ">> ATTENTION: la restauration d'au moins une NetworkPolicy a échoué" >&2
      status=1
    fi
  fi
  kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
    delete pod network-policy-allow-postgres network-policy-deny-postgres \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  release_state_cleanup
  exit "$status"
}
trap rollback EXIT

policies=(
  "$NAMESPACE:allow-cluster-dns"
  "$NAMESPACE:default-deny"
  "$NAMESPACE:server"
  "$NAMESPACE:client-web"
  "$NAMESPACE:postgres"
  "$NAMESPACE:redis"
  "$NAMESPACE:cert-manager-http01-solver"
  "$NAMESPACE:postgres-role-bootstrap"
  "$NAMESPACE:postgres-backup"
  "$NAMESPACE:postgres-backup-verify"
  "kube-public:traefik-public-ingress"
)

for policy in "${policies[@]}"; do
  namespace=${policy%%:*}
  name=${policy#*:}
  release_state_snapshot "$namespace" networkpolicy "$name"
done

rollback_armed=1
echo ">> Application ordonnée des autorisations réseau"
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" apply \
  -f k8s/network-policies/allow-cluster-dns.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" apply \
  -f k8s/network-policies/workloads.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace kube-public apply \
  -f k8s/network-policies/traefik.yaml
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" apply \
  -f k8s/network-policies/default-deny.yaml

kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  rollout status deployment/server --timeout=180s

api_origin=${API_ORIGIN%/}
API_ONLY=1 \
  WEB_URL="$api_origin/health" \
  ABOUT_URL="$api_origin/about.json" \
  WS_URL="$api_origin/ws" \
  ./scripts/smoke.sh

auth_status=$(curl --show-error --silent -o /dev/null -w '%{http_code}' \
  "$api_origin/api/auth/sign-in" \
  -H 'Content-Type: application/json' \
  --data-binary '{"email":"network-policy-proof@example.invalid","password":"invalid"}')
[ "$auth_status" = 401 ]

postgres_image=postgres@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15

kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" run \
  network-policy-allow-postgres \
  --image="$postgres_image" \
  --labels=app=postgres-backup \
  --restart=Never \
  --command -- sh -ec 'pg_isready -h postgres -p 5432 -t 5'
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" wait \
  --for=jsonpath='{.status.phase}'=Succeeded \
  pod/network-policy-allow-postgres --timeout=90s

kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" run \
  network-policy-deny-postgres \
  --image="$postgres_image" \
  --labels=network-policy-proof=denied \
  --restart=Never \
  --command -- sh -ec \
  'if pg_isready -h postgres -p 5432 -t 5; then echo "unexpected database access" >&2; exit 1; else echo "database access denied"; fi'
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" wait \
  --for=jsonpath='{.status.phase}'=Succeeded \
  pod/network-policy-deny-postgres --timeout=90s

rollback_armed=0
printf '>> NetworkPolicies vérifiées: public=ok database=allowed-by-role default=denied\n'
