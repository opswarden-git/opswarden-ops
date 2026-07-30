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

## Unresolved production blockers

1. The Spaces backup Secret still contains a blocking placeholder, so no remote
   backup upload or isolated restore from Spaces is claimed. A validated local
   pre-migration dump exists, but it is not a substitute for off-cluster backup.
2. A targeted server ingress NetworkPolicy is applied for public traffic and
   Prometheus metrics. The complete workload policy set is not yet claimed:
   PostgreSQL, unauthenticated Redis, DNS, ACME and external server integrations
   still require a staged negative-connectivity proof before broad rollout.
3. The backup path omits role passwords intentionally (`--no-role-passwords`).
   Recovery therefore requires the credential-rotation runbook. A real Spaces
   upload and isolated restore remain mandatory.
4. Production rollback restores the previous server image only. It does not
   version or restore ConfigMaps, HPA/PDB or database migrations, and a first
   deployment has no previous image.
5. Prometheus scraping and durable Alertmanager alerts are proven. The
   Kubernetes Metrics API remains unavailable, so the deployed HPA cannot yet
   obtain CPU utilization. Centralized log alerting is not proven by this run.
6. Mutable base-image tags remain in application Docker build stages. Runtime
   behavior is hardened, but full supply-chain reproducibility is incomplete.
7. WebSocket handshake Origin is not allow-listed server-side. Authentication is
   in-band with a bearer token (not a cookie), reducing cross-site handshake
   impact, but an explicit origin policy remains defense in depth for the Vercel
   split.

## Safe next gate

Before broadening the production claim:

1. provision restricted Spaces credentials and prove upload plus isolated restore;
2. stage and apply the remaining workload NetworkPolicies with explicit
   negative-connectivity tests, without breaking ACME or external reactions;
3. install and verify metrics-server before relying on the HPA;
4. exercise the image rollback path and document migration compatibility;
5. keep the jury demonstration on the verified immutable digest and successful
   CD runs `30563381853` and `30564398461`.

The API and Alertmanager observability are deployed and reproducible through
CD. Off-cluster backup, full network isolation and autoscaling evidence remain
explicitly incomplete.
