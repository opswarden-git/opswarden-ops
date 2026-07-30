#!/usr/bin/env bash
# Snapshot and restore the exact Kubernetes resources changed by a release.
# This file is sourced by deploy-production.sh.

declare -a RELEASE_STATE_NAMESPACES=()
declare -a RELEASE_STATE_RESOURCES=()
declare -a RELEASE_STATE_NAMES=()
declare -a RELEASE_STATE_FILES=()
declare -a RELEASE_STATE_EXISTED=()

release_state_init() {
  RELEASE_STATE_CONTEXT=$1
  RELEASE_STATE_DIR=$2
  mkdir -p "$RELEASE_STATE_DIR"
}

release_state_snapshot() {
  local namespace=$1
  local resource=$2
  local name=$3
  local index=${#RELEASE_STATE_NAMES[@]}
  local file="$RELEASE_STATE_DIR/${index}.yaml"
  local existed=0

  if kubectl --context "$RELEASE_STATE_CONTEXT" --namespace "$namespace" \
    get "$resource/$name" -o yaml >"$file" 2>/dev/null; then
    existed=1
  else
    : >"$file"
  fi

  RELEASE_STATE_NAMESPACES+=("$namespace")
  RELEASE_STATE_RESOURCES+=("$resource")
  RELEASE_STATE_NAMES+=("$name")
  RELEASE_STATE_FILES+=("$file")
  RELEASE_STATE_EXISTED+=("$existed")
}

release_state_restore() {
  local index
  for ((index = ${#RELEASE_STATE_NAMES[@]} - 1; index >= 0; index--)); do
    local namespace=${RELEASE_STATE_NAMESPACES[$index]}
    local resource=${RELEASE_STATE_RESOURCES[$index]}
    local name=${RELEASE_STATE_NAMES[$index]}
    if [ "${RELEASE_STATE_EXISTED[$index]}" -eq 1 ]; then
      kubectl --context "$RELEASE_STATE_CONTEXT" --namespace "$namespace" \
        apply -f "${RELEASE_STATE_FILES[$index]}"
    else
      kubectl --context "$RELEASE_STATE_CONTEXT" --namespace "$namespace" \
        delete "$resource/$name" --ignore-not-found
    fi
  done
}

release_state_cleanup() {
  find "$RELEASE_STATE_DIR" -depth -delete
}
