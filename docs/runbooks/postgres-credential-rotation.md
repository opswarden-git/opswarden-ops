# PostgreSQL credential rotation (step 2C)

OpsWarden uses four distinct PostgreSQL identities:

- `opswarden_admin`: bootstrap only, stored in `postgres-secret`;
- `opswarden_owner`: `NOLOGIN` owner of the database and schema;
- `opswarden_migrator`: login used only by the server init container;
- `opswarden_runtime`: DML-only login used by the running API;
- `opswarden_backup`: read-only login used by `pg_dump`.

The role credentials live in `postgres-role-secret`. The migrator and runtime
connection URLs live in separate Secrets so neither workload receives the
other login. All real manifests are encrypted with SOPS; examples contain no
usable credential.

## Preconditions

1. Work from the audited branch with a clean worktree.
2. Verify a recent PostgreSQL backup and its checksum.
3. Set `EXPECTED_CONTEXT` and `NAMESPACE`, then verify the current context.
4. Keep the SOPS/age private key local. Never pass a password as a command-line
   argument, paste it into chat, or print a decrypted Secret.

## Rotation sequence

Generate independent random values locally for the admin, migrator, runtime and
backup logins. Update encrypted values with `sops set --value-stdin`; update the
two database URLs in the same local session so they remain coherent with the
role bundle. Validate without displaying plaintext:

```bash
nix develop -c make secret-dry-run \
  SECRET_FILE=k8s/postgres/postgres-role.secret.sops.yaml \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE"
nix develop -c make secret-dry-run \
  SECRET_FILE=k8s/server/migrator.secret.sops.yaml \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE"
nix develop -c make secret-dry-run \
  SECRET_FILE=k8s/server/server.secret.sops.yaml \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE"
```

Apply the three Secrets, reconcile PostgreSQL, then restart the server:

```bash
for file in \
  k8s/postgres/postgres-role.secret.sops.yaml \
  k8s/server/migrator.secret.sops.yaml \
  k8s/server/server.secret.sops.yaml
do
  nix develop -c make secret-apply \
    SECRET_FILE="$file" \
    EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
    NAMESPACE="$NAMESPACE" \
    CONFIRM=APPLY_SOPS_SECRET
done

nix develop -c make db-roles \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE"

kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  rollout restart deployment/server
kubectl --context "$EXPECTED_CONTEXT" --namespace "$NAMESPACE" \
  rollout status deployment/server --timeout=180s
```

`db-roles` is idempotent. It writes SCRAM verifiers, preserves the `NOLOGIN`
owner, reapplies least-privilege grants and default privileges, and never logs
passwords. The running API skips migrations; only its init container receives
the migrator URL.

## Evidence

Prove all of the following without echoing connection URLs or passwords:

- the bootstrap Job completed;
- the init container completed and both API replicas are Ready;
- runtime DML succeeds but runtime DDL is denied;
- the backup role can read but cannot write;
- all three login verifiers use `SCRAM-SHA-256`;
- a connection attempt with each retired credential is rejected;
- the encrypted files and only the intended manifests are committed.

## Admin credential special case

Changing `POSTGRES_PASSWORD` in a Kubernetes Secret does not alter an existing
database role. Rotate `opswarden_admin` inside an authenticated `psql` session
first, using `\password` (hidden input), then update and apply
`postgres.secret.sops.yaml` before closing that session. On a brand-new empty
volume, the official PostgreSQL entrypoint creates the admin directly from the
new Secret.

Never roll back to a retired password. If reconciliation fails, retain the
authenticated admin session, create a third fresh value, align SOPS with it,
and rerun the dry-run and reconciliation gates.
