# Production deployment audit

Snapshot: 2026-07-30. This document records both verified production evidence
and the remaining infrastructure gaps. It is not a cloud certification.

## Architecture decision

The nominal production topology is:

- `opswarden.dev`: marketing site on Vercel (`opswarden-website`);
- `app.opswarden.dev`: `client-web` on Vercel;
- `api.opswarden.dev`: Rust HTTP API and WebSocket through Traefik on DOKS;
- PostgreSQL, Redis and encrypted backup jobs on DOKS;
- Terraform state and encrypted PostgreSQL backups in separate Spaces paths or
  buckets with separate restricted credentials.

The Kubernetes `client-web` Deployment is retained only for local and optional
self-hosted operation. Production CD deploys the Rust image only. Vercel must
build from `client-web` with:

```text
OPSWARDEN_API_ORIGIN=https://api.opswarden.dev
NEXT_PUBLIC_WS_URL=wss://api.opswarden.dev/ws
```

## Reproduced evidence

- application release gate `30562337570` passes Rust formatting, strict Clippy,
  backend tests and coverage, web quality and tests, desktop packaging and the
  Playwright critical path;
- release `v1.0.12` publishes the attested server image by immutable digest
  `sha256:6468bd3eb43b410ccc911c3dab0cade0696180932e765559df34bd88f2ead026`;
- DOKS runs two ready server replicas with completed migration init containers,
  the dedicated runtime Secret and zero container restarts;
- PostgreSQL owner, migrator, runtime and backup roles were reconciled by the
  production bootstrap Job after a validated custom-format database dump;
- Let's Encrypt serves a certificate for `api.opswarden.dev`, and the public
  health, `/about.json` and WebSocket `101` checks pass through Traefik;
- production CD run `30563381853` reproduced the immutable rollout and smoke
  checks from GitHub Actions;
- observability CD run `30564398461` proves API HTTP 200, WebSocket 101,
  Prometheus target `up=1` and three loaded Alertmanager rules;
- a production smoke using the official Alertmanager `v0.32.1` image pinned by
  digest delivered firing and resolved as two durable runs, with metrics
  `accepted +2` and `failed +0`; all temporary resources were removed;
- bearer-token rotation and rollback reject each stale secret with HTTP 401 and
  accept the active secret with HTTP 202 while preserving connection identity.
- hardening run `30565376997` installs two Metrics Server `v0.8.1` replicas
  pinned by multi-architecture digest and proves node, pod and HPA CPU metrics;
- hardening run `30565632048` observes a controlled server HPA scale event from
  two to three ready replicas, then restores the nominal policy. Follow-up run
  `30565794256` proves `replicas=2`, `desired=2` and a healthy public API.
- hardening run `30566269859` applies the complete application-namespace
  NetworkPolicy set in safe order. Public HTTP, `/about.json` and WebSocket
  remain available; the backup role reaches PostgreSQL while an unlabeled pod
  is denied.
- deployment run `30566406249` rolls the immutable server from `v1.0.12` back
  to `v1.0.11`; run `30566497276` restores `v1.0.12`. Both pass rollout,
  application and Prometheus proofs. There is no SQL migration delta between
  the two releases.
- Spaces Job `postgres-backup-manual-20260730191627` uploads an encrypted
  PostgreSQL dump and verifies all three remote files by downloading them;
  isolated Job `postgres-backup-verify-fv75q` validates SHA-256 and gzip,
  restores the schema and data, and proves the `users` relation plus successful
  SQLx migration records.

## Findings corrected on the audited branches

1. The self-hosted web image no longer bakes `ws://localhost:8080/ws`; an empty
   setting uses the browser-origin fallback and Compose remains explicit.
2. Namespaced manifests no longer force `default`; deployment commands select
   the reviewed namespace. SOPS streams remove legacy namespace metadata after
   decryption without modifying encrypted files.
3. Production now deploys only Rust and uses distinct frontend and API origins.
4. Traefik watches only the application namespace; TLS secret permissions are a
   namespace Role instead of cluster-wide Secret access.
5. Terraform writes kubeconfig with `local_sensitive_file` mode `0600`, requires
   an explicit DOKS version, and exposes node size/count as reviewed inputs.
6. GitHub Actions references used by the new workflows are pinned to commits.
7. Database retry logs no longer include the raw SQLx error, which could contain
   connection details.
8. Restore verification now requires the `users` relation and successful SQLx
   migration records, rather than accepting any connectable empty database.
9. The standalone cAdvisor manifest is optional and excluded from the production
   deployment set; it is not treated as an observability stack.
10. The canonical Ingress references `opswarden-api-tls`; the duplicate legacy
    Ingress was removed after the public certificate was verified.
11. PostgreSQL now uses separate owner, migrator and DML-only runtime identities.
    The running server cannot execute migrations with its runtime credential.
12. The guarded GitHub production environment now performs the same immutable
    rollout and strict public smoke test as the reviewed local procedure.
13. Prometheus discovers the server endpoints through Kubernetes service
    discovery, Grafana provisions an Alertmanager dashboard, and alerts cover
    delivery failures, elevated rejection volume and duplicate ratio.
14. The targeted server ingress policy explicitly preserves Traefik,
    client-web and Prometheus traffic. The first rollout exposed the danger of
    introducing an isolating policy incrementally; recovery PR #11 and run
    `30564398461` are the retained incident and recovery evidence.
15. Backup and restore containers now share dump files through `fsGroup 20000`
    with group-readable permissions. DOKS' internal FRA1 Spaces endpoint is
    allowed as a single `/32` on TCP 443 for backup workloads only.
16. Isolated restore omits per-database settings for cluster-global roles that
    `pg_dump --no-owner` does not export, while preserving and validating all
    application schema and data.

## Remaining production hardening

1. Encrypted upload and isolated restore are proven manually. The first
   scheduled run, 30-day retention deletion, backup freshness/failure alerting
   and an audited offline copy of the matching age identity remain operational
   follow-ups.
2. The full application-namespace NetworkPolicy set is applied and its public,
   database allow and default-deny paths are proven. A future ACME renewal and
   each newly added external reaction must still be monitored against the
   explicit egress allowlist.
3. The backup path omits role passwords intentionally. Disaster recovery
   therefore still requires the credential-rotation runbook after restoring
   schema and data.
4. Immutable server rollback and restoration are proven across releases with
   no migration delta. ConfigMaps and HPA/PDB are still reconciled from Git
   rather than captured as a single atomic release unit; irreversible database
   migrations remain outside automated rollback.
5. Prometheus scraping, durable Alertmanager alerts, the Kubernetes Metrics API
   and HPA scaling are proven. Centralized log alerting is not proven by this
   run.
6. Mutable base-image tags remain in application Docker build stages. Runtime
   behavior is hardened, but full supply-chain reproducibility is incomplete.
7. WebSocket handshake Origin is not allow-listed server-side. Authentication is
   in-band with a bearer token (not a cookie), reducing cross-site handshake
   impact, but an explicit origin policy remains defense in depth for the Vercel
   split.

## Safe next gate

Before broadening the production claim:

1. version configuration as an atomic release unit and define forward-only
   migration recovery boundaries;
2. keep the jury demonstration on the verified immutable digest and successful
   CD runs `30563381853` and `30564398461`.

The API and Alertmanager observability are deployed and reproducible through
CD. Autoscaling, NetworkPolicies, immutable image rollback and encrypted
off-cluster backup with isolated restore are proven. Atomic
configuration/database rollback remains explicitly incomplete.
