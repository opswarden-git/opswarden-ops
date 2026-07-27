output "kubeconfig" {
  value     = digitalocean_kubernetes_cluster.opswarden.kube_config[0].raw_config
  sensitive = true
}

resource "local_sensitive_file" "kubeconfig" {
  content         = digitalocean_kubernetes_cluster.opswarden.kube_config[0].raw_config
  filename        = "${path.module}/../kubeconfig"
  file_permission = "0600"
}
