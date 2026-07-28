# Production deployment audit

Snapshot: 2026-07-28. This document records both verified production evidence
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

- application CI run `30396981672` passes Rust formatting, strict Clippy,
  backend tests and coverage, web quality and tests, desktop packaging and the
  Playwright critical path;
- release `v1.0.2` publishes the attested server image by immutable digest;
- DOKS runs two ready server replicas with completed migration init containers,
  the dedicated runtime Secret and zero container restarts;
- PostgreSQL owner, migrator, runtime and backup roles were reconciled by the
  production bootstrap Job after a validated custom-format database dump;
- Let's Encrypt serves a certificate for `api.opswarden.dev`, and the public
  health, `/about.json` and WebSocket `101` checks pass through Traefik;
- production CD run `30398979253` reproduced the immutable rollout and smoke
  checks from GitHub Actions at ops revision `7903eea`.

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

## Unresolved production blockers

1. The Spaces backup Secret still contains a blocking placeholder, so no remote
   backup upload or isolated restore from Spaces is claimed. A validated local
   pre-migration dump exists, but it is not a substitute for off-cluster backup.
2. Kubernetes NetworkPolicies are not applied. PostgreSQL and unauthenticated Redis
   must not be called production-ready until ingress/egress policies are designed
   and tested, including ACME solver traffic and external server integrations.
3. The backup path omits role passwords intentionally (`--no-role-passwords`).
   Recovery therefore requires the credential-rotation runbook. A real Spaces
   upload and isolated restore remain mandatory.
4. Production rollback restores the previous server image only. It does not
   version or restore ConfigMaps, HPA/PDB or database migrations, and a first
   deployment has no previous image.
5. The Metrics API is unavailable, so the deployed HPA cannot obtain CPU
   utilization. Durable alerts and centralized logs are not proven by this run.
6. Mutable base-image tags remain in application Docker build stages. Runtime
   behavior is hardened, but full supply-chain reproducibility is incomplete.
7. WebSocket handshake Origin is not allow-listed server-side. Authentication is
   in-band with a bearer token (not a cookie), reducing cross-site handshake
   impact, but an explicit origin policy remains defense in depth for the Vercel
   split.

## Safe next gate

Before broadening the production claim:

1. provision restricted Spaces credentials and prove upload plus isolated restore;
2. test and apply NetworkPolicies without breaking ACME or external reactions;
3. install and verify metrics-server before relying on the HPA;
4. exercise the image rollback path and document migration compatibility;
5. keep the jury demonstration on the verified immutable digest and CD run.

The API is deployed and reproducible through CD. Backup, network isolation and
autoscaling evidence remain explicitly incomplete.
