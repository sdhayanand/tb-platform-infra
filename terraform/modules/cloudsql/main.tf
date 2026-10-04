variable "project_id" { type = string }
variable "region" { type = string }
variable "tier" { type = string }
variable "labels" { type = map(string) }

# Cloud SQL PostgreSQL 15 — shared by order-intake-api and inventory-service (same DB, demo).
# Connections go through the Cloud SQL Java connector (socket factory) with IAM auth of the
# workload's service account + a DB password held in Secret Manager; no public authorized networks.
resource "google_sql_database_instance" "pg" {
  project             = var.project_id
  name                = "tb-otd-pg"
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = false

  settings {
    tier              = var.tier
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = true
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled = true          # connector handles auth/TLS; no authorized networks
      ssl_mode     = "ENCRYPTED_ONLY"
    }
    backup_configuration {
      enabled                        = true
      start_time                     = "09:00"
      point_in_time_recovery_enabled = false
      backup_retention_settings {
        retained_backups = 3
      }
    }
    maintenance_window {
      day  = 7
      hour = 10
    }
    database_flags {
      name  = "max_connections"
      value = "100"
    }
    insights_config {
      query_insights_enabled = true
    }
  }
}

resource "google_sql_database" "otd" {
  project  = var.project_id
  instance = google_sql_database_instance.pg.name
  name     = "otd"
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "google_sql_user" "otd" {
  project  = var.project_id
  instance = google_sql_database_instance.pg.name
  name     = "otd"
  password = random_password.db.result
}

# ---------------------------------------------------------------------------
# Secrets consumed by the deploy workflows / Cloud Run (--set-secrets)
# ---------------------------------------------------------------------------
resource "google_secret_manager_secret" "db_password" {
  project   = var.project_id
  secret_id = "otd-db-password"
  labels    = var.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

resource "random_password" "webhook_secret" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "webhook_secret" {
  project   = var.project_id
  secret_id = "webhook-shared-secret"
  labels    = var.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "webhook_secret" {
  secret      = google_secret_manager_secret.webhook_secret.id
  secret_data = random_password.webhook_secret.result
}

# JMS connection for the migration bridges / reconciler (in GCP the EMS stand-in is the
# ems-broker service in namespace `legacy`).
locals {
  jms = {
    "otd-jms-url"      = "tcp://ems-broker.legacy.svc.cluster.local:61616"
    "otd-jms-username" = "bridge"
    "otd-jms-password" = "bridge"
  }
}

resource "google_secret_manager_secret" "jms" {
  for_each  = local.jms
  project   = var.project_id
  secret_id = each.key
  labels    = var.labels
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "jms" {
  for_each    = local.jms
  secret      = google_secret_manager_secret.jms[each.key].id
  secret_data = each.value
}

output "connection_name" {
  value = google_sql_database_instance.pg.connection_name
}

output "password_secret_id" {
  value = google_secret_manager_secret.db_password.secret_id
}

output "db_user" {
  value = google_sql_user.otd.name
}
