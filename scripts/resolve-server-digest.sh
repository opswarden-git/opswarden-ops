#!/usr/bin/env bash
set -euo pipefail

# Resolve a release version to an immutable GHCR digest reference.
#
# Deploys must pin a digest, never a mutable tag. Having a human copy a sha256
# out of a release summary and paste it into a workflow input is the one step in
# the chain where a silent mistake deploys the wrong image, so the lookup is done
# here instead.
#
# usage: resolve-server-digest.sh <version> [owner] [package]
#   e.g. resolve-server-digest.sh 1.0.7

version=${1:-}
owner=${2:-opswarden-git}
package=${3:-opswarden-server}

if [ -z "$version" ]; then
  echo "usage: ${0##*/} <version> [owner] [package]" >&2
  exit 1
fi

# Accept both v1.0.7 and 1.0.7; the published tag carries no prefix.
version=${version#v}

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid semantic version: $version" >&2
  exit 1
fi

repository="${owner,,}/${package,,}"

token=$(curl --fail --silent --show-error \
  "https://ghcr.io/token?scope=repository:${repository}:pull&service=ghcr.io" |
  jq -r '.token')

if [ -z "$token" ] || [ "$token" = null ]; then
  echo "Could not obtain a GHCR pull token for ${repository}" >&2
  exit 1
fi

digest=$(curl --fail --silent --show-error --head \
  --header "Authorization: Bearer ${token}" \
  --header 'Accept: application/vnd.oci.image.index.v1+json' \
  --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
  --header 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  --header 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  "https://ghcr.io/v2/${repository}/manifests/${version}" |
  tr -d '\r' |
  awk 'tolower($1) == "docker-content-digest:" { print $2 }')

if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "No usable digest for ${repository}:${version} (got '${digest}')" >&2
  exit 1
fi

echo "ghcr.io/${repository}@${digest}"
