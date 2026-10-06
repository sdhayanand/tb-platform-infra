#!/usr/bin/env bash
# Deploy the tb-order-api-v1 proxy to the Apigee X org with the plain Apigee REST API (curl only,
# so every step is visible): target server -> import bundle -> deploy -> API product -> developer -> app.
# Prereqs: gcloud auth (ADC) and the org from terraform (enable_apigee = true).
#   APIGEE_ORG=<project-id> BACKEND_HOST=<order-intake LB IP> scripts/deploy-apigee.sh
# Writes the app's API key to $KEY_FILE (default .apigee-key, git-ignored); never prints it.
set -euo pipefail
ORG="${APIGEE_ORG:?set APIGEE_ORG (= GCP project id)}"
ENV="${APIGEE_ENV:-dev}"
API=tb-order-api-v1
PRODUCT=tb-order-api-stores
DEV_EMAIL=store-pos@tailoredbrands.example
APP=store-pos-app
BACKEND_HOST="${BACKEND_HOST:?set BACKEND_HOST (order-intake-api load balancer IP or DNS)}"
BACKEND_PORT="${BACKEND_PORT:-80}"
KEY_FILE="${KEY_FILE:-.apigee-key}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
A="${APIGEE_API:-https://apigee.googleapis.com/v1}/organizations/${ORG}"
TOKEN="${TOKEN:-$(gcloud auth print-access-token)}"
BODY="$(mktemp)"
api() { # api METHOD PATH [curl args...] -> response body in $BODY, HTTP code in $CODE (call directly, not in $(...))
  local m="$1" p="$2"; shift 2
  CODE="$(curl -sS -o "$BODY" -w '%{http_code}' -X "$m" "${A}${p}" -H "Authorization: Bearer ${TOKEN}" "$@")"
}
json() { python3 -c "import sys,json; d=json.load(open('$BODY')); print($1)"; }

echo "==> org"
api GET ""; [ "$CODE" = 200 ] || { echo "Apigee org ${ORG} not ready (HTTP $CODE)"; exit 1; }

echo "==> target server order-intake-api -> ${BACKEND_HOST}:${BACKEND_PORT}"
TS="{\"name\":\"order-intake-api\",\"host\":\"${BACKEND_HOST}\",\"port\":${BACKEND_PORT},\"isEnabled\":true}"
api POST "/environments/${ENV}/targetservers" -H 'Content-Type: application/json' -d "$TS"
if [ "$CODE" = 409 ]; then
  api PUT "/environments/${ENV}/targetservers/order-intake-api" -H 'Content-Type: application/json' -d "$TS"
fi
[[ "$CODE" =~ ^20 ]] || { echo "target server failed: HTTP $CODE"; exit 1; }

echo "==> import bundle"
ZIP="$(mktemp -d)/${API}.zip"
(cd "$HERE/apigee" && zip -qr "$ZIP" apiproxy)
api POST "/apis?name=${API}&action=import&validate=true" -F "file=@${ZIP}"
[[ "$CODE" =~ ^20 ]] || { echo "import failed: HTTP $CODE"; cat "$BODY"; exit 1; }
REV="$(json "d['revision']")"
echo "    revision ${REV}"

echo "==> deploy revision ${REV} to ${ENV}"
api POST "/environments/${ENV}/apis/${API}/revisions/${REV}/deployments?override=true"
[[ "$CODE" =~ ^20 ]] || { echo "deploy failed: HTTP $CODE"; cat "$BODY"; exit 1; }
for i in $(seq 1 60); do
  api GET "/environments/${ENV}/apis/${API}/revisions/${REV}/deployments"
  STATE="$(json "d.get('state','')" || true)"
  echo "    state=${STATE}"
  [ "$STATE" = READY ] && break
  [ "$STATE" = ERROR ] && { cat "$BODY"; exit 1; }
  sleep 10
done
[ "$STATE" = READY ] || { echo "deployment not READY"; exit 1; }

echo "==> API product ${PRODUCT} (quota 100000/day)"
api POST "/apiproducts" -H 'Content-Type: application/json' -d "{
  \"name\":\"${PRODUCT}\",\"displayName\":\"TB Order API - stores\",\"approvalType\":\"auto\",
  \"environments\":[\"${ENV}\"],\"proxies\":[\"${API}\"],\"attributes\":[{\"name\":\"access\",\"value\":\"internal\"}],
  \"quota\":\"100000\",\"quotaInterval\":\"1\",\"quotaTimeUnit\":\"day\"}"
[[ "$CODE" =~ ^20|409 ]] || { echo "product failed: HTTP $CODE"; exit 1; }

echo "==> developer + app"
api POST "/developers" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${DEV_EMAIL}\",\"firstName\":\"Store\",\"lastName\":\"POS\",\"userName\":\"storepos\"}"
[[ "$CODE" =~ ^20|409 ]] || { echo "developer failed: HTTP $CODE"; exit 1; }
api POST "/developers/${DEV_EMAIL}/apps" -H 'Content-Type: application/json' \
  -d "{\"name\":\"${APP}\",\"apiProducts\":[\"${PRODUCT}\"]}"
[[ "$CODE" =~ ^20|409 ]] || { echo "app failed: HTTP $CODE"; cat "$BODY"; exit 1; }
api GET "/developers/${DEV_EMAIL}/apps/${APP}"
json "d['credentials'][0]['consumerKey']" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
echo "==> done. API key written to ${KEY_FILE}"
