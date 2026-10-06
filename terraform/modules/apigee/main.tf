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

# /22 handed to Apigee's tenant project over VPC peering (fixed so it cannot collide with the PSC subnet).
resource "google_compute_global_address" "apigee_range" {
  project       = var.project_id
  name          = "apigee-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = "10.10.0.0"
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

  timeouts {
    create = "90m"
    delete = "90m"
  }
}

resource "google_apigee_instance" "instance" {
  name     = "tb-otd-${var.region}"
  location = var.region
  org_id   = google_apigee_organization.org.id

  timeouts {
    create = "120m"
    delete = "90m"
  }
}

resource "google_apigee_environment" "dev" {
  org_id = google_apigee_organization.org.id
  name   = "dev"
}

resource "google_apigee_envgroup" "default" {
  org_id    = google_apigee_organization.org.id
  name      = "default"
  # The demo host is <lb-ip>.nip.io (wildcard DNS that resolves to the IP inside the name), so no DNS
  # zone is needed; api.tb-otd.example stands in for the real corporate hostname.
  hostnames = ["api.tb-otd.example", "${google_compute_global_address.northbound.address}.nip.io"]
}

resource "google_apigee_envgroup_attachment" "dev" {
  envgroup_id = google_apigee_envgroup.default.id
  environment = google_apigee_environment.dev.name
}

resource "google_apigee_instance_attachment" "dev" {
  instance_id = google_apigee_instance.instance.id
  environment = google_apigee_environment.dev.name
}

# ---------------------------------------------------------------------------------------------
# Northbound (client -> Apigee) path. Apigee X runtime lives in a Google tenant project and is
# only reachable privately, so we publish it with Private Service Connect:
#   client -> global external Application LB (HTTP :80) -> PSC NEG -> Apigee service attachment
# Demo-grade: plain HTTP on the frontend. Production: HTTPS with a Google-managed cert + Cloud Armor.
# ---------------------------------------------------------------------------------------------
resource "google_compute_subnetwork" "psc" {
  project       = var.project_id
  name          = "apigee-psc-${var.region}"
  region        = var.region
  network       = google_compute_network.apigee.id
  ip_cidr_range = "10.20.0.0/28"
}

resource "google_compute_region_network_endpoint_group" "apigee" {
  project               = var.project_id
  name                  = "apigee-psc-neg"
  region                = var.region
  network_endpoint_type = "PRIVATE_SERVICE_CONNECT"
  psc_target_service    = google_apigee_instance.instance.service_attachment
  network               = google_compute_network.apigee.id
  subnetwork            = google_compute_subnetwork.psc.id
}

resource "google_compute_backend_service" "apigee" {
  project               = var.project_id
  name                  = "apigee-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  backend {
    group           = google_compute_region_network_endpoint_group.apigee.id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

resource "google_compute_url_map" "apigee" {
  project         = var.project_id
  name            = "apigee-url-map"
  default_service = google_compute_backend_service.apigee.id
}

resource "google_compute_target_http_proxy" "apigee" {
  project = var.project_id
  name    = "apigee-http-proxy"
  url_map = google_compute_url_map.apigee.id
}

resource "google_compute_global_address" "northbound" {
  project = var.project_id
  name    = "apigee-northbound-ip"
}

resource "google_compute_global_forwarding_rule" "apigee" {
  project               = var.project_id
  name                  = "apigee-http"
  target                = google_compute_target_http_proxy.apigee.id
  ip_address            = google_compute_global_address.northbound.address
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

output "apigee_host" {
  value = google_apigee_instance.instance.host
}

output "northbound_ip" {
  value = google_compute_global_address.northbound.address
}

output "northbound_hostname" {
  value = "${google_compute_global_address.northbound.address}.nip.io"
}
