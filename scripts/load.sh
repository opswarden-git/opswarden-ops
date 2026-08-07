#!/usr/bin/env bash
# OpsWarden Ops — générateur de charge pour déclencher l'autoscaling (HPA).
# Suivre l'effet dans un autre terminal :
#   watch -n2 kubectl get hpa,deploy server
#   kubectl get pods -l app=server -o wide -w
#
# Usage :
#   ./scripts/load.sh                  # 60s, auto-détecte hey/ab, sinon boucle curl
#   DURATION=120 CONCURRENCY=100 ./scripts/load.sh
#   WEB_URL=http://app.opswarden.dev:30021 ./scripts/load.sh
set -euo pipefail

WEB_URL="${WEB_URL:-http://app.opswarden.dev:30021}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-50}"

echo ">> Cible :       $WEB_URL"
echo ">> Durée :       ${DURATION}s"
echo ">> Concurrence : $CONCURRENCY"

if command -v hey >/dev/null 2>&1; then
  echo ">> Avec hey"
  hey -z "${DURATION}s" -c "$CONCURRENCY" "$WEB_URL"
elif command -v ab >/dev/null 2>&1; then
  echo ">> Avec ApacheBench (ab) — ~$((CONCURRENCY * DURATION * 10)) requêtes"
  ab -t "$DURATION" -c "$CONCURRENCY" "$WEB_URL/"
else
  echo ">> Pas de hey/ab — repli sur une boucle curl parallèle"
  end=$(( $(date +%s) + DURATION ))
  for _ in $(seq 1 "$CONCURRENCY"); do
    ( while [ "$(date +%s)" -lt "$end" ]; do curl -fsS "$WEB_URL" -o /dev/null || true; done ) &
  done
  wait
fi

echo ">> Charge terminée. Vérifier : kubectl get hpa"
