variable "project_id" { type = string }
variable "service_accounts" { type = map(string) }
variable "bucket_names" { type = map(string) }

# ---------------------------------------------------------------------------
# Service accounts — one per workload (least privilege, Workload Identity)
# ---------------------------------------------------------------------------
resource "google_service_account" "sa" {
  for_each     = var.service_accounts
  project      = var.project_id
  account_id   = each.key
  display_name = each.value
}

locals {
  email = { for k, sa in google_service_account.sa : k => sa.email }

  # Project-level roles per workload. Keep this table readable: it is the access review.
  project_roles = {
    "order-intake-api" = [
      "roles/pubsub.publisher", "roles/pubsub.subscriber", "roles/pubsub.viewer",
      "roles/cloudsql.client", "roles/secretmanager.secretAccessor",
      "roles/logging.logWriter", "roles/monitoring.metricWriter", "roles/cloudtrace.agent",
    ]
    "inventory-service" = [
      "roles/pubsub.publisher", "roles/pubsub.subscriber", "roles/pubsub.viewer",
      "roles/cloudsql.client", "roles/secretmanager.secretAccessor",
      "roles/logging.logWriter", "roles/monitoring.metricWriter", "roles/cloudtrace.agent",
    ]
    "shipment-webhook" = [
      "roles/pubsub.publisher", "roles/secretmanager.secretAccessor",
      "roles/logging.logWriter", "roles/monitoring.metricWriter", "roles/cloudtrace.agent",
    ]
    "notification-service" = [
      "roles/logging.logWriter", "roles/monitoring.metricWriter", "roles/cloudtrace.agent",
    ]
    "pubsub-push" = [
      # invoker on the Cloud Run service is granted in the service deploy (gcloud run services add-iam-policy-binding)
      "roles/run.invoker",
    ]
    "tb-migration-bridge" = [
      "roles/pubsub.publisher", "roles/pubsub.subscriber", "roles/pubsub.viewer",
      "roles/secretmanager.secretAccessor",
      "roles/logging.logWriter", "roles/monitoring.metricWriter",
    ]
    "tb-legacy-sim" = [
      "roles/storage.objectCreator", "roles/logging.logWriter", "roles/monitoring.metricWriter",
    ]
    "tb-reconciler" = [
      "roles/bigquery.dataEditor", "roles/bigquery.jobUser", "roles/secretmanager.secretAccessor",
      "roles/logging.logWriter",
    ]
    "dataflow-runner" = [
      "roles/dataflow.worker", "roles/dataflow.admin",
      "roles/pubsub.subscriber", "roles/pubsub.publisher", "roles/pubsub.viewer",
      "roles/bigquery.dataEditor", "roles/bigquery.jobUser",
      "roles/storage.objectAdmin", "roles/artifactregistry.reader",
      "roles/logging.logWriter", "roles/monitoring.metricWriter",
    ]
    "tb-scheduler" = [
      "roles/dataflow.developer", # launch Flex Templates
      "roles/iam.serviceAccountUser",
    ]
  }

  role_bindings = flatten([
    for sa, roles in local.project_roles : [
      for role in roles : { key = "${sa}:${role}", sa = sa, role = role }
    ]
  ])
}

resource "google_project_iam_member" "roles" {
  for_each = { for b in local.role_bindings : b.key => b }
  project  = var.project_id
  role     = each.value.role
  member   = "serviceAccount:${local.email[each.value.sa]}"
}

# Scheduler must be able to launch Dataflow jobs *as* the dataflow-runner SA.
resource "google_service_account_iam_member" "scheduler_acts_as_dataflow" {
  service_account_id = google_service_account.sa["dataflow-runner"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.email["tb-scheduler"]}"
}

output "service_account_emails" {
  value = local.email
}

output "service_account_names" {
  description = "Fully-qualified SA resource names (projects/.../serviceAccounts/...), for IAM bindings made outside the module"
  value       = { for k, sa in google_service_account.sa : k => sa.name }
}
