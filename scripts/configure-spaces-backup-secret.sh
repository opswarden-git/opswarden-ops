#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
target="$repo_root/k8s/postgres/postgres-backup.secret.sops.yaml"
sops_config="$repo_root/.sops.yaml"
identity_file=${SOPS_AGE_KEY_FILE:-"$HOME/.config/sops/age/keys.txt"}
plain_file=
encrypted_file=
access_key=
secret_key=
secret_key_confirmation=
backup_password=
obscured_backup_password=

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  access_key=
  secret_key=
  secret_key_confirmation=
  backup_password=
  obscured_backup_password=
  if [ -n "$plain_file" ]; then
    rm -f -- "$plain_file"
  fi
  if [ -n "$encrypted_file" ]; then
    rm -f -- "$encrypted_file"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

fail() {
  echo ">> ERREUR: $*" >&2
  exit 1
}

for command in age-keygen base64 openssl rclone sops; do
  command -v "$command" >/dev/null 2>&1 \
    || fail "$command est introuvable; lancez ce script avec nix develop"
done

[ -f "$sops_config" ] || fail ".sops.yaml est introuvable"
[ -f "$identity_file" ] || fail "identité age introuvable: $identity_file"
[ "$(stat -c '%a' "$identity_file")" = 600 ] \
  || fail "les permissions de l'identité age doivent être 600"

local_recipient=$(age-keygen -y "$identity_file")
grep -Fq -- "$local_recipient" "$sops_config" \
  || fail "l'identité age locale ne correspond à aucun destinataire SOPS"

echo "Cette commande va remplacer uniquement:"
echo "  ${target#"$repo_root/"}"
echo "Elle ne contactera ni DigitalOcean ni Kubernetes."
printf "Continuer ? [y/N] " >/dev/tty
IFS= read -r confirmation </dev/tty
case "$confirmation" in
  y|Y|yes|YES|oui|OUI) ;;
  *) echo ">> Annulé"; exit 0 ;;
esac

printf "Spaces Access Key (saisie masquée): " >/dev/tty
IFS= read -r -s access_key </dev/tty
printf '\n' >/dev/tty
[ -n "$access_key" ] || fail "l'Access Key est vide"

printf "Spaces Secret Key (saisie masquée): " >/dev/tty
IFS= read -r -s secret_key </dev/tty
printf '\n' >/dev/tty
[ -n "$secret_key" ] || fail "la Secret Key est vide"

printf "Confirmez la Spaces Secret Key: " >/dev/tty
IFS= read -r -s secret_key_confirmation </dev/tty
printf '\n' >/dev/tty
[ "$secret_key" = "$secret_key_confirmation" ] \
  || fail "les deux Secret Keys ne correspondent pas"

umask 077
plain_file=$(mktemp "${TMPDIR:-/tmp}/opswarden-backup-secret.XXXXXX")
encrypted_file=$(mktemp "$repo_root/k8s/postgres/.postgres-backup.secret.sops.yaml.XXXXXX")

backup_password=$(openssl rand -base64 48)
obscured_backup_password=$(printf '%s' "$backup_password" | rclone obscure -)

access_key_b64=$(printf '%s' "$access_key" | base64 --wrap=0)
secret_key_b64=$(printf '%s' "$secret_key" | base64 --wrap=0)
backup_password_b64=$(printf '%s' "$obscured_backup_password" | base64 --wrap=0)

{
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: Secret' \
    'metadata:' \
    '  name: postgres-backup-secret' \
    '  namespace: default' \
    'type: Opaque' \
    'data:'
  printf '  RCLONE_CONFIG_S3_ACCESS_KEY_ID: %s\n' "$access_key_b64"
  printf '  RCLONE_CONFIG_S3_SECRET_ACCESS_KEY: %s\n' "$secret_key_b64"
  printf '  RCLONE_CONFIG_BACKUP_PASSWORD: %s\n' "$backup_password_b64"
} >"$plain_file"

sops --config "$sops_config" --encrypt --input-type yaml --output-type yaml \
  --filename-override "$target" "$plain_file" >"$encrypted_file"

SOPS_AGE_KEY_FILE="$identity_file" sops --decrypt \
  --input-type yaml --output-type yaml "$encrypted_file" >/dev/null
grep -q '^sops:' "$encrypted_file" \
  || fail "le fichier produit ne contient pas de métadonnées SOPS"
grep -q 'ENC\[AES256_GCM' "$encrypted_file" \
  || fail "le fichier produit ne semble pas chiffré"
if grep -Fq -- "$access_key_b64" "$encrypted_file" \
  || grep -Fq -- "$secret_key_b64" "$encrypted_file" \
  || grep -Fq -- "$backup_password_b64" "$encrypted_file"; then
  fail "une valeur sensible est restée visible dans le fichier produit"
fi

mv -- "$encrypted_file" "$target"
encrypted_file=
chmod 600 "$target"

echo ">> Secret Spaces chiffré et validé:"
echo "   ${target#"$repo_root/"}"
echo ">> Aucun secret n'a été affiché, envoyé au cluster ou transmis à DigitalOcean."
