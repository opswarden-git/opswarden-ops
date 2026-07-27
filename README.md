<div align="center">

<img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/heroicon.png" alt="OpsWarden" width="120" />

# OpsWarden — Ops

<p>
  <a href="https://github.com/opswarden-git/opswarden-ops/actions/workflows/ops-ci.yml"><img src="https://github.com/opswarden-git/opswarden-ops/actions/workflows/ops-ci.yml/badge.svg" alt="Ops CI" /></a>
  <img src="https://img.shields.io/github/v/release/opswarden-git/opswarden-ops?style=flat-square&label=release" alt="Release" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-F4C430?style=flat-square" alt="License: Apache 2.0" /></a>
  <img src="https://img.shields.io/badge/status-baseline-2F2F2F?style=flat-square" alt="Status: baseline" />
</p>

<br />

[![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Traefik](https://img.shields.io/badge/Traefik-24A1C1?style=for-the-badge&logo=traefikproxy&logoColor=white)](https://traefik.io/)
[![DigitalOcean](https://img.shields.io/badge/DigitalOcean-0080FF?style=for-the-badge&logo=digitalocean&logoColor=white)](https://www.digitalocean.com/)
[![Nix](https://img.shields.io/badge/Nix-5277C3?style=for-the-badge&logo=nixos&logoColor=white)](https://nixos.org/)

<br /><br />

<img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/architecture.png" alt="Reference cluster topology" width="100%" />

<sub><i>Reference cluster topology — to be replaced by OpsWarden's own diagram.</i></sub>

</div>

<br />

---

## About

`opswarden-ops` is the **infrastructure & deployment** repository for OpsWarden:
a Kubernetes deployment on **DigitalOcean (DOKS)**, provisioned end-to-end by
**Terraform**, routed by **Traefik**, with a reproducible dev environment via
**Nix**.

It is **separate from the product** (`opswarden-app`) and **deliberately optional**:
OpsWarden runs with a single `docker compose up`. This repo is the **portfolio
cloud showcase** — it must never be a prerequisite to run the product.

> Status: the complete core stack—Traefik, PostgreSQL, Redis, Rust server and
> Next.js client—has passed local two-node deployment and end-to-end product
> checks. The DOKS production path, immutable GHCR releases, public DNS and TLS
> issuance remain pending. The optional services are not part
> of the core product deployment.
> See the current [deployment audit](docs/deployment-audit.md) for the verified
> state, production blockers and rollout order.

---

## Project Structure

```
opswarden-ops/
│
├── k8s/
│   ├── server/             # OpsWarden server (Rust/Axum) + HPA/PDB — manifest ready
│   ├── client-web/         # Next.js client + ingress      — manifest ready
│   ├── postgres/           # PostgreSQL + encrypted off-cluster backups
│   ├── redis/              # Redis                          — ready
│   ├── traefik/            # ingress controller & LB (+ IngressClass, PDB) — ready
│   └── observability/      # cAdvisor (+ prom/grafana/loki) — partial
│
├── terraform/              # DOKS cluster provisioning (main/outputs/providers/variables.tf)
├── scripts/                # smoke.sh, load.sh, soft-affinity.sh (ops helpers)
├── Makefile                # single runner: provision → deploy → harden → verify → destroy + fmt/validate/lint
├── flake.nix / flake.lock  # Nix dev shell (kubectl, terraform, k9s, helm…)
├── .env                    # API tokens (git-ignored)
├── LICENSE / NOTICE        # Apache-2.0
└── README.md
```

---

## Services

| Service        |                                      Tech                                       | Status                                 |
| -------------- | :-----------------------------------------------------------------------------: | -------------------------------------- |
| **server**     |    <img src="https://skillicons.dev/icons?i=rust" height="22" /> Rust / Axum    | locally verified — release pending     |
| **client-web** |     <img src="https://skillicons.dev/icons?i=nextjs" height="22" /> Next.js     | locally verified — release/TLS pending |
| **PostgreSQL** | <img src="https://skillicons.dev/icons?i=postgres" height="22" /> PostgreSQL 18 | locally verified — backup automation   |
| **Redis**      |     <img src="https://skillicons.dev/icons?i=redis" height="22" /> Redis 8      | ready — immutable image                |
| **Traefik**    |                                   Traefik 3.7                                   | ready — immutable image                |
| **cAdvisor**   | <img src="https://skillicons.dev/icons?i=prometheus" height="22" /> monitoring  | ready — `k8s/observability/`           |

Replicated services use **preferred pod anti-affinity** to spread across nodes.
Shared config lives in **ConfigMaps**; credentials are supplied through
SOPS-encrypted **Secrets** before a real deployment.

---

## Reference Deployment

The reusable stack has been **proven on DigitalOcean Kubernetes (DOKS)** — a
2-node pool (`s-2vcpu-4gb`) provisioned end-to-end by Terraform in the `fra1`
region. The screenshots below are from that reference run; OpsWarden's own
screenshots will replace the application-level ones once it is deployed.

<div align="center">

**Node pool — 2 / 2 nodes running**

<img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/cluster-overview.png" alt="DOKS node pool status — 2/2 running" width="100%" />

<br /><br />



<br /><br />

**Cluster insights — CPU, load, memory, disk & I/O**

<img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/insights.png" alt="DigitalOcean cluster insights graphs" width="100%" />

<br /><br />

**Traefik — routers & services healthy, 100% success on `:80` / `:8080`**

<img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/traefik.png" alt="Traefik dashboard — routers and services healthy" width="100%" />

</div>

> `poll.png` and `result.png` (in the wiki) show the reference workload (a voting
> app) that validated the cluster end-to-end. They will be replaced by OpsWarden
> screenshots once the application services are deployed.

---

## Installation & Configuration

> **One-command path.** The whole lifecycle is automated by the
> [`Makefile`](Makefile): `make all` (initialize remote state, provision and
> deploy the ready layer),
> `make hosts && make smoke` (local DNS + end-to-end check), `make harden`
> (PDB/HPA), `make destroy`. Run `make help` for every target. **No cloud
> account?** Run the same manifests for free on a local 2-node minikube:
> `make minikube`, then `make minikube-smoke`. The manual steps below spell out
> the same flow.

### Prerequisites

- [Nix](https://nixos.org/download.html) package manager
- A [DigitalOcean](https://www.digitalocean.com/) account with an API token
- A versioned DigitalOcean Spaces bucket and restricted access keys for Terraform state
- [Git](https://git-scm.com/)

### 1 — Clone & enter the environment

```bash
git clone git@github.com:opswarden-git/opswarden-ops.git && cd opswarden-ops
cp .env.example .env   # add credentials and a reviewed TF_VAR_kubernetes_version
nix develop            # loads kubectl, terraform, k9s, helm…
```

### 2 — Initialize remote state and provision the cluster

```bash
cp terraform/backend.hcl.example terraform/backend.hcl
# Edit the local, git-ignored backend.hcl with the bucket and Spaces region.
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are loaded from .env.
make infra TF_BACKEND_CONFIG=terraform/backend.hcl
export KUBECONFIG=$(pwd)/kubeconfig
```

The backend uses the Spaces S3-compatible API and native Terraform lockfiles.
Enable bucket versioning before the first apply. If a local state already exists,
`make backend-init` stops and prints the explicit migration command instead of
silently discarding it.

### 3 — Bootstrap Secrets (SOPS)

> Credentials are encrypted in Git via [SOPS](https://github.com/getsops/sops) and `age`. They must be applied manually before the database deployment.

```bash
# 1. Provide your private age key to SOPS
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# 2. Select your target environment explicitly
export EXPECTED_CONTEXT=minikube
export NAMESPACE=opswarden

# 3. Validate the decrypted secret against the target cluster
make secrets-dry-run \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE"

# 4. Apply the decrypted secret to the cluster
make secrets-apply \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE" \
  CONFIRM=APPLY_POSTGRES_SECRET
```

### 4 — Deploy the infrastructure layer

```bash
make deploy \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE"
```

### 5 — Deploy the nominal application backend

The nominal production split is intentional: `client-web` runs on Vercel at
`app.opswarden.dev`; Rust, PostgreSQL, Redis and Traefik run on DOKS. Create the
SOPS-managed `opswarden-server-secret` first. Production accepts only an
immutable server digest and HTTPS origins.

```bash
make deploy-server \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE" \
  SERVER_IMAGE="ghcr.io/opswarden-git/opswarden-server@sha256:<digest>" \
  PUBLIC_ORIGIN="https://app.opswarden.dev" \
  API_ORIGIN="https://api.opswarden.dev"
```

Configure the Vercel project with Root Directory `client-web`,
`OPSWARDEN_API_ORIGIN=https://api.opswarden.dev`, and
`NEXT_PUBLIC_WS_URL=wss://api.opswarden.dev/ws`. The checked-in Kubernetes web
Deployment is an optional self-hosted path exposed through
`make deploy-self-hosted-web`; it is not part of production CD.

### 6 — Enable public TLS

After the load balancer address is known and `api.opswarden.dev` points at it:

```bash
make tls \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" \
  NAMESPACE="$NAMESPACE" \
  ACME_EMAIL="ops@example.com" \
  CONFIRM=ENABLE_PUBLIC_TLS
```

### 7 — Enable encrypted off-cluster backups

Create and SOPS-encrypt `k8s/postgres/postgres-backup.secret.sops.yaml` from the
example. Its rclone crypt password must be independent from database credentials.

```bash
make secret-apply \
  SECRET_FILE=k8s/postgres/postgres-backup.secret.sops.yaml \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE" \
  CONFIRM=APPLY_SOPS_SECRET

make backup-enable \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE" \
  BACKUP_BUCKET="opswarden-backups" \
  BACKUP_ENDPOINT="https://fra1.digitaloceanspaces.com" \
  CONFIRM=ENABLE_BACKUPS

# Prove upload, decryption and an isolated PostgreSQL restore.
make backup-run EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE"
make backup-verify \
  EXPECTED_CONTEXT="$EXPECTED_CONTEXT" NAMESPACE="$NAMESPACE" \
  CONFIRM=VERIFY_LATEST_BACKUP
```

### 8 — Configure guarded production delivery

Create a GitHub environment named `production`, enable required reviewers and
define:

- secret `KUBE_CONFIG_B64`: base64-encoded, least-privilege production kubeconfig;
- variable `KUBE_CONTEXT`: the exact context name in that kubeconfig;
- variable `KUBE_NAMESPACE`: the application namespace;
- variable `FRONTEND_ORIGIN`: `https://app.opswarden.dev`;
- variable `API_ORIGIN`: `https://api.opswarden.dev`.

Run **Deploy production** from `main` with the server GHCR digest and the literal
confirmation `DEPLOY_PRODUCTION`. If backups are enabled, the workflow takes one
before rollout. A failed rollout or API/WebSocket smoke restores the prior
server image. Vercel has its own deployment and rollback history.

### Teardown

```bash
make destroy TF_BACKEND_CONFIG=terraform/backend.hcl
```

---

## Production hardening

Reusable patterns ported from the reference deployment, applied with `make harden`:

- **Disruption budgets** — [`k8s/traefik/traefik.pdb.yaml`](k8s/traefik/traefik.pdb.yaml)
  keeps ≥1 Traefik replica during node drain; [`k8s/server/server.pdb.yaml`](k8s/server/server.pdb.yaml)
  protects the API server.
- **Autoscaling** — [`k8s/server/server.hpa.yaml`](k8s/server/server.hpa.yaml)
  is a CPU-based HPA enabled by `requests.cpu` + metrics-server
  (`make metrics` / `make load`).
- **Modern ingress** — [`k8s/traefik/traefik.ingressclass.yaml`](k8s/traefik/traefik.ingressclass.yaml)
  replaces the deprecated `kubernetes.io/ingress.class` annotation; app Ingresses
  use `spec.ingressClassName: traefik`.
- **Availability-aware placement** — replicated services default to preferred
  cross-node anti-affinity so a rolling update is not deadlocked on a two-node
  cluster. [`scripts/soft-affinity.sh`](scripts/soft-affinity.sh) can enforce
  strict one-replica-per-node placement where spare node capacity exists.
- **Smoke & load** — [`scripts/smoke.sh`](scripts/smoke.sh) checks the public
  path (Traefik + app routes, NixOS/minikube aware) and
  [`scripts/load.sh`](scripts/load.sh) drives autoscaling.

The guarded production workflow applies the server HPA/PDB, verifies the public
API and WebSocket paths, and rolls the server image back on failure.

---

## License

OpsWarden is distributed under the **Apache License 2.0**. See
[LICENSE](LICENSE).
