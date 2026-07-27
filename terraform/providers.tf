terraform {
  required_version = ">= 1.11.0"

  # DigitalOcean Spaces exposes an S3-compatible API. Runtime values live in
  # backend.hcl (git-ignored); credentials are supplied through AWS_ACCESS_KEY_ID
  # and AWS_SECRET_ACCESS_KEY, never committed to this repository.
  backend "s3" {}

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  # Utilise automatiquement la variable d'environnement DIGITALOCEAN_TOKEN
}
