output "kubeconfig" {
  value     = digitalocean_kubernetes_cluster.bernstein.kube_config[0].raw_config
  sensitive = true
}

resource "local_file" "kubeconfig" {
  content  = digitalocean_kubernetes_cluster.bernstein.kube_config[0].raw_config
  filename = "${path.module}/../kubeconfig"
}
