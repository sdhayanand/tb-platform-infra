variable "project_id" { type = string }
variable "region" { type = string }
variable "release_channel" { type = string }
variable "labels" { type = map(string) }

# GKE Autopilot: no node pools to manage, Workload Identity on by default, pay per pod.
resource "google_container_cluster" "autopilot" {
  project  = var.project_id
  name     = "tb-otd-autopilot"
  location = var.region

  enable_autopilot    = true
  deletion_protection = false
  resource_labels     = var.labels

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {} # VPC-native (required by Autopilot)

  # Managed Prometheus + Cloud Logging are the default on Autopilot; keep them explicit.
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-01-01T09:00:00Z"
      end_time   = "2026-01-01T13:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }
}

output "cluster_name" {
  value = google_container_cluster.autopilot.name
}

output "cluster_location" {
  value = google_container_cluster.autopilot.location
}
