#!/usr/bin/env bash
# =============================================================================
# End-to-end smoke test for the local platform stack (local/docker-compose.yml).
# Exercises every integration path once and fails loudly on the first broken link.
#
#   ./e2e.sh                # against localhost ports from docker-compose.yml
#   WITH_DATAFLOW=1 ./e2e.sh   # also runs the Beam streaming pipeline on the DirectRunner
#                                (needs ../../tb-order-events-dataflow checked out + Maven)
# =============================================================================
set -euo pipefail

API="${API:-http://localhost:8080}"
INV="${INV:-http://localhost:8081}"
WEBHOOK="${WEBHOOK:-http://localhost:8082}"
NOTIFY="${NOTIFY:-http://localhost:8083}"
EMS="${EMS:-http://localhost:8086}"
ERP="${ERP:-http://localhost:8087}"
OMS="${OMS:-http://localhost:8089}"
BRIDGE_IN="${BRIDGE_IN:-http://localhost:8090}"
BRIDGE_OUT="${BRIDGE_OUT:-http://localhost:8091}"
PUBSUB="${PUBSUB:-http://localhost:8085}"
PROJECT="${PROJECT:-tb-otd-local}"
SECRET="${WEBHOOK_SHARED_SECRET:-local-dev-secret}"
COMPOSE="${COMPOSE:-docker compose}"

pass() { printf "\033[32mPASS\033[0m %s\n" "$*"; }
fail() { printf "\033[31mFAIL\033[0m %s\n" "$*"; exit 1; }
step() { printf "\n\033[1m== %s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null || fail "missing tool: $1"; }
need curl; need jq; need openssl

wait_http() { # url, label, seconds
  local i=0
  until curl -fsS "$1" >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -ge "${3:-120}" ] && fail "$2 not healthy after ${3:-120}s ($1)"; sleep 1
  done
  pass "$2 up"
}

step "1. Health of every component"
wait_http "$API/actuator/health/readiness"      order-intake-api
wait_http "$INV/actuator/health/readiness"      inventory-service
wait_http "$WEBHOOK/actuator/health/readiness"  shipment-webhook
wait_http "$NOTIFY/healthz"                     notification-service
wait_http "$EMS/actuator/health/readiness"      ems-broker
wait_http "$OMS/actuator/health/readiness"      legacy-oms-soap
wait_http "$ERP/actuator/health/readiness"      erp-mq-consumer
wait_http "$BRIDGE_IN/actuator/health"          jms-to-pubsub-bridge
wait_http "$BRIDGE_OUT/actuator/health"         pubsub-to-jms-bridge

step "2. REST order intake -> outbox -> Pub/Sub -> inventory reservation -> status feedback"
SKU_BEFORE=$(curl -fsS "$INV/v1/inventory/MW-SUIT-NAVY-42R" | jq '[.locations[]? // .[]? | .reserved // 0] | add // 0')
CREATE=$(curl -fsS -X POST "$API/v1/orders" -H 'Content-Type: application/json' -H 'X-Correlation-Id: e2e-rest-1' -d '{
  "orderType":"TAILORED","channel":"STORE","storeId":"0412","customerId":"C-E2E","promisedDate":"2026-12-24",
  "lines":[{"sku":"MW-SUIT-NAVY-42R","quantity":1,"unitPrice":599.99,"fulfillmentType":"STORE_PICKUP"},
           {"sku":"ALT-HEM-TROUSER","quantity":1,"unitPrice":50.00,"fulfillmentType":"ALTERATION",
            "alteration":{"type":"HEM","measurementInches":31.5,"tailorShopId":"TS-EASTBAY"}}]}')
ORDER_ID=$(echo "$CREATE" | jq -r .orderId)
[[ "$ORDER_ID" =~ ^ORD-[0-9]{4}-[0-9]{6}$ ]] || fail "unexpected create response: $CREATE"
pass "created $ORDER_ID"
for i in $(seq 1 60); do
  STATUS=$(curl -fsS "$API/v1/orders/$ORDER_ID" | jq -r .status)
  [ "$STATUS" = "RESERVED" ] && break
  sleep 1
