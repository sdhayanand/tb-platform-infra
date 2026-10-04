variable "project_id" { type = string }
variable "region" { type = string }
variable "composer_sa_email" { type = string }
variable "labels" { type = map(string) }

# Cloud Composer 2 (Airflow 2) — optional, ~$300+/month even when idle, so it is behind
# enable_composer. DAGs live in tb-orchestration/composer/dags and are synced by its workflow.
resource "google_composer_environment" "otd" {
  project = var.project_id
  region  = var.region
  name    = "tb-otd-composer"
  labels  = var.labels

  config {
    environment_size = "ENVIRONMENT_SIZE_SMALL"

    software_config {
      image_version = "composer-2.9.9-airflow-2.9.3"
      env_variables = {
        OTD_PROJECT_ID = var.project_id
        OTD_REGION     = var.region
      }
    }

    node_config {
      service_account = var.composer_sa_email
    }

    workloads_config {
      scheduler {
        cpu        = 0.5
        memory_gb  = 2
        storage_gb = 1
        count      = 1
      }
      web_server {
        cpu        = 0.5
        memory_gb  = 2
        storage_gb = 1
      }
      worker {
        cpu        = 0.5
        memory_gb  = 2
        storage_gb = 1
        min_count  = 1
        max_count  = 2
      }
    }
  }
}

output "dag_gcs_prefix" {
  value = google_composer_environment.otd.config[0].dag_gcs_prefix
}
