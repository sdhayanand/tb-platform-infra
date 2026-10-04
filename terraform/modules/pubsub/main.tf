variable "project_id" { type = string }
variable "project_number" { type = string }
variable "region" { type = string }
variable "labels" { type = map(string) }
variable "message_retention" { type = string }
variable "bigquery_dataset" { type = string }
variable "bigquery_raw_table" { type = string }
variable "notification_push_url" { type = string }
variable "notification_push_audience" {
  description = "OIDC audience; must equal PUSH_AUDIENCE configured on the Cloud Run service (its base URL)"
  type        = string
}
variable "pubsub_push_sa_email" { type = string }

variable "enable_schema_validation" {
  description = "Attach protobuf schemas (JSON encoding) to business topics"
  type        = bool
  default     = true
}

locals {
  pubsub_service_agent = "serviceAccount:service-${var.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  schemas = {
    "order-event"     = "OrderEvent.proto"
    "inventory-event" = "InventoryEvent.proto"
    "shipment-event"  = "ShipmentEvent.proto"
  }
}

# ---------------------------------------------------------------------------
# Schemas (protobuf, JSON-encoded messages). Revisions are additive-only.
# ---------------------------------------------------------------------------
resource "google_pubsub_schema" "schema" {
  for_each   = var.enable_schema_validation ? local.schemas : {}
  project    = var.project_id
  name       = each.key
  type       = "PROTOCOL_BUFFER"
  definition = file("${path.module}/schemas/${each.value}")
}

# ---------------------------------------------------------------------------
# Topics
# ---------------------------------------------------------------------------
resource "google_pubsub_topic" "orders" {
  project                    = var.project_id
  name                       = "orders-v1"
  message_retention_duration = var.message_retention
  labels                     = var.labels

  dynamic "schema_settings" {
    for_each = var.enable_schema_validation ? [1] : []
    content {
      schema   = google_pubsub_schema.schema["order-event"].id
      encoding = "JSON"
    }
  }
  depends_on = [google_pubsub_schema.schema]
}

resource "google_pubsub_topic" "inventory" {
  project                    = var.project_id
  name                       = "inventory-v1"
  message_retention_duration = var.message_retention
  labels                     = var.labels

  dynamic "schema_settings" {
    for_each = var.enable_schema_validation ? [1] : []
    content {
      schema   = google_pubsub_schema.schema["inventory-event"].id
      encoding = "JSON"
    }
  }
  depends_on = [google_pubsub_schema.schema]
}

resource "google_pubsub_topic" "shipments" {
  project                    = var.project_id
  name                       = "shipments-v1"
  message_retention_duration = var.message_retention
  labels                     = var.labels

  dynamic "schema_settings" {
    for_each = var.enable_schema_validation ? [1] : []
    content {
      schema   = google_pubsub_schema.schema["shipment-event"].id
      encoding = "JSON"
    }
  }
  depends_on = [google_pubsub_schema.schema]
}

resource "google_pubsub_topic" "dlq" {
  project                    = var.project_id
  name                       = "events-dlq"
  message_retention_duration = var.message_retention
  labels                     = var.labels
}

resource "google_pubsub_topic" "migration_control" {
  project = var.project_id
  name    = "migration-control"
  labels  = var.labels
}

# Pub/Sub's own service agent must be allowed to forward to the DLQ topic ...
resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dlq.name
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_service_agent
}

# ... to mint OIDC tokens for push subscriptions ...
resource "google_service_account_iam_member" "push_token_creator" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.pubsub_push_sa_email}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.pubsub_service_agent
}

# ... and to write into BigQuery for the BigQuery subscription.
resource "google_bigquery_dataset_iam_member" "pubsub_bq_writer" {
  project    = var.project_id
  dataset_id = var.bigquery_dataset
  role       = "roles/bigquery.dataEditor"
  member     = local.pubsub_service_agent
}

# ---------------------------------------------------------------------------
# Subscriptions on orders-v1
# ---------------------------------------------------------------------------
resource "google_pubsub_subscription" "orders_inventory_service" {
  project                      = var.project_id
  name                         = "orders-inventory-service"
  topic                        = google_pubsub_topic.orders.id
  ack_deadline_seconds         = 60
  message_retention_duration   = var.message_retention
  enable_message_ordering      = true
  enable_exactly_once_delivery = true
  labels                       = var.labels

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }
  expiration_policy {
    ttl = "" # never expire
  }
}

resource "google_pubsub_subscription" "orders_dataflow" {
  project                    = var.project_id
  name                       = "orders-dataflow"
  topic                      = google_pubsub_topic.orders.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.message_retention
  enable_message_ordering    = true
  labels                     = var.labels
  expiration_policy {
    ttl = ""
  }
}

