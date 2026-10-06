#!/usr/bin/env bash
# Provision GCP Application Integration in the region and publish tb-shipment-exception-to-ops.
#   PROJECT_ID=... ORDER_API_BASE=http://<apigee-ip>.nip.io/v1/orders ORDER_API_KEY=... scripts/app-integration.sh
# Idempotent: safe to re-run (re-publishes a new version). Uses the Integrations REST API directly.
set -euo pipefail
PROJECT="${PROJECT_ID:?set PROJECT_ID}"
REGION="${REGION:-us-central1}"
NAME=tb-shipment-exception-to-ops
SA="tb-app-integration@${PROJECT}.iam.gserviceaccount.com"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
API="https://integrations.googleapis.com/v1/projects/${PROJECT}/locations/${REGION}"
TOKEN="$(gcloud auth print-access-token)"
BODY="$(mktemp)"
OUT_DIR="${OUT_DIR:-$(mktemp -d)}"
call() { CODE="$(curl -sS -o "$BODY" -w '%{http_code}' -X "$1" "$2" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' "${@:3}")"; }
jq_() { python3 -c "import json,sys; d=json.load(open('$BODY')); print($1)"; }
retry() { for i in 1 2 3 4 5 6; do "$@" && return 0; echo "    retry $i: $*"; sleep 10; done; return 1; }

echo "==> enable integrations.googleapis.com"
gcloud services enable integrations.googleapis.com --project "$PROJECT"

echo "==> service account the Pub/Sub trigger runs as: ${SA}"
gcloud iam service-accounts describe "$SA" --project "$PROJECT" >/dev/null 2>&1 || \
  gcloud iam service-accounts create tb-app-integration --project "$PROJECT" --display-name "Application Integration trigger"
retry gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:${SA}" \
  --role roles/integrations.integrationInvoker --condition=None --quiet >/dev/null

echo "==> Application Integration service agent: Pub/Sub editor (creates the trigger's subscription) + actAs ${SA}"
AGENT="$(gcloud beta services identity create --service=integrations.googleapis.com --project "$PROJECT" --format='value(email)')"
echo "    ${AGENT}"
retry gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:${AGENT}" \
  --role roles/pubsub.editor --condition=None --quiet >/dev/null
retry gcloud iam service-accounts add-iam-policy-binding "$SA" --project "$PROJECT" \
  --member "serviceAccount:${AGENT}" --role roles/iam.serviceAccountUser --quiet >/dev/null

echo "==> provision the region (${REGION})"
call POST "${API}/clients:provision" -d '{"provisionGmek": true}'
case "$CODE" in
  2*) echo "    provisioned";;
  409) echo "    already provisioned";;
  *) if grep -qi "already" "$BODY"; then echo "    already provisioned"; else echo "    HTTP $CODE"; cat "$BODY"; exit 1; fi;;
esac

echo "==> build integration version (order API: ${ORDER_API_BASE})"
V="${OUT_DIR}/version.json"
python3 "$HERE/app-integration/build_integration.py" > "$V"

echo "==> create a draft version"
call POST "${API}/integrations/${NAME}/versions?newIntegration=true" --data-binary "@${V}"
if [[ ! "$CODE" =~ ^2 ]]; then
  echo "    newIntegration=true -> HTTP $CODE: $(head -c 400 "$BODY" | tr '\n' ' ')"
  call POST "${API}/integrations/${NAME}/versions" --data-binary "@${V}"
fi
[[ "$CODE" =~ ^2 ]] || { echo "create version failed: HTTP $CODE"; cat "$BODY"; exit 1; }
VERSION="$(jq_ "d['name']")"
echo "    ${VERSION##*/}"

echo "==> publish"
call POST "https://integrations.googleapis.com/v1/${VERSION}:publish" -d '{}'
if [[ ! "$CODE" =~ ^2 ]] && grep -qi "already.*publish\|unpublish" "$BODY"; then
  echo "    unpublishing the active version first"
  call GET "${API}/integrations/${NAME}/versions?filter=state=ACTIVE"
  for v in $(jq_ "' '.join(x['name'] for x in d.get('integrationVersions',[]))"); do
    curl -sS -X POST "https://integrations.googleapis.com/v1/${v}:unpublish" -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' -d '{}' >/dev/null
  done
  call POST "https://integrations.googleapis.com/v1/${VERSION}:publish" -d '{}'
fi
[[ "$CODE" =~ ^2 ]] || { echo "publish failed: HTTP $CODE"; cat "$BODY"; exit 1; }
echo "    published ${VERSION##*/}"
echo "$VERSION" > "${OUT_DIR}/integration-version.txt"
