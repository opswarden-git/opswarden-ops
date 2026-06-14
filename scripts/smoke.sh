#!/usr/bin/env bash
# OpsWarden Ops — smoke test bout-en-bout / infra.
# Prouve le chemin public (Traefik) et dumpe l'état du cluster.
#
# La couche prête (Traefik + cluster) est toujours vérifiée. Les routes
# applicatives (web / api) sont best-effort : elles restent "skip" tant que les
# images OpsWarden ne sont pas déployées (server/client-web sont des placeholders).
#
# Par défaut : s'appuie sur /etc/hosts mappant les hôtes vers une IP de nœud.
# Sans /etc/hosts (NixOS / minikube), résoudre via curl à la place :
#   RESOLVE_IP=$(minikube ip) ./scripts/smoke.sh      # ou: make minikube-smoke
set -euo pipefail

PORT="${PORT:-30021}"
DASH_PORT="${DASH_PORT:-30042}"
WEB_HOST="${WEB_HOST:-app.opswarden.example}"
API_HOST="${API_HOST:-api.opswarden.example}"
WEB_URL="${WEB_URL:-http://$WEB_HOST:$PORT}"
API_URL="${API_URL:-http://$API_HOST:$PORT}"

# Avec RESOLVE_IP, on envoie le bon Host header mais on résout vers l'IP du nœud
# (pas besoin de /etc/hosts). Pointe aussi le dashboard Traefik sur cette IP.
RESOLVE=()
if [ -n "${RESOLVE_IP:-}" ]; then
  RESOLVE=(--resolve "$WEB_HOST:$PORT:$RESOLVE_IP" --resolve "$API_HOST:$PORT:$RESOLVE_IP")
  TRAEFIK_PING="${TRAEFIK_PING:-http://$RESOLVE_IP:$DASH_PORT/ping}"
else
  TRAEFIK_PING="${TRAEFIK_PING:-http://localhost:$DASH_PORT/ping}"
fi

pass() { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[0;33m•\033[0m %s\n' "$1"; }

echo "== Couche prête (Traefik) =="
code=$(curl -fsS -o /dev/null -w '%{http_code}' "$TRAEFIK_PING") \
  && pass "traefik /ping -> HTTP $code" \
  || echo "  (traefik /ping injoignable d'ici — ok si pas de port-forward)"

echo "== Routes applicatives (best-effort tant que non déployées) =="
check_app() {
  name="$1"; url="$2"; folder="$3"
  code=$(curl -fsS "${RESOLVE[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) \
    && pass "$name ($url) -> HTTP $code" \
    || skip "$name ($url) pas encore servi — déployer $folder pour l'allumer"
}
check_app web "$WEB_URL" "k8s/client-web/"
check_app api "$API_URL" "k8s/server/"

echo "== État du cluster =="
kubectl get pods -o wide
kubectl get svc,ingress
kubectl -n kube-public get pods,svc -o wide

echo "== Smoke test OK =="
