variable "project_id" { type = string }
variable "region" { type = string }
variable "labels" { type = map(string) }

# Docker images for every service and the Dataflow Flex Template launchers.
resource "google_artifact_registry_repository" "docker" {
  project       = var.project_id
  location      = var.region
  repository_id = "tb-otd"
  format        = "DOCKER"
  description   = "Tailored Brands OTD platform images"
  labels        = var.labels

  # Keep the registry small: untagged images are removed after 7 days, keep last 10 tagged.
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s"
    }
  }
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

# Remote Maven repository proxying Maven Central — the enterprise pattern for
# builds that cannot reach the internet directly (what a locked-down CI would use).
resource "google_artifact_registry_repository" "maven_central_remote" {
  project       = var.project_id
  location      = var.region
  repository_id = "maven-central-remote"
  format        = "MAVEN"
  mode          = "REMOTE_REPOSITORY"
  description   = "Proxy of Maven Central for locked-down builds"
  labels        = var.labels

  remote_repository_config {
    description = "Maven Central"
    maven_repository {
      public_repository = "MAVEN_CENTRAL"
    }
  }
}

output "repository_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
}

output "maven_remote_url" {
  value = "https://${var.region}-maven.pkg.dev/${var.project_id}/${google_artifact_registry_repository.maven_central_remote.repository_id}"
}
