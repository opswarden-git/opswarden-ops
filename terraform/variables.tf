variable "region" {
  type        = string
  default     = "fra1" # Frankfurt, idéal pour l'Europe
  description = "Region DigitalOcean pour le cluster"
}

variable "cluster_name" {
  type        = string
  default     = "bernstein-cluster"
  description = "Nom du cluster Kubernetes"
}
