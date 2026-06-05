# Pas de version_prefix codé en dur : DigitalOcean retire régulièrement les
# anciennes versions (EOL), ce qui casse un prefix figé. On laisse le data
# source renvoyer la dernière version supportée du moment.
data "digitalocean_kubernetes_versions" "current" {}

resource "digitalocean_kubernetes_cluster" "bernstein" {
  name    = var.cluster_name
  region  = var.region
  version = data.digitalocean_kubernetes_versions.current.latest_version

  node_pool {
    name       = "worker-pool"
    size       = "s-2vcpu-4gb" # 2 vCPU, 4 Go RAM par noeud
    node_count = 2
  }
}
