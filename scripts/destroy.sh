#!/usr/bin/env bash
# Tear down everything that costs money. Run from Cloud Shell (or dispatch the terraform workflow with action=destroy).
#   PROJECT_ID=crosscutdata-509514 scripts/destroy.sh
set -euo pipefail
PROJECT_ID="${PROJECT_ID:?}"; REGION="${REGION:-us-central1}"
echo "==> Dataflow jobs"
for j in $(gcloud dataflow jobs list --project "$PROJECT_ID" --region "$REGION" --status=active --format='value(id)'); do
  gcloud dataflow jobs cancel "$j" --project "$PROJECT_ID" --region "$REGION" || true
done
echo "==> Cloud Run services/jobs"
for s in shipment-webhook notification-service; do gcloud run services delete "$s" --region "$REGION" --project "$PROJECT_ID" --quiet || true; done
gcloud run jobs delete tb-reconciler --region "$REGION" --project "$PROJECT_ID" --quiet || true
echo "==> Terraform destroy (GKE, Cloud SQL, Pub/Sub, BigQuery, buckets, scheduler, IAM)"
cd "$(dirname "$0")/../terraform"
terraform init -backend-config="bucket=${PROJECT_ID}-tb-otd-tfstate" >/dev/null
terraform destroy -auto-approve -var-file=envs/dev.tfvars -var="project_id=${PROJECT_ID}"
echo "==> done. Remaining (free) items: WIF pool, deployer SA, tfstate bucket — delete the project to remove them."
