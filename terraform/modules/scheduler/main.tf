variable "project_id" { type = string }
variable "region" { type = string }
variable "scheduler_sa_email" { type = string }
variable "dataflow_sa_email" { type = string }
variable "dataflow_bucket" { type = string }
variable "legacy_extract_bucket" { type = string }
variable "reports_bucket" { type = string }

# Cloud Scheduler -> Dataflow Flex Template launch (REST), daily at 06:10 UTC.
# This is the "Cloud Scheduler" half of the posting's "Cloud Scheduler/Composer" requirement;
# the Composer DAG in tb-orchestration does the same launch with DataflowStartFlexTemplateOperator.
resource "google_cloud_scheduler_job" "daily_reconciliation" {
  project     = var.project_id
  region      = var.region
  name        = "tb-otd-daily-reconciliation"
  description = "Launch the daily-reconciliation Dataflow Flex Template (legacy OMS extract vs order_events)"
  schedule    = "10 6 * * *"
  time_zone   = "Etc/UTC"

  retry_config {
    retry_count          = 3
    min_backoff_duration = "60s"
    max_backoff_duration = "600s"
  }

  http_target {
    http_method = "POST"
    uri         = "https://dataflow.googleapis.com/v1b3/projects/${var.project_id}/locations/${var.region}/flexTemplates:launch"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(jsonencode({
      launchParameter = {
        jobName           = "daily-reconciliation-scheduled"
        containerSpecGcsPath = "gs://${var.dataflow_bucket}/templates/daily-reconciliation.json"
        parameters = {
          legacyExtractPath = "gs://${var.legacy_extract_bucket}/extracts/*.xml"
          bigQueryDataset   = "otd"
          reportGcsPath     = "gs://${var.reports_bucket}/reconciliation/daily-reconciliation.csv"
        }
        environment = {
          serviceAccountEmail = var.dataflow_sa_email
          tempLocation        = "gs://${var.dataflow_bucket}/temp"
          stagingLocation     = "gs://${var.dataflow_bucket}/staging"
          maxWorkers          = 2
          machineType         = "n1-standard-2"
        }
      }
    }))
    oauth_token {
      service_account_email = var.scheduler_sa_email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}

output "job_name" {
  value = google_cloud_scheduler_job.daily_reconciliation.name
}
