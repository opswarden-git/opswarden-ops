# Contradictory deployment audit

Snapshot: 2026-07-27. This document audits the preserved WIP candidate; it is
not a cloud certification and records negative findings as well as evidence.

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

- frontend lint, formatting, type checking, 49 test files and 209 tests pass;
- the app workflow passes `actionlint`;
- Rust formatting passes and the four server health integration tests pass;
- the earlier local lab reached Next.js, Rust and a WebSocket `101` and restored
  a real PostgreSQL dump, but this does not certify DOKS, Spaces, ACME or CD;
- the candidate branches and external format-patch backups are preserved without
  any push, tag or deployment.

Rust Clippy was not reproduced because the host toolchain has no Clippy
component. A matching Rust dev shell or `rustup component add clippy` is still
required before integration.

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

## Unresolved production blockers

1. No DOKS, Spaces, DNS, Vercel, cert-manager or rollback path has been exercised
   with production credentials. Supplying credentials is deliberately deferred.
2. Kubernetes NetworkPolicies are absent. PostgreSQL and unauthenticated Redis
   must not be called production-ready until ingress/egress policies are designed
   and tested, including ACME solver traffic and external server integrations.
3. The PostgreSQL runtime role still needs a least-privilege grants/migration
   design. The example rejects reuse of the owner role, but does not provision
   roles automatically.
4. TLS templates are statically rendered only. HTTP-to-HTTPS redirect behavior,
   ACME HTTP-01 and certificate renewal require a live staging test.
5. The backup path omits role passwords intentionally (`--no-role-passwords`).
   Recovery therefore requires the credential-rotation runbook. A real Spaces
   upload and isolated restore remain mandatory.
6. Production rollback restores the previous server image only. It does not
   version or restore ConfigMaps, HPA/PDB or database migrations, and a first
   deployment has no previous image.
7. Durable metrics, alerts and centralized logs are not implemented. The pinned
   cAdvisor manifest is suitable only for an explicit lab experiment.
8. Mutable base-image tags remain in application Docker build stages. Runtime
   behavior is hardened, but full supply-chain reproducibility is incomplete.
9. WebSocket handshake Origin is not allow-listed server-side. Authentication is
   in-band with a bearer token (not a cookie), reducing cross-site handshake
   impact, but an explicit origin policy remains defense in depth for the Vercel
   split.
10. The reproducible web-image build succeeds, but `npm ci` reports nine
    high-severity advisories. Their production reachability has not been triaged;
    release is blocked until `npm audit` is reviewed without applying an
    unreviewed breaking `--force` upgrade.

## Safe next gate

Before any credential handoff, push, tag or cloud mutation:

1. review the atomic commit series and rerun all local CI, including Clippy;
2. add and test NetworkPolicies in an isolated cluster;
3. define database owner, migrator and runtime roles;
4. test TLS with Let's Encrypt staging and test the server rollback path;
5. merge only after review, then publish immutable images;
6. provision cloud resources with credentials supplied locally, never in chat;
7. prove backup/restore from Spaces before switching DNS.

The candidate is now reviewable, but it remains a deployment candidate rather
than a completed production deployment.
