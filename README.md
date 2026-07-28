<div align="center">
  <img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/heroicon.png" alt="OpsWarden" width="120" />
  <h1>OpsWarden - Infrastructure</h1>
  <p>
    <img src="https://github.com/opswarden-git/opswarden-ops/actions/workflows/ops-ci.yml/badge.svg" alt="CI" />
    <img src="https://img.shields.io/badge/License-Apache_2.0-blue?style=flat" alt="License: Apache 2.0" />
    <img src="https://img.shields.io/badge/Kubernetes-326ce5?style=flat&logo=kubernetes&logoColor=white" alt="Kubernetes" />
    <img src="https://img.shields.io/badge/DigitalOcean-%230167ff?style=flat&logo=digitalOcean&logoColor=white" alt="DigitalOcean" />
    <img src="https://img.shields.io/badge/Terraform-%235835CC?style=flat&logo=terraform&logoColor=white" alt="Terraform" />
    <img src="https://img.shields.io/badge/NixOS-5277C3?style=flat&logo=nixos&logoColor=white" alt="NixOS" />
    <img src="https://img.shields.io/badge/Traefik-24A1C1?style=flat&logo=traefikproxy&logoColor=white" alt="Traefik" />
  </p>
</div>

This repository is the infrastructure and deployment home of OpsWarden, containing all our Cloud-Native provisioning and orchestration files.

It includes the **Terraform** configuration for our DigitalOcean Kubernetes cluster, our custom **Traefik** routing setup, the **Prometheus & Grafana** observability stack, and strict **Nix** environments for reproducible deployments.

## What's Running?

While we keep our users focused on a clean and lightning-fast interface, the engine running OpsWarden is robust, observable, and fully declarative. Here is a tour of our real-world production deployment.

### <img src="https://api.iconify.design/simple-icons/vercel.svg" height="24" /> 1. Edge

The frontend is naturally deployed on **Vercel** at the edge, ensuring blazingly fast load times independently from the core cluster state.

<p align="center">
  <img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/vercel-overview.png" alt="Vercel Overview" width="100%" />
</p>

### <img src="https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/digitalocean/digitalocean-original.svg" height="24" /> 2. DigitalOcean

The backend and the database are deployed on a **DigitalOcean** cluster using the GitHub Student Developer Pack. We capture hardware metrics and networking throughput directly from the provider.

<p align="center">
  <img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/do-cluster-insights.png" alt="DigitalOcean Cluster Insights" width="100%" />
</p>

### <img src="https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/kubernetes/kubernetes-plain.svg" height="24" /> 3. Kubernetes

**Kubernetes** handles the management of the nodes and horizontal scaling, with completely automated provisioning via Terraform.

<table width="100%">
  <tr>
    <td colspan="2"><img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/do-kubernetes-clusters.png" alt="Kubernetes Clusters" width="100%" /></td>
  </tr>
  <tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/do-cluster-overview.png" alt="Cluster Overview" width="100%" /></td>
    <td width="50%"><img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/do-cluster-nodes.png" alt="Cluster Nodes" width="100%" /></td>
  </tr>
</table>

### <img src="https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/traefikproxy/traefikproxy-original.svg" height="24" /> 4. Ingress

Telemetry and traffic routing are handled by **Traefik Ingress**. It securely routes and load-balances external HTTP and WebSocket traffic into the cluster.

<p align="center">
  <img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/traefik-dashboard.png" alt="Traefik Dashboard" width="100%" />
</p>

### <img src="https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/grafana/grafana-original.svg" height="24" /> 5. Grafana

Everything is transmitted to **Grafana** for deep observability. We aggregate container states and Prometheus metrics into a collection of clear dashboards that give us a holistic view of the system.

<p align="center">
  <img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/grafana-dashboards.png" alt="Grafana Dashboards Overview" width="100%" />
</p>

For example, here is our detailed Node Exporter dashboard, which we use to closely monitor individual node health, CPU, memory, and disk usage:

<p align="center">
  <img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/grafana-node-exporter.png" alt="Grafana Node Exporter" width="100%" />
</p>
