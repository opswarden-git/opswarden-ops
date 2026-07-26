# Runbook : Rotation du Credential PostgreSQL (Étape 2C)

Ce runbook détaille les opérations interactives pour finaliser la migration SCRAM et la rotation du mot de passe de l'utilisateur `postgres`.
L'intervention est **manuelle et humaine** pour éviter la fuite du mot de passe dans les logs ou les historiques d'agents.

> [!CAUTION]
> Assurez-vous d'avoir une sauvegarde vérifiée ou un snapshot avant d'effectuer ces opérations sur un cluster de production. Ne collez **jamais** le nouveau mot de passe dans le terminal sans interface masquée.

---

## 2C.0 — Audit et Préparation

Vérifiez l'état de la base de données et des règles d'authentification avant toute modification :

```bash
export EXPECTED_CONTEXT=minikube
export NAMESPACE=default

kubectl --context "$EXPECTED_CONTEXT" \
  --namespace "$NAMESPACE" \
  exec deployment/postgres -- \
  sh -ec '
    psql -X -v ON_ERROR_STOP=1 \
      -U "$POSTGRES_USER" \
      -d "$POSTGRES_DB" \
      -c "SHOW password_encryption;" \
      -c "SHOW hba_file;" \
      -c "SELECT rule_number, line_number, type, database, user_name, address, auth_method, error
          FROM pg_hba_file_rules
          ORDER BY rule_number;"
  '
```

### Sauvegarde logique (Recommandé)

Sur Minikube ou avant toute opération délicate, réalisez une sauvegarde :

```bash
BACKUP_DIR="$HOME/.local/share/opswarden/backups"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/postgres-before-rotation-$(date +%Y%m%d-%H%M%S).dump"

kubectl --context "$EXPECTED_CONTEXT" \
  --namespace "$NAMESPACE" \
  exec deployment/postgres -- \
  sh -ec '
    pg_dump \
      -U "$POSTGRES_USER" \
      -d "$POSTGRES_DB" \
      --format=custom
  ' > "$BACKUP_FILE"

chmod 600 "$BACKUP_FILE"
test -s "$BACKUP_FILE"
pg_restore --list "$BACKUP_FILE" >/dev/null
echo "Backup réussi : $BACKUP_FILE"
```

*Note : La commande de restauration (à titre documentaire) serait :*
```bash
# cat "$BACKUP_FILE" | kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" exec -i deployment/postgres -- pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" -1
```

---

## 2C.1 — Rotation Interactive du Rôle

> [!IMPORTANT]
> Lancez cette commande dans **votre propre terminal** et **gardez la session ouverte** en cas de problème de synchronisation pour un éventuel rollback.

```bash
kubectl --context "$EXPECTED_CONTEXT" \
  --namespace "$NAMESPACE" \
  exec -it deployment/postgres -- \
  sh -lc '
    exec psql -X -v ON_ERROR_STOP=1 \
      -U "$POSTGRES_USER" \
      -d "$POSTGRES_DB"
  '
```

Dans l'invite `psql`, appliquez SCRAM et le nouveau mot de passe :

```sql
SELECT current_user;
SHOW password_encryption;

-- Forcer SCRAM-SHA-256
SET password_encryption = 'scram-sha-256';

-- Saisie interactive (protégée) du nouveau mot de passe
\password
```

### Preuve du rejet de l'ancien credential

