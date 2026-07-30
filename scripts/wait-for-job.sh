#!/usr/bin/env bash
set -Eeuo pipefail

context=${1:-}
namespace=${2:-}
job=${3:-}
timeout_seconds=${4:-7800}

if [ -z "$context" ] || [ -z "$namespace" ] || [ -z "$job" ]; then
  echo "usage: $0 <context> <namespace> <job> [timeout-seconds]" >&2
  exit 2
fi
if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo ">> ERREUR: timeout invalide" >&2
  exit 2
fi

deadline=$((SECONDS + timeout_seconds))
while :; do
  conditions=$(kubectl --context "$context" --namespace "$namespace" \
    get "job/$job" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{end}')
  case "$conditions" in
    *Complete=True*)
      result=0
      break
      ;;
    *Failed=True*)
      echo ">> ERREUR: job/$job a échoué" >&2
      result=1
      break
      ;;
  esac
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo ">> ERREUR: délai dépassé pour job/$job" >&2
    result=1
    break
  fi
  sleep 5
done

kubectl --context "$context" --namespace "$namespace" \
  logs "job/$job" --all-containers=true || true
exit "$result"
