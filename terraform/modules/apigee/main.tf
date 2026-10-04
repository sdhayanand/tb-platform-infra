variable "project_id" { type = string }
variable "project_number" { type = string }
variable "region" { type = string }

# Apigee X evaluation organization (free for 60 days, ~1h to provision). Off by default.
# After it exists, deploy the proxy bundle in ../../apigee with scripts/deploy-apigee.sh.
resource "google_project_service" "apigee" {
  project            = var.project_id
  service            = "apigee.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "apigee" {
  project                 = var.project_id
  name                    = "apigee-network"
  auto_create_subnetworks = false
}

resource "google_compute_global_address" "apigee_range" {
  project       = var.project_id
  name          = "apigee-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 22
  network       = google_compute_network.apigee.id
}

resource "google_service_networking_connection" "apigee_vpc_connection" {
  network                 = google_compute_network.apigee.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.apigee_range.name]
}

resource "google_apigee_organization" "org" {
  project_id         = var.project_id
  analytics_region   = var.region
  display_name       = "tb-otd-eval"
  runtime_type       = "CLOUD"
  billing_type       = "EVALUATION"
  authorized_network = google_compute_network.apigee.id
  depends_on         = [google_service_networking_connection.apigee_vpc_connection, google_project_service.apigee]
}

resource "google_apigee_instance" "instance" {
  name     = "tb-otd-${var.region}"
  location = var.region
  org_id   = google_apigee_organization.org.id
}

resource "google_apigee_environment" "dev" {
  org_id = google_apigee_organization.org.id
  name   = "dev"
}

resource "google_apigee_envgroup" "default" {
  org_id    = google_apigee_organization.org.id
  name      = "default"
  hostnames = ["api.tb-otd.example"]
}

resource "google_apigee_envgroup_attachment" "dev" {
  envgroup_id = google_apigee_envgroup.default.id
  environment = google_apigee_environment.dev.name
}

resource "google_apigee_instance_attachment" "dev" {
  instance_id = google_apigee_instance.instance.id
  environment = google_apigee_environment.dev.name
}

output "apigee_host" {
  value = google_apigee_instance.instance.host
}
