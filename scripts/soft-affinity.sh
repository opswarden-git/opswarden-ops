#!/usr/bin/env sh
# Bascule l'anti-affinity des pods entre dure (required, défaut des manifests) et
# souple (preferred) sur les déploiements répliqués — SANS éditer les manifests.
#
# Pourquoi : la base utilise une anti-affinity *required* (vraie HA : un replica
# par nœud). Cela suppose un node pool avec de la marge (nodes > replicas). Sur un
# petit cluster (<=2 nœuds, minikube), "required" laisse les pods en trop en
# Pending et bloque le surge en rolling-update / le scale-up HPA. Lancer ceci
# pour relâcher le temps d'une démo.
#
# Les déploiements applicatifs (server/client-web) sont des placeholders : ils
# sont sautés tant qu'ils n'existent pas. Seul traefik est patché aujourd'hui.
#
# Usage :
#   ./soft-affinity.sh on    # required -> preferred (petits clusters / local)
#   ./soft-affinity.sh off   # preferred -> required (restaure la base)
set -eu

MODE="${1:-}"
[ "$MODE" = "on" ] || [ "$MODE" = "off" ] || {
  echo "usage: $0 on|off" >&2; exit 2; }

# app:namespace — déploiements répliqués avec anti-affinity.
TARGETS="server:default client-web:default traefik:kube-public"

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
    echo ">> skip deploy/$app (ns $ns) — absent (placeholder)"
    continue
  fi
  echo ">> $MODE anti-affinity: deploy/$app (ns $ns)"
  kubectl -n "$ns" patch deployment "$app" --type merge --patch "$(patch_for "$app")"
done

echo ">> fait. Vérifier : kubectl get pods -o wide"
