# Atomic release and migration recovery

## Release unit

`scripts/deploy-production.sh` treats the immutable server image and every
modified ConfigMap, Deployment, NetworkPolicy, HPA and PDB as one guarded
release unit. Before the first apply, it stores the live representation of each
resource in a private temporary directory. Every resource receives the same
`opswarden.dev/release` annotation.

If an apply, rollout or smoke proof fails, the script restores the snapshots in
reverse order, waits for the previous server and restarts Prometheus and
Grafana against their restored ConfigMaps. Resources introduced by the failed
release are deleted when they did not exist in the snapshot. PersistentVolume
Claims are deliberately not deleted or rolled back.

The mechanism is a guarded deployment transaction, not a Kubernetes or database
transaction. Do not run two production deployments concurrently; the GitHub
workflow enforces this with the `opswarden-production` concurrency group.

## Forward-only SQL contract

Database migrations use expand/contract:

1. **Expand:** add nullable columns, new tables, indexes or compatible
   structures. The previous and next server images must both work.
2. Deploy and observe the new application while the previous image remains a
   valid rollback target.
3. Backfill data through a bounded, restartable operation.
4. **Contract:** remove old structures only in a later release, after the
   compatibility window and a verified encrypted backup.

Automatic SQL down-migrations are forbidden. A release that needs `DROP`,
column/type narrowing, destructive rename, `TRUNCATE` or irreversible data
rewrites must be split and explicitly reviewed. If an application rollout
fails after an expand migration, restore the previous image and leave the
additive schema in place.

If a contract migration itself fails, stop automatic rollback, preserve the
database and follow the Spaces restore runbook. Restoring a database is a
disaster-recovery operation, not a normal deployment rollback.

## Proof

For every production release, retain:

- release ID and immutable server digest;
- pre-deployment backup Job name;
- resource annotations after the rollout;
- application, WebSocket, Prometheus and logging smoke results;
- migration delta classification: none, expand, backfill or contract.