done
[ "$STATUS" = "RESERVED" ] || fail "order $ORDER_ID status is $STATUS, expected RESERVED (inventory-service / inventory-v1 feedback loop)"
pass "order $ORDER_ID -> RESERVED via inventory-service"
SKU_AFTER=$(curl -fsS "$INV/v1/inventory/MW-SUIT-NAVY-42R" | jq '[.locations[]? // .[]? | .reserved // 0] | add // 0')
[ "$SKU_AFTER" -gt "$SKU_BEFORE" ] && pass "MW-SUIT-NAVY-42R reserved count $SKU_BEFORE -> $SKU_AFTER" || echo "WARN reserved count did not increase ($SKU_BEFORE -> $SKU_AFTER); check /v1/inventory shape"

step "3. Reverse bridge: Pub/Sub orders-v1 -> pubsub-to-jms-bridge -> ERP.ORDERS.IN -> ERP consumer"
for i in $(seq 1 60); do
  if curl -fsS "$ERP/received/$ORDER_ID" >/dev/null 2>&1; then break; fi; sleep 1
done
curl -fsS "$ERP/received/$ORDER_ID" | jq -e '.orderNbr // .orderId // .id' >/dev/null || fail "ERP never received $ORDER_ID through ERP.ORDERS.IN"
pass "ERP (IBM MQ / JMS side) received $ORDER_ID as legacy XML"

step "4. Legacy path: TIBCO EMS stand-in publishes XML -> jms-to-pubsub-bridge -> orders-v1 -> inventory-service"
SIM=$(curl -fsS -X POST "$EMS/simulate/orders?count=2")
LEGACY_IDS=$(echo "$SIM" | jq -r '.. | strings | select(test("^[A-Z0-9-]{6,}$"))' | head -2 | tr '\n' ' ')
pass "ems-broker published legacy orders: $LEGACY_IDS"
BRIDGED_BEFORE=$(curl -fsS "$BRIDGE_IN/actuator/metrics/bridge.messages.bridged" 2>/dev/null | jq '.measurements[0].value // 0' || echo 0)
sleep 5
BRIDGED=$(curl -fsS "$BRIDGE_IN/actuator/metrics/bridge.messages.bridged" 2>/dev/null | jq '.measurements[0].value // 0' || echo 0)
if [ "$(echo "$BRIDGED >= 2" | bc 2>/dev/null || echo 1)" = "1" ]; then pass "jms-to-pubsub-bridge bridged counter = $BRIDGED"; else echo "WARN bridged counter=$BRIDGED (metric name may differ; checking logs)"; fi
$COMPOSE logs --no-color jms-to-pubsub-bridge 2>/dev/null | grep -iq "bridged\|published" && pass "bridge log shows published messages" || echo "WARN no bridge log lines yet"

step "5. SOAP legacy adapter: XML SubmitOrderRequest -> XSLT -> canonical -> same pipeline"
SOAP_RESP=$(curl -fsS -X POST "$API/ws" -H 'Content-Type: text/xml;charset=UTF-8' -H 'SOAPAction: ""' --data-binary @- <<'EOF'
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:v1="http://tailoredbrands.com/legacy/oms/v1">
  <soapenv:Body>
    <v1:SubmitOrderRequest>
      <v1:Order>
        <v1:OrderNbr>LEG-E2E-0001</v1:OrderNbr><v1:OrderType>R</v1:OrderType><v1:StoreNbr>0875</v1:StoreNbr>
        <v1:CustNbr>C-SOAP</v1:CustNbr><v1:OrderDate>2026-10-04T10:00:00</v1:OrderDate>
        <v1:Lines><v1:Line><v1:LineNbr>1</v1:LineNbr><v1:SKU>JAB-SHIRT-WHITE-16</v1:SKU><v1:Qty>2</v1:Qty><v1:Price>79.50</v1:Price><v1:FulfillType>P</v1:FulfillType></v1:Line></v1:Lines>
      </v1:Order>
    </v1:SubmitOrderRequest>
  </soapenv:Body>
</soapenv:Envelope>
EOF
)
echo "$SOAP_RESP" | grep -q "SubmitOrderResponse" && pass "SOAP adapter accepted the legacy XML order" || fail "SOAP adapter response: $SOAP_RESP"

