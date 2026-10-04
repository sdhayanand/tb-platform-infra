variable "project_id" { type = string }
variable "region" { type = string }
variable "labels" { type = map(string) }

locals {
  buckets = {
    # Flex Template specs + launcher images metadata, staging and temp for Dataflow jobs
    "dataflow" = { name = "${var.project_id}-tb-otd-dataflow", lifecycle_days = 14 }
    # Nightly legacy OMS XML extracts (input of the daily reconciliation batch)
    "legacy-extracts" = { name = "${var.project_id}-tb-otd-legacy-extracts", lifecycle_days = 90 }
    # Reconciliation CSV reports
    "reports" = { name = "${var.project_id}-tb-otd-reports", lifecycle_days = 180 }
    # Store reference data (CSV side input for Dataflow enrichment)
    "reference" = { name = "${var.project_id}-tb-otd-reference", lifecycle_days = 0 }
  }
}

resource "google_storage_bucket" "this" {
  for_each                    = local.buckets
  project                     = var.project_id
  name                        = each.value.name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
  labels                      = var.labels

  versioning {
    enabled = false
  }

  dynamic "lifecycle_rule" {
    for_each = each.value.lifecycle_days > 0 ? [1] : []
    content {
      action {
        type = "Delete"
      }
      condition {
        age = each.value.lifecycle_days
      }
    }
  }
}

# Store reference data used by the streaming pipeline side input.
resource "google_storage_bucket_object" "store_reference" {
  bucket  = google_storage_bucket.this["reference"].name
  name    = "stores/store-reference.csv"
  content = file("${path.module}/store-reference.csv")
}

output "bucket_names" {
  value = { for k, b in google_storage_bucket.this : k => b.name }
}
