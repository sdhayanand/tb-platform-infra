#!/usr/bin/env bash
# =============================================================================
# tb-platform-infra :: one-time GCP bootstrap (run in Cloud Shell)
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/sdhayanand/tb-platform-infra/main/bootstrap/bootstrap.sh)
#   -- or paste the whole file into Cloud Shell --
#
# What it does (idempotent, safe to re-run):
#   1. Enables the GCP APIs the platform needs
#   2. Creates the Terraform state bucket
#   3. Creates the deployer service account used by GitHub Actions
#   4. Sets up keyless Workload Identity Federation for github.com/<GITHUB_OWNER>
#   5. Prints the values to configure in GitHub (bootstrap/github-config.sh does that part)
#
# Nothing here costs money by itself; the expensive resources are created by Terraform later.
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-crosscutdata-509514}"
GITHUB_OWNER="${GITHUB_OWNER:-sdhayanand}"
REGION="${REGION:-us-central1}"
POOL_ID="github-pool"
PROVIDER_ID="github-provider"
DEPLOYER_SA_NAME="tb-deployer"

echo "==> Project: ${PROJECT_ID}   GitHub owner: ${GITHUB_OWNER}   Region: ${REGION}"
gcloud config set project "${PROJECT_ID}" --quiet
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
echo "==> Project number: ${PROJECT_NUMBER}"

echo "==> [1/5] Enabling APIs (this takes 1-3 minutes)"
# gcloud enables at most 20 services per call, so the list is split in two batches.
gcloud services enable \
  serviceusage.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com compute.googleapis.com \
  container.googleapis.com run.googleapis.com pubsub.googleapis.com dataflow.googleapis.com \
  bigquery.googleapis.com \
  --project "${PROJECT_ID}"
gcloud services enable \
  bigquerystorage.googleapis.com sqladmin.googleapis.com servicenetworking.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com storage.googleapis.com logging.googleapis.com \
  monitoring.googleapis.com cloudtrace.googleapis.com \
  --project "${PROJECT_ID}"

echo "==> [2/5] Terraform state bucket"
TF_STATE_BUCKET="${PROJECT_ID}-tb-otd-tfstate"
if ! gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${TF_STATE_BUCKET}" --location="${REGION}" \
    --uniform-bucket-level-access --public-access-prevention
  gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning
fi

echo "==> [3/5] Deployer service account"
DEPLOYER_SA="${DEPLOYER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "${DEPLOYER_SA}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${DEPLOYER_SA_NAME}" \
    --display-name="Tailored Brands OTD platform deployer (GitHub Actions)"
fi
# Demo project: the deployer owns the project so Terraform can create IAM bindings, SAs, WIF, etc.
# In a real org you would split this into a least-privilege set per workflow.
# A brand-new service account takes a few seconds to become visible to IAM; retry the binding.
for attempt in 1 2 3 4 5 6; do
  if gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
       --member="serviceAccount:${DEPLOYER_SA}" --role="roles/owner" --condition=None --quiet >/dev/null 2>&1; then
    break
  fi
  [ "$attempt" -eq 6 ] && { echo "IAM binding for ${DEPLOYER_SA} failed after retries"; exit 1; }
  echo "    service account not visible to IAM yet, retrying in 10s ($attempt/6)"; sleep 10
done

echo "==> [4/5] Workload Identity Federation for GitHub Actions"
if ! gcloud iam workload-identity-pools describe "${POOL_ID}" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_ID}" --location=global \
    --display-name="GitHub Actions pool"
fi
if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
      --location=global --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --location=global --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_OWNER}'"
fi
WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
gcloud iam service-accounts add-iam-policy-binding "${DEPLOYER_SA}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository_owner/${GITHUB_OWNER}" \
  --quiet >/dev/null

echo "==> [5/5] Done. Paste the block below back to Claude (or run bootstrap/github-config.sh):"
cat <<EOF

GCP_PROJECT_ID=${PROJECT_ID}
GCP_PROJECT_NUMBER=${PROJECT_NUMBER}
GCP_REGION=${REGION}
GCP_WIF_PROVIDER=${WIF_PROVIDER}
GCP_DEPLOYER_SA=${DEPLOYER_SA}
TF_STATE_BUCKET=${TF_STATE_BUCKET}

EOF