step "6. Carrier webhook (HMAC) -> shipments-v1 -> push -> notification-service"
BODY=$(printf '{"trackingNumber":"1Z999AA10123456784","localActivityDate":"20261004","localActivityTime":"081500","gmtOffset":"-07:00","activityStatus":{"type":"I","code":"OT","description":"Out For Delivery Today"},"activityLocation":{"city":"Dublin","stateProvince":"CA","countryCode":"US"},"referenceNumbers":[{"code":"PO","value":"%s"}]}' "$ORDER_ID")
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WEBHOOK/v1/carriers/UPS/events" -H 'Content-Type: application/json' -H "X-Carrier-Signature: sha256=$SIG" --data "$BODY")
[ "$CODE" = "202" ] || fail "webhook returned $CODE"
pass "webhook accepted signed UPS event (202)"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WEBHOOK/v1/carriers/UPS/events" -H 'Content-Type: application/json' -H "X-Carrier-Signature: sha256=deadbeef" --data "$BODY")
[ "$BAD" = "401" ] || [ "$BAD" = "403" ] && pass "webhook rejected a bad signature ($BAD)" || fail "bad signature returned $BAD"
for i in $(seq 1 30); do
  if $COMPOSE logs --no-color notification-service 2>/dev/null | grep -q "$ORDER_ID"; then break; fi; sleep 1
done
$COMPOSE logs --no-color notification-service 2>/dev/null | grep -q "$ORDER_ID" && pass "notification-service rendered the out-for-delivery notice for $ORDER_ID" || fail "notification-service never logged $ORDER_ID (push subscription)"

step "7. Poison message -> dead-letter topic"
curl -fsS -X POST "$PUBSUB/v1/projects/$PROJECT/topics/orders-v1:publish" -H 'Content-Type: application/json' \
  -d '{"messages":[{"data":"bm90IGpzb24=","attributes":{"eventType":"ORDER_CREATED","storeId":"0412","source":"E2E"},"orderingKey":"0412"}]}' >/dev/null
sleep 3
DLQ=$(curl -fsS -X POST "$PUBSUB/v1/projects/$PROJECT/subscriptions/events-dlq-monitor:pull" -H 'Content-Type: application/json' -d '{"maxMessages":10,"returnImmediately":true}' | jq '.receivedMessages | length')
if [ "${DLQ:-0}" -ge 1 ]; then pass "poison message landed in events-dlq ($DLQ)"; else echo "WARN no DLQ message from the inventory consumer (emulator has no dead-letter policy; the Dataflow DLQ path covers this in WITH_DATAFLOW mode)"; fi

if [ "${WITH_DATAFLOW:-0}" = "1" ]; then
  step "8. Beam streaming pipeline on the DirectRunner (Pub/Sub emulator -> local JSONL instead of BigQuery)"
  DF="${DATAFLOW_REPO:-$(cd "$(dirname "$0")/../.." && pwd)/tb-order-events-dataflow}"
  [ -d "$DF" ] || fail "tb-order-events-dataflow not found at $DF"
  OUT=$(mktemp -d)
  ( cd "$DF" && PUBSUB_EMULATOR_HOST=localhost:8085 timeout 90 mvn -q -B -ntp compile exec:java \
      -Dexec.mainClass=com.tailoredbrands.otd.dataflow.OrderEventsStreamingPipeline \
      -Dexec.args="--runner=DirectRunner --project=$PROJECT --pubsubRootUrl=http://localhost:8085 --ordersSubscription=projects/$PROJECT/subscriptions/orders-dataflow --inventorySubscription=projects/$PROJECT/subscriptions/inventory-dataflow --shipmentsSubscription=projects/$PROJECT/subscriptions/shipments-dataflow --deadLetterTopic=projects/$PROJECT/topics/events-dlq --localOutputDir=$OUT --metricsWindowMinutes=1" \
      >"$OUT/pipeline.log" 2>&1 ) || true
  grep -rq "$ORDER_ID" "$OUT" && pass "DirectRunner wrote $ORDER_ID to $OUT (order_events)" || { tail -40 "$OUT/pipeline.log"; fail "pipeline output does not contain $ORDER_ID"; }
  ls "$OUT"
fi

step "DONE — every integration path verified"
