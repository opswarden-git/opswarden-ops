<div align="center">
  <img src="https://raw.githubusercontent.com/wiki/opswarden-git/opswarden/assets/opswarden-ops/heroicon.png" alt="OpsWarden" width="120" />
  <h1>OpsWarden - Infrastructure</h1>
  <p>
    <img src="https://github.com/opswarden-git/opswarden-ops/actions/workflows/ops-ci.yml/badge.svg" alt="CI" />
    <img src="https://img.shields.io/github/v/release/opswarden-git/opswarden-ops?style=flat" alt="Release" />
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

## Behind the Scenes

While we keep our users focused on a clean and lightning-fast interface, the engine running OpsWarden is robust, observable, and fully declarative. Here is a tour of our real-world production deployment.

### Cloud Infrastructure

OpsWarden runs on a managed **DigitalOcean Kubernetes** cluster. We rely on managed node pools to handle horizontal scaling, with completely automated provisioning via Terraform.

<p align="center">
  <img src="assets/do-kubernetes-clusters.png" alt="Kubernetes Clusters" width="100%" />
</p>
<p align="center">
  <img src="assets/do-cluster-overview.png" alt="Cluster Overview" width="49%" />
  &nbsp;
  <img src="assets/do-cluster-nodes.png" alt="Cluster Nodes" width="49%" />
</p>

### Observability & Metrics

Knowing the state of the cluster is critical. We capture hardware metrics, networking throughput, and container states, aggregating them into clear dashboards with Prometheus and Grafana.

<p align="center">
  <img src="assets/do-cluster-insights.png" alt="Cluster Insights" width="100%" />
</p>
<p align="center">
  <img src="assets/grafana-dashboards.png" alt="Grafana Dashboards" width="49%" />
  &nbsp;
  <img src="assets/grafana-node-exporter.png" alt="Grafana Node Exporter" width="49%" />
</p>

### Ingress & Traffic Management

We use **Traefik** as our primary Ingress Controller, securely routing and load-balancing external HTTP and WebSocket traffic into the cluster.

<p align="center">
  <img src="assets/traefik-dashboard.png" alt="Traefik Dashboard" width="100%" />
</p>

### Edge Delivery

Our frontend is completely statically generated and served globally at the edge via **Vercel**, ensuring blazingly fast load times independently from the core cluster state.

<p align="center">
  <img src="assets/vercel-overview.png" alt="Vercel Overview" width="100%" />
</p>
