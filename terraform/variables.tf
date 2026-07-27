variable "region" {
  type        = string
  default     = "fra1" # Frankfurt, idéal pour l'Europe
  description = "Region DigitalOcean pour le cluster"
}

variable "cluster_name" {
  type        = string
  default     = "opswarden-cluster"
  description = "Nom du cluster Kubernetes"
}

variable "kubernetes_version" {
  type        = string
  description = "Version DOKS explicite et revue (ex: 1.33.1-do.3); aucune mise à niveau implicite"
}

variable "node_size" {
  type        = string
  default     = "s-2vcpu-4gb"
  description = "Taille DigitalOcean des nœuds du pool principal"
}

variable "node_count" {
  type        = number
  default     = 2
  description = "Nombre de nœuds du pool principal"
  validation {
    condition     = var.node_count >= 2
    error_message = "La production requiert au moins deux nœuds."
  }
}
