terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.40"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Bucket is injected at init time:  terraform init -backend-config="bucket=<TF_STATE_BUCKET>"
  backend "gcs" {
    prefix = "tb-otd/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
