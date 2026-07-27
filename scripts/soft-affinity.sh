#!/usr/bin/env sh
# Bascule l'anti-affinity des pods entre souple (preferred, défaut des manifests)
# et dure (required) sur les déploiements répliqués — sans éditer les manifests.
#
# Le mode required garantit un replica par nœud mais exige de la capacité libre
# pendant les rolling updates et le scale-up HPA. Le mode preferred conserve la
# disponibilité si le cluster manque temporairement de nœuds.
#
# Usage :
#   ./soft-affinity.sh on    # required -> preferred (petits clusters / local)
#   ./soft-affinity.sh off   # preferred -> required (restaure la base)
set -eu

MODE="${1:-}"
[ "$MODE" = "on" ] || [ "$MODE" = "off" ] || {
  echo "usage: $0 on|off" >&2; exit 2; }

# app:namespace — déploiements répliqués avec anti-affinity.
APP_NAMESPACE=${NAMESPACE:-default}
TARGETS="server:${APP_NAMESPACE} client-web:${APP_NAMESPACE} traefik:kube-public"

patch_for() {
  app="$1"
  if [ "$MODE" = "on" ]; then
    cat <<EOF
{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{
  "requiredDuringSchedulingIgnoredDuringExecution":null,
  "preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"podAffinityTerm":{
    "labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["$app"]}]},
    "topologyKey":"kubernetes.io/hostname"}}]}}}}}}
EOF
  else
    cat <<EOF
{"spec":{"template":{"spec":{"affinity":{"podAntiAffinity":{
  "preferredDuringSchedulingIgnoredDuringExecution":null,
  "requiredDuringSchedulingIgnoredDuringExecution":[{
    "labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["$app"]}]},
    "topologyKey":"kubernetes.io/hostname"}]}}}}}}
EOF
  fi
}

for t in $TARGETS; do
  app="${t%%:*}"; ns="${t##*:}"
  if ! kubectl -n "$ns" get deployment "$app" >/dev/null 2>&1; then
    echo ">> skip deploy/$app (ns $ns) — absent"
    continue
  fi
  echo ">> $MODE anti-affinity: deploy/$app (ns $ns)"
  kubectl -n "$ns" patch deployment "$app" --type merge --patch "$(patch_for "$app")"
done

echo ">> fait. Vérifier : kubectl get pods -o wide"
