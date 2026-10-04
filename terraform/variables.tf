variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Primary region for all regional resources"
  type        = string
  default     = "us-central1"
}

variable "env" {
  description = "Environment name (dev|stage|prod); used in labels and names"
  type        = string
  default     = "dev"
}

variable "github_owner" {
  description = "GitHub owner whose repos deploy into this project"
  type        = string
  default     = "sdhayanand"
}

variable "alert_email" {
  description = "Email for Cloud Monitoring alert notifications (empty disables the channel)"
  type        = string
  default     = ""
}

# ---------- feature flags (cost control) ----------
variable "enable_gke" {
  description = "Create the GKE Autopilot cluster (~$0.10/h idle + pods)"
  type        = bool
  default     = true
}

variable "enable_cloudsql" {
  description = "Create the Cloud SQL Postgres instance (db-f1-micro ≈ $9/month)"
  type        = bool
  default     = true
}

variable "enable_scheduler" {
  description = "Create the Cloud Scheduler job that launches the daily reconciliation Dataflow template"
  type        = bool
  default     = true
}

variable "enable_composer" {
  description = "Create a Cloud Composer 2 environment (≈ $300+/month — off by default; Cloud Scheduler covers the demo)"
  type        = bool
  default     = false
}

variable "enable_apigee" {
  description = "Provision an Apigee X evaluation org (takes ~1h; off by default — proxy bundle is still in the repo)"
  type        = bool
  default     = false
}

variable "cloudsql_tier" {
  type    = string
  default = "db-f1-micro"
}

variable "gke_release_channel" {
  type    = string
  default = "REGULAR"
}

variable "pubsub_message_retention" {
  description = "Retention for business topics"
  type        = string
  default     = "604800s" # 7 days
}

variable "labels" {
  type = map(string)
  default = {
    platform = "tb-otd"
    managed  = "terraform"
  }
}
