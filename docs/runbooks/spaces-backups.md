# Sauvegardes PostgreSQL dans DigitalOcean Spaces

Le bucket de production est privé et dédié aux sauvegardes:

- bucket: `opswarden-production-backups`;
- région: `fra1`;
- endpoint S3 régional: `https://fra1.digitaloceanspaces.com`;
- préfixe: `production/postgres`;
- rétention: `30d`.

Objectifs opérationnels:

- RPO cible: 26 heures, soit une exécution quotidienne plus deux heures de
  marge avant alerte;
- RTO cible: 4 heures pour récupérer les objets, restaurer PostgreSQL dans un
  environnement propre et effectuer la rotation des identifiants globaux;
- une sauvegarde n'est récupérable que si l'identité age correspondant au
  manifeste SOPS reste disponible hors du cluster.

La clé Spaces doit être limitée à ce seul bucket avec les permissions
`Read/Write/Delete`. Ne passez jamais l'Access Key ou la Secret Key en argument
de commande, dans un fichier `.env`, dans un ticket ou dans un chat.

## Chiffrer les identifiants

Depuis la racine de `opswarden-ops`, lancez:

```bash
nix develop -c make backup-secret-configure
```

La commande lit les deux valeurs avec l'écho du terminal désactivé, confirme la
Secret Key, génère un mot de passe indépendant pour `rclone crypt`, puis écrit
uniquement le manifeste SOPS chiffré
`k8s/postgres/postgres-backup.secret.sops.yaml`. Elle vérifie que l'identité age
locale peut le déchiffrer avant de remplacer le manifeste existant. Elle ne
contacte ni DigitalOcean ni Kubernetes.

Inspectez ensuite uniquement les changements chiffrés:

```bash
git diff --stat
git diff -- k8s/postgres/postgres-backup.secret.sops.yaml
make check-plaintext-secret-manifests
```

Ne lancez pas `sops -d` dans un terminal enregistré ou partagé.

## Appliquer et prouver la restauration

Ces opérations ciblent la production et doivent être lancées séparément après
revue du diff, avec le contexte et le namespace réels:

```bash
nix develop -c make secret-dry-run \
  SECRET_FILE=k8s/postgres/postgres-backup.secret.sops.yaml \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE"

nix develop -c make secret-apply \
  SECRET_FILE=k8s/postgres/postgres-backup.secret.sops.yaml \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE" \
  CONFIRM=APPLY_SOPS_SECRET

nix develop -c make backup-enable \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE" \
  BACKUP_BUCKET=opswarden-production-backups \
  BACKUP_ENDPOINT=https://fra1.digitaloceanspaces.com \
  CONFIRM=ENABLE_BACKUPS

nix develop -c make backup-run \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE"

nix develop -c make backup-verify \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE" \
  CONFIRM=VERIFY_LATEST_BACKUP
```

Un upload réussi ne suffit pas: le chantier n'est terminé qu'après le contrôle
du checksum et la restauration réussie du dernier dump dans le PostgreSQL
isolé du Job de vérification.

## Supervision

kube-state-metrics est limité aux `Jobs` et `CronJobs` du namespace `default`.
Prometheus alerte si le CronJob est absent ou suspendu, si un Job planifié
échoue, si aucune exécution planifiée n'a jamais réussi après 26 heures, ou si
le dernier succès dépasse 26 heures.

La vérification complète par téléchargement reste quotidienne pour privilégier
l'intégrité tant que la base est petite. Réévaluez ce choix si les frais de
récupération ou la taille du dump deviennent significatifs. Vérifiez aussi
périodiquement qu'une exécution est réellement créée à `02:17 UTC` et que les
objets âgés de plus de `30d` sont supprimés.

Conservez une copie chiffrée ou matérielle de
`~/.config/sops/age/keys.txt` dans un emplacement de récupération distinct. Ne
la commitez pas, ne la placez pas dans le cluster et ne la réutilisez pas comme
secret applicatif. Testez périodiquement cette copie en déchiffrant le manifeste
SOPS dans une machine isolée sans afficher son contenu.
