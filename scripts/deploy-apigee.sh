#!/usr/bin/env bash
# Deploy the tb-order-api-v1 proxy bundle to an Apigee X org with apigeecli.
# Prereqs: gcloud auth (ADC), an Apigee org (terraform enable_apigee=true), apigeecli on PATH
#   (curl -L https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | sh -)
set -euo pipefail
ORG="${APIGEE_ORG:?set APIGEE_ORG (= GCP project id)}"
ENV="${APIGEE_ENV:-dev}"
BACKEND_HOST="${BACKEND_HOST:?set BACKEND_HOST (order-intake-api load balancer IP or DNS)}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN="$(gcloud auth print-access-token)"

echo "==> target server"
apigeecli targetservers create --org "$ORG" --env "$ENV" --name order-intake-api \
  --host "$BACKEND_HOST" --port "$BACKEND_PORT" --enable=true --token "$TOKEN" 2>/dev/null || \
apigeecli targetservers update --org "$ORG" --env "$ENV" --name order-intake-api \
  --host "$BACKEND_HOST" --port "$BACKEND_PORT" --enable=true --token "$TOKEN"

echo "==> import + deploy proxy"
cd "$HERE/apigee"
rm -f tb-order-api-v1.zip && zip -qr tb-order-api-v1.zip apiproxy
apigeecli apis create bundle --org "$ORG" --name tb-order-api-v1 --proxy-zip tb-order-api-v1.zip --token "$TOKEN"
REV="$(apigeecli apis listdeploy --org "$ORG" --name tb-order-api-v1 --token "$TOKEN" 2>/dev/null | grep -o '"revision": *"[0-9]*"' | tail -1 | grep -o '[0-9]*' || true)"
LATEST="$(apigeecli apis get --org "$ORG" --name tb-order-api-v1 --token "$TOKEN" | grep -o '"revision": *\[[^]]*\]' | grep -o '[0-9]*' | sort -n | tail -1)"
apigeecli apis deploy --org "$ORG" --env "$ENV" --name tb-order-api-v1 --rev "$LATEST" --ovr --wait --token "$TOKEN"

echo "==> API product / developer / app (for the demo API key)"
apigeecli products create --org "$ORG" --name tb-order-api-stores --display-name "TB Order API — stores" \
  --envs "$ENV" --proxies tb-order-api-v1 --approval auto --quota 100000 --interval 1 --unit day \
  --attrs "access=internal" --token "$TOKEN" 2>/dev/null || true
apigeecli developers create --org "$ORG" --user storepos --email store-pos@tailoredbrands.example \
  --first Store --last POS --token "$TOKEN" 2>/dev/null || true
apigeecli apps create --org "$ORG" --name store-pos-app --email store-pos@tailoredbrands.example \
  --prods tb-order-api-stores --token "$TOKEN" 2>/dev/null || true
echo "==> API key:"
apigeecli apps get --org "$ORG" --name store-pos-app --token "$TOKEN" | grep -o '"consumerKey": *"[^"]*"' | head -1
echo "==> host:"
apigeecli envgroups list --org "$ORG" --token "$TOKEN" | grep -o '"hostnames": *\[[^]]*\]' | head -1