# Migration phase 2-3: keep IBM MQ / ERP fed from Pub/Sub. Never re-bridge what came from EMS.
resource "google_pubsub_subscription" "orders_to_legacy_mq" {
  project                    = var.project_id
  name                       = "orders-to-legacy-mq"
  topic                      = google_pubsub_topic.orders.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.message_retention
  enable_message_ordering    = true
  filter                     = "attributes.source != \"TIBCO_EMS_BRIDGE\""
  labels                     = var.labels

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }
  expiration_policy {
    ttl = ""
  }
}

# Zero-code raw archive: every order event lands in BigQuery as JSON.
resource "google_pubsub_subscription" "orders_bq_archive" {
  project = var.project_id
  name    = "orders-bq-archive"
  topic   = google_pubsub_topic.orders.id
  labels  = var.labels

  bigquery_config {
    table          = var.bigquery_raw_table
    write_metadata = true
  }
  expiration_policy {
    ttl = ""
  }
  depends_on = [google_bigquery_dataset_iam_member.pubsub_bq_writer]
}

# ---------------------------------------------------------------------------
# Subscriptions on inventory-v1
# ---------------------------------------------------------------------------
resource "google_pubsub_subscription" "inventory_dataflow" {
  project                    = var.project_id
  name                       = "inventory-dataflow"
  topic                      = google_pubsub_topic.inventory.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.message_retention
  labels                     = var.labels
  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription" "inventory_order_intake" {
  project                    = var.project_id
  name                       = "inventory-order-intake"
  topic                      = google_pubsub_topic.inventory.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.message_retention
  enable_message_ordering    = true
  labels                     = var.labels

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }
  expiration_policy {
    ttl = ""
  }
}

# ---------------------------------------------------------------------------
# Subscriptions on shipments-v1
# ---------------------------------------------------------------------------
resource "google_pubsub_subscription" "shipments_dataflow" {
  project                    = var.project_id
  name                       = "shipments-dataflow"
  topic                      = google_pubsub_topic.shipments.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.message_retention
  labels                     = var.labels
  expiration_policy {
    ttl = ""
  }
}

# Push to Cloud Run with an OIDC token — the Cloud Run service is private.
resource "google_pubsub_subscription" "shipments_notification" {
  project                    = var.project_id
  name                       = "shipments-notification"
  topic                      = google_pubsub_topic.shipments.id
  ack_deadline_seconds       = 30
  message_retention_duration = var.message_retention
  labels                     = var.labels

  push_config {
    push_endpoint = var.notification_push_url
    oidc_token {
      service_account_email = var.pubsub_push_sa_email
      audience              = var.notification_push_audience
    }
  }
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }
  expiration_policy {
    ttl = ""
  }
  depends_on = [google_service_account_iam_member.push_token_creator]
}

# ---------------------------------------------------------------------------
# DLQ + migration control
# ---------------------------------------------------------------------------
resource "google_pubsub_subscription" "dlq_monitor" {
  project                    = var.project_id
  name                       = "events-dlq-monitor"
  topic                      = google_pubsub_topic.dlq.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.message_retention
  labels                     = var.labels
  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription" "migration_control" {
  for_each = toset(["migration-control-jms-to-pubsub", "migration-control-pubsub-to-jms", "migration-control-bridges"])
  project  = var.project_id
  name     = each.key
  topic    = google_pubsub_topic.migration_control.id
  labels   = var.labels
  expiration_policy {
    ttl = ""
  }
}

# The DLQ forwarder needs subscriber on every subscription that has a dead-letter policy.
resource "google_pubsub_subscription_iam_member" "dlq_forwarder" {
  for_each = {
    inv  = google_pubsub_subscription.orders_inventory_service.name
    mq   = google_pubsub_subscription.orders_to_legacy_mq.name
    oi   = google_pubsub_subscription.inventory_order_intake.name
    push = google_pubsub_subscription.shipments_notification.name
  }
  project      = var.project_id
  subscription = each.value
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_service_agent
}

output "topic_names" {
  value = [
    google_pubsub_topic.orders.name, google_pubsub_topic.inventory.name, google_pubsub_topic.shipments.name,
    google_pubsub_topic.dlq.name, google_pubsub_topic.migration_control.name,
  ]
}

output "subscription_names" {
  value = concat([
    google_pubsub_subscription.orders_inventory_service.name, google_pubsub_subscription.orders_dataflow.name,
    google_pubsub_subscription.orders_to_legacy_mq.name, google_pubsub_subscription.orders_bq_archive.name,
    google_pubsub_subscription.inventory_dataflow.name, google_pubsub_subscription.inventory_order_intake.name,
    google_pubsub_subscription.shipments_dataflow.name, google_pubsub_subscription.shipments_notification.name,
    google_pubsub_subscription.dlq_monitor.name,
  ], [for s in google_pubsub_subscription.migration_control : s.name])
}
