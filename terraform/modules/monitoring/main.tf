variable "project_id" { type = string }
variable "alert_email" { type = string }

locals {
  channels = var.alert_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email != "" ? 1 : 0
  project      = var.project_id
  display_name = "OTD platform alerts"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

# 1. Anything in the dead-letter topic is a bug or a bad producer: page quickly.
resource "google_monitoring_alert_policy" "dlq_backlog" {
  project      = var.project_id
  display_name = "OTD: dead-letter backlog > 0"
  combiner     = "OR"
  conditions {
    display_name = "events-dlq-monitor undelivered messages"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"events-dlq-monitor\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
  notification_channels = local.channels
  documentation {
    content = "Messages are landing in events-dlq. Pull a sample: gcloud pubsub subscriptions pull events-dlq-monitor --limit 5 --format=json and check attributes dlqReason/dlqStage. See tb-platform-infra/docs/RUNBOOK-OPERATIONS.md"
  }
}

# 2. Consumer lag on the inventory subscription (ordering keys make a stuck key visible here).
resource "google_monitoring_alert_policy" "inventory_lag" {
  project      = var.project_id
  display_name = "OTD: orders-inventory-service oldest unacked > 5 min"
  combiner     = "OR"
  conditions {
    display_name = "oldest_unacked_message_age"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"orders-inventory-service\" AND metric.type = \"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
      comparison      = "COMPARISON_GT"
      threshold_value = 300
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
  notification_channels = local.channels
}

# 3. Streaming pipeline falling behind (system lag) — Dataflow autoscaling should keep this low.
resource "google_monitoring_alert_policy" "dataflow_lag" {
  project      = var.project_id
  display_name = "OTD: Dataflow streaming system lag > 2 min"
  combiner     = "OR"
  conditions {
    display_name = "job/system_lag"
    condition_threshold {
      filter          = "resource.type = \"dataflow_job\" AND metric.type = \"dataflow.googleapis.com/job/system_lag\" AND metadata.user_labels.pipeline = \"order-events-streaming\""
      comparison      = "COMPARISON_GT"
      threshold_value = 120
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
  notification_channels = local.channels
}

# 4. Cloud Run push target erroring (notification-service) — 5xx ratio.
resource "google_monitoring_alert_policy" "notification_5xx" {
  project      = var.project_id
  display_name = "OTD: notification-service 5xx"
  combiner     = "OR"
  conditions {
    display_name = "request_count 5xx"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"notification-service\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.labels.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
  notification_channels = local.channels
}

# Log-based metric: dual-write failures during the migration (phase DUAL_RUN).
resource "google_logging_metric" "dual_write_failures" {
  project     = var.project_id
  name        = "otd/dual_write_failures"
  description = "order-intake-api failed to send the legacy copy of an order during DUAL_RUN"
  filter      = "resource.type=\"k8s_container\" AND resource.labels.namespace_name=\"otd\" AND jsonPayload.message:\"dual-write failed\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}
