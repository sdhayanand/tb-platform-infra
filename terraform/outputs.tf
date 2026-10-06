output "project_number" {
  value = local.project_number
}

output "artifact_registry" {
  value = module.registry.repository_url
}

output "service_account_emails" {
  value = module.iam.service_account_emails
}

output "buckets" {
  value = module.storage.bucket_names
}

output "pubsub_topics" {
  value = module.pubsub.topic_names
}

output "pubsub_subscriptions" {
  value = module.pubsub.subscription_names
}

output "bigquery_dataset" {
  value = module.bigquery.dataset_id
}

output "gke_location" {
  value = var.gke_location
}

output "gke_cluster_name" {
  value = var.enable_gke ? module.gke[0].cluster_name : null
}

output "cloudsql_connection_name" {
  value = var.enable_cloudsql ? module.cloudsql[0].connection_name : null
}

output "cloudsql_db_password_secret" {
  value = var.enable_cloudsql ? module.cloudsql[0].password_secret_id : null
}

output "notification_service_url" {
  value = local.notification_service_url
}

output "scheduler_job" {
  value = var.enable_scheduler ? module.scheduler[0].job_name : null
}

output "apigee_northbound_hostname" {
  description = "Public hostname of the Apigee proxy (http://<ip>.nip.io/v1/orders) when enable_apigee = true"
  value       = try(module.apigee[0].northbound_hostname, null)
}
