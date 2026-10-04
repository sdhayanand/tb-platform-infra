#!/usr/bin/env bash
# Configure the GitHub repository variables/secrets that every tb-* deploy workflow reads.
# Usage: source the block printed by bootstrap.sh (or export the variables) and run:
#   bash bootstrap/github-config.sh
# Requires: gh CLI authenticated as the repo owner.
set -euo pipefail

: "${GCP_PROJECT_ID:?}"; : "${GCP_WIF_PROVIDER:?}"; : "${GCP_DEPLOYER_SA:?}"; : "${TF_STATE_BUCKET:?}"
GCP_REGION="${GCP_REGION:-us-central1}"
OWNER="${GITHUB_OWNER:-sdhayanand}"
REPOS=(tb-platform-infra tb-integration-services tb-order-events-dataflow tb-tibco-to-pubsub-migration tb-legacy-simulators tb-orchestration)

for repo in "${REPOS[@]}"; do
  echo "==> ${OWNER}/${repo}"
  gh variable set GCP_PROJECT_ID --repo "${OWNER}/${repo}" --body "${GCP_PROJECT_ID}"
  gh variable set GCP_REGION     --repo "${OWNER}/${repo}" --body "${GCP_REGION}"
  gh variable set GKE_CLUSTER    --repo "${OWNER}/${repo}" --body "tb-otd-autopilot"
  gh variable set AR_REPO        --repo "${OWNER}/${repo}" --body "tb-otd"
  gh variable set TF_STATE_BUCKET --repo "${OWNER}/${repo}" --body "${TF_STATE_BUCKET}"
  gh secret set GCP_WIF_PROVIDER --repo "${OWNER}/${repo}" --body "${GCP_WIF_PROVIDER}"
  gh secret set GCP_DEPLOYER_SA  --repo "${OWNER}/${repo}" --body "${GCP_DEPLOYER_SA}"
done
echo "done"