Dans un **autre terminal**, confirmez que le Pod courant (qui a encore l'ancien mot de passe injecté dans son environnement) ne peut plus s'authentifier :

```bash
if kubectl --context "$EXPECTED_CONTEXT" \
  --namespace "$NAMESPACE" \
  exec deployment/postgres -- \
  sh -ec '
    PGPASSWORD="$POSTGRES_PASSWORD" \
      psql -w \
        -h 127.0.0.1 \
        -p 5432 \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        -tAc "SELECT 1"
  '
then
  echo "ERREUR : l’ancien credential est encore accepté."
else
  echo "Ancien credential refusé : OK"
fi
```
*(L'erreur retournée est normale, elle indique une désynchronisation volontaire)*

---

## 2C.2 — Cohérence SOPS et Kubernetes

1. Éditez localement le fichier SOPS de manière interactive pour y inscrire le nouveau mot de passe :
```bash
EDITOR='vim -n' sops k8s/postgres/postgres.secret.sops.yaml
```

2. Validez et appliquez le nouveau Secret depuis l'environnement Nix :
```bash
nix develop -c make secrets-dry-run \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE"

nix develop -c make secrets-apply \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE" \
  CONFIRM=APPLY_POSTGRES_SECRET
```

3. Déclenchez un redémarrage contrôlé du Deployment pour injecter la nouvelle variable d'environnement :
```bash
kubectl --context "$EXPECTED_CONTEXT" \
  --namespace "$NAMESPACE" \
  rollout restart deployment/postgres

kubectl --context "$EXPECTED_CONTEXT" \
  --namespace "$NAMESPACE" \
  rollout status deployment/postgres \
  --timeout=180s
```

4. Validez l'accès TCP avec le nouveau credential :
```bash
kubectl --context "$EXPECTED_CONTEXT" \
  --namespace "$NAMESPACE" \
  exec deployment/postgres -- \
  sh -ec '
    PGPASSWORD="$POSTGRES_PASSWORD" \
      psql -w \
        -h 127.0.0.1 \
        -p 5432 \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        -tAc "SELECT 1"
  '
```
*(Résultat attendu : `1`)*

5. Vérifiez la persistance des données :
```bash
kubectl --context "$EXPECTED_CONTEXT" \
  --namespace "$NAMESPACE" \
  exec deployment/postgres -- \
  sh -ec '
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -c "SELECT * FROM test_persist;"
  '
```

6. Retournez dans votre session `psql` d'administration toujours ouverte et vérifiez que le vérificateur stocké est bien SCRAM :
```sql
SELECT rolpassword LIKE 'SCRAM-SHA-256$%' AS uses_scram
FROM pg_authid
WHERE rolname = current_user;
```
*(Résultat attendu : `t`)*

Vous pouvez fermer la session `psql` d'administration si tous ces tests sont au vert.

### Validation finale et Commit

Il est **impératif** de versionner le nouveau Secret chiffré dans Git pour éviter qu'un futur déploiement ne réintroduise l'ancien mot de passe compromis :

```bash
git add k8s/postgres/postgres.secret.sops.yaml
git status --short
git diff --cached --check
git commit -m "ops: rotate postgres administrative credential"
```
*(Vérifiez avec `git status --short` que seul le fichier SOPS chiffré a changé)*

> **Note sur la migration SCRAM** : Cette étape 2C crée un verifier SCRAM pour le rôle `postgres` et stocke le mot de passe sous ce format. La conversion explicite du fichier `pg_hba.conf` (règles `md5` vers `scram-sha-256`) fera l'objet d'une future **Étape 2D** séparée, après l'audit des clients.

---

## ⚠️ Rollback

Si le déploiement échoue ou que l'authentification est bloquée, **ne revenez jamais à l'ancien mot de passe compromis**.
Gardez la session `psql` ouverte tant que le nouveau Pod n'a pas réussi son test TCP et que le Secret SOPS n'est pas commité. Ne fermez jamais cette session après le simple succès de `secrets-apply`.

Utilisez les diagnostics suivants :

* **PostgreSQL modifié, SOPS non appliqué ou divergent** : Utilisez la session `psql` restée ouverte pour définir un *troisième* mot de passe de secours, puis alignez SOPS dessus.
* **Secret appliqué avec une mauvaise valeur** : Corrigez le fichier SOPS pour correspondre au mot de passe de la base et réappliquez-le.
* **Rollout défaillant mais Secret correct** : Ne changez pas le mot de passe ; diagnostiquez le Pod et réparez le Deployment.
* **Session de secours perdue** : Vérifiez l'accès de l'utilisateur `postgres` via la socket locale du conteneur (accès peer/local non protégé) avant de vous y fier pour rétablir les accès.
