#!/usr/bin/env bash
# OpsWarden Ops — smoke test bout-en-bout / infra.
# Prouve le chemin public (Traefik) et dumpe l'état du cluster.
#
# Vérifie Traefik, le rendu Next.js, le proxy Next -> Rust et le handshake
# WebSocket same-origin. Le test est strict : une route absente fait échouer la
# commande au lieu de masquer un déploiement incomplet.
#
# Par défaut : s'appuie sur /etc/hosts mappant les hôtes vers une IP de nœud.
# Sans /etc/hosts (NixOS / minikube), résoudre via curl à la place :
#   RESOLVE_IP=$(minikube ip) ./scripts/smoke.sh      # ou: make minikube-smoke
set -euo pipefail

PORT="${PORT:-30021}"
WEB_HOST="${WEB_HOST:-app.opswarden.dev}"
WEB_URL="${WEB_URL:-http://$WEB_HOST:$PORT/en}"
ABOUT_URL="${ABOUT_URL:-http://$WEB_HOST:$PORT/about.json}"
WS_URL="${WS_URL:-http://$WEB_HOST:$PORT/ws}"

# Avec RESOLVE_IP, on envoie le bon Host header mais on résout vers l'IP du nœud
# (pas besoin de /etc/hosts). Pointe aussi le dashboard Traefik sur cette IP.
RESOLVE=()
if [ -n "${RESOLVE_IP:-}" ]; then
  RESOLVE=(--resolve "$WEB_HOST:$PORT:$RESOLVE_IP")
  TRAEFIK_PING="${TRAEFIK_PING:-http://$RESOLVE_IP:$PORT/ping}"
else
  TRAEFIK_PING="${TRAEFIK_PING:-http://$WEB_HOST:$PORT/ping}"
fi

pass() { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }

if [ "${API_ONLY:-0}" != "1" ]; then
  echo "== Couche prête (Traefik) =="
  code=$(curl -fsS -o /dev/null -w '%{http_code}' "$TRAEFIK_PING")
  pass "traefik /ping -> HTTP $code"
fi

echo "== Routes applicatives =="
code=$(curl -fsS "${RESOLVE[@]}" -o /dev/null -w '%{http_code}' "$WEB_URL")
if [ "${API_ONLY:-0}" = "1" ]; then
  pass "API health ($WEB_URL) -> HTTP $code"
else
  pass "client web ($WEB_URL) -> HTTP $code"
fi

about_file=$(mktemp)
trap 'rm -f "$about_file"' EXIT
curl -fsS "${RESOLVE[@]}" -o "$about_file" "$ABOUT_URL"
jq -e '
  (.server | type == "object") and
  (.server.services | type == "array") and
  (.server.services | length > 0) and
  all(.server.services[];
    (.name | type == "string") and
    (.actions | type == "array") and
    (.reactions | type == "array")
  )
' "$about_file" >/dev/null
pass "catalogue Rust ($ABOUT_URL) -> contrat valide"

set +e
ws_code=$(curl "${RESOLVE[@]}" --http1.1 --max-time 2 --silent --output /dev/null \
  --write-out '%{http_code}' \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: SGVsbG9PcHNXQXJkZW4hIQ==' \
  "$WS_URL")
ws_exit=$?
set -e
if [ "$ws_code" != "101" ] || { [ "$ws_exit" -ne 0 ] && [ "$ws_exit" -ne 28 ]; }; then
  echo ">> ERREUR: handshake WebSocket attendu 101, reçu $ws_code (curl=$ws_exit)" >&2
  exit 1
fi
pass "WebSocket ($WS_URL) -> HTTP 101"

echo "== État du cluster =="
KUBE_ARGS=()
if [ -n "${EXPECTED_CONTEXT:-}" ]; then
  KUBE_ARGS+=(--context "$EXPECTED_CONTEXT")
fi
APP_NAMESPACE="${NAMESPACE:-default}"
kubectl "${KUBE_ARGS[@]}" --namespace "$APP_NAMESPACE" get pods -o wide
kubectl "${KUBE_ARGS[@]}" --namespace "$APP_NAMESPACE" get svc,ingress
kubectl "${KUBE_ARGS[@]}" --namespace kube-public get pods,svc -o wide

echo "== Smoke test OK =="
