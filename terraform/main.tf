# =============================================================================
# Tailored Brands OTD platform — root module
# One environment per state prefix (see versions.tf backend). Modules are local
# so the whole platform is readable in one place.
# =============================================================================

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  project_number = data.google_project.this.number
  labels         = merge(var.labels, { env = var.env })

  # Service accounts expected by the deploy workflows of the other tb-* repos.
  service_accounts = {
    "order-intake-api"     = "order-intake-api (GKE, Workload Identity)"
    "inventory-service"    = "inventory-service (GKE, Workload Identity)"
    "shipment-webhook"     = "shipment-webhook (Cloud Run)"
    "notification-service" = "notification-service (Cloud Run, push target)"
    "pubsub-push"          = "identity Pub/Sub uses to call push endpoints"
    "tb-migration-bridge"  = "jms-to-pubsub-bridge + pubsub-to-jms-bridge (GKE)"
    "tb-legacy-sim"        = "legacy simulators (GKE, namespace legacy)"
    "tb-reconciler"        = "migration reconciler (Cloud Run Job)"
    "dataflow-runner"      = "Dataflow worker / controller service account"
    "tb-scheduler"         = "Cloud Scheduler caller for Dataflow template launches"
  }

  # Cloud Run service URLs are deterministic: https://<service>-<project-number>.<region>.run.app
  notification_service_url = "https://notification-service-${local.project_number}.${var.region}.run.app"
}

module "registry" {
  source     = "./modules/registry"
  project_id = var.project_id
  region     = var.region
  labels     = local.labels
}

module "storage" {
  source     = "./modules/storage"
  project_id = var.project_id
  region     = var.region
  labels     = local.labels
}

module "iam" {
  source           = "./modules/iam"
  project_id       = var.project_id
  service_accounts = local.service_accounts
  bucket_names     = module.storage.bucket_names
}

module "bigquery" {
  source     = "./modules/bigquery"
  project_id = var.project_id
  region     = var.region
  labels     = local.labels
}

module "pubsub" {
  source                = "./modules/pubsub"
  project_id            = var.project_id
  project_number        = local.project_number
  region                = var.region
  labels                = local.labels
  message_retention     = var.pubsub_message_retention
  bigquery_dataset      = module.bigquery.dataset_id
  bigquery_raw_table    = module.bigquery.orders_raw_table_id
  notification_push_url = "${local.notification_service_url}/push/shipments"
  pubsub_push_sa_email  = module.iam.service_account_emails["pubsub-push"]
  depends_on            = [module.bigquery]
}

module "cloudsql" {
  count      = var.enable_cloudsql ? 1 : 0
  source     = "./modules/cloudsql"
  project_id = var.project_id
  region     = var.region
  tier       = var.cloudsql_tier
  labels     = local.labels
}

module "gke" {
  count           = var.enable_gke ? 1 : 0
  source          = "./modules/gke"
  project_id      = var.project_id
  region          = var.gke_location
  release_channel = var.gke_release_channel
  labels          = local.labels
}

# Workload Identity: Kubernetes SA (namespace/name) -> Google SA. The identity pool
# <project>.svc.id.goog only exists once the first GKE cluster with WI is created, hence depends_on.
locals {
  workload_identity = {
    "otd/order-intake-api"       = "order-intake-api"
    "otd/inventory-service"      = "inventory-service"
    "otd/jms-to-pubsub-bridge"   = "tb-migration-bridge"
    "otd/pubsub-to-jms-bridge"   = "tb-migration-bridge"
    "legacy/ems-broker"          = "tb-legacy-sim"
    "legacy/legacy-oms-soap"     = "tb-legacy-sim"
    "legacy/erp-mq-consumer"     = "tb-legacy-sim"
    "legacy/store-pos-simulator" = "tb-legacy-sim"
  }
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each           = var.enable_gke ? local.workload_identity : {}
  service_account_id = module.iam.service_account_names[each.value]
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.key}]"
  depends_on         = [module.gke]
}

module "scheduler" {
  count                 = var.enable_scheduler ? 1 : 0
  source                = "./modules/scheduler"
  project_id            = var.project_id
  region                = var.region
  scheduler_sa_email    = module.iam.service_account_emails["tb-scheduler"]
  dataflow_sa_email     = module.iam.service_account_emails["dataflow-runner"]
  dataflow_bucket       = module.storage.bucket_names["dataflow"]
  legacy_extract_bucket = module.storage.bucket_names["legacy-extracts"]
  reports_bucket        = module.storage.bucket_names["reports"]
}

module "monitoring" {
  source      = "./modules/monitoring"
  project_id  = var.project_id
  alert_email = var.alert_email
}

module "composer" {
  count             = var.enable_composer ? 1 : 0
  source            = "./modules/composer"
  project_id        = var.project_id
  region            = var.region
  composer_sa_email = module.iam.service_account_emails["dataflow-runner"]
  labels            = local.labels
}

module "apigee" {
  count          = var.enable_apigee ? 1 : 0
  source         = "./modules/apigee"
  project_id     = var.project_id
  project_number = local.project_number
  region         = var.region
}
