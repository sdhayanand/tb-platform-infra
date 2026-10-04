#!/usr/bin/env bash
# Post-deploy smoke test against the real GCP deployment (run from Cloud Shell or any gcloud-authed shell).
#   PROJECT_ID=crosscutdata-509514 scripts/smoke-gcp.sh
set -euo pipefail
PROJECT_ID="${PROJECT_ID:?}"; REGION="${REGION:-us-central1}"
gcloud container clusters get-credentials tb-otd-autopilot --region "${GKE_LOCATION:-us-east1}" --project "$PROJECT_ID" >/dev/null

API_IP=$(kubectl -n otd get svc order-intake-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
[ -n "$API_IP" ] || { echo "order-intake-api has no external IP yet"; exit 1; }
API="http://$API_IP:8080"
echo "order-intake-api: $API"

echo "== create order"
RESP=$(curl -fsS -X POST "$API/v1/orders" -H 'Content-Type: application/json' -d '{"orderType":"RETAIL","storeId":"0875","customerId":"C-SMOKE","lines":[{"sku":"MW-SUIT-NAVY-42R","quantity":1,"unitPrice":599.99,"fulfillmentType":"STORE_PICKUP"}]}')
ORDER_ID=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["orderId"])')
echo "created $ORDER_ID"
for i in $(seq 1 60); do
  S=$(curl -fsS "$API/v1/orders/$ORDER_ID" | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')
  [ "$S" = RESERVED ] && break; sleep 2
done
echo "status: $S"

echo "== Pub/Sub -> BigQuery raw archive (BigQuery subscription, no code)"
sleep 10
bq --project_id="$PROJECT_ID" query --nouse_legacy_sql --format=pretty \
  "SELECT message_id, publish_time, JSON_VALUE(data, '$.order.orderId') AS order_id, JSON_VALUE(attributes, '$.source') AS source
   FROM \`otd.orders_raw\` WHERE JSON_VALUE(data, '$.order.orderId') = '$ORDER_ID'"

echo "== Dataflow streaming -> otd.order_events (allow ~1 min)"
sleep 60
bq --project_id="$PROJECT_ID" query --nouse_legacy_sql --format=pretty \
  "SELECT event_type, store_id, store_name, total_amount, line_count FROM \`otd.order_events\` WHERE order_id = '$ORDER_ID'" || echo "(table appears after the streaming job's first write)"

echo "== shipment webhook (Cloud Run) -> push -> notification-service"
WEBHOOK_URL=$(gcloud run services describe shipment-webhook --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')
SECRET=$(gcloud secrets versions access latest --secret=webhook-shared-secret --project "$PROJECT_ID")
BODY=$(printf '{"trackingNumber":"1Z999AA10123456784","localActivityDate":"20261004","localActivityTime":"081500","gmtOffset":"-07:00","activityStatus":{"type":"I","code":"OT","description":"Out For Delivery Today"},"activityLocation":{"city":"Dublin","stateProvince":"CA","countryCode":"US"},"referenceNumbers":[{"code":"PO","value":"%s"}]}' "$ORDER_ID")
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
curl -fsS -o /dev/null -w "webhook -> %{http_code}\n" -X POST "$WEBHOOK_URL/v1/carriers/UPS/events" -H 'Content-Type: application/json' -H "X-Carrier-Signature: sha256=$SIG" --data "$BODY"
sleep 15
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=notification-service AND textPayload:$ORDER_ID OR jsonPayload.message:$ORDER_ID" --project "$PROJECT_ID" --limit 3 --format='value(textPayload,jsonPayload.message)' --freshness=10m

echo "== ERP side (pubsub-to-jms-bridge -> ems-broker ERP.ORDERS.IN -> erp-mq-consumer)"
kubectl -n legacy port-forward svc/erp-mq-consumer 18087:8087 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -fsS "http://localhost:18087/received/$ORDER_ID" | head -c 400; echo
kill $PF 2>/dev/null || true
echo "== done"
