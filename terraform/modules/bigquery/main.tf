variable "project_id" { type = string }
variable "region" { type = string }
variable "labels" { type = map(string) }

# Dataset `otd`. Tables written by Dataflow (order_events, order_lines, inventory_events,
# shipment_events, store_order_metrics, dead_letter, legacy_oms_orders, order_reconciliation)
# are created by the pipelines themselves with CREATE_IF_NEEDED and the schemas in
# tb-order-events-dataflow/docs/BIGQUERY-SCHEMAS.md, so the pipeline owns their evolution.
# Terraform owns the tables written by *non-Beam* writers.
resource "google_bigquery_dataset" "otd" {
  project                    = var.project_id
  dataset_id                 = "otd"
  friendly_name              = "Order-to-Delivery"
  description                = "Tailored Brands OTD integration platform analytics"
  location                   = "US"
  delete_contents_on_destroy = true
  labels                     = var.labels
}

# Raw archive fed by the Pub/Sub BigQuery subscription on orders-v1 (no code involved).
resource "google_bigquery_table" "orders_raw" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.otd.dataset_id
  table_id            = "orders_raw"
  deletion_protection = false
  labels              = var.labels

  time_partitioning {
    type  = "DAY"
    field = "publish_time"
  }
  clustering = ["subscription_name"]

  schema = file("${path.module}/schemas/orders_raw.json")
}

# Written by tb-tibco-to-pubsub-migration/reconciler (insertAll).
resource "google_bigquery_table" "migration_reconciliation" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.otd.dataset_id
  table_id            = "migration_reconciliation"
  deletion_protection = false
  labels              = var.labels

  time_partitioning {
    type  = "DAY"
    field = "run_time"
  }

  schema = file("${path.module}/schemas/migration_reconciliation.json")
}

output "dataset_id" {
  value = google_bigquery_dataset.otd.dataset_id
}

output "orders_raw_table_id" {
  value = "${var.project_id}.${google_bigquery_dataset.otd.dataset_id}.${google_bigquery_table.orders_raw.table_id}"
}
