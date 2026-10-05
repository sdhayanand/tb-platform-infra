#!/usr/bin/env bash
# =============================================================================
# End-to-end smoke test against the real GCP deployment.
#   PROJECT_ID=crosscutdata-509514 scripts/smoke-gcp.sh          (Cloud Shell or any gcloud-authed shell)
# Also run by .github/workflows/smoke-gcp.yml, where every check becomes a run annotation.
#
# Follows one order through every integration path:
#   REST -> order-intake-api (GKE) -> outbox -> Pub/Sub orders-v1
#        -> inventory-service (exactly-once sub) -> inventory-v1 -> order status RESERVED
#        -> BigQuery subscription (otd.orders_raw)            [zero-code archive]
#        -> Dataflow streaming job (otd.order_events)         [Beam on Dataflow]
#        -> pubsub-to-jms-bridge -> IBM MQ ERP.ORDERS.IN -> erp-mq-consumer   [migration, reverse]
#   TIBCO EMS stand-in -> jms-to-pubsub-bridge -> orders-v1                    [migration, forward]
#   carrier webhook (Cloud Run, HMAC) -> shipments-v1 -> push (OIDC) -> notification-service (Cloud Run)
# =============================================================================
set -uo pipefail
PROJECT_ID="${PROJECT_ID:?set PROJECT_ID}"
REGION="${REGION:-us-central1}"
GKE_LOCATION="${GKE_LOCATION:-us-east1}"
FAILS=0

note() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=$1::$2"; else printf "\033[32mPASS\033[0m %-28s %s\n" "$1" "$2"; fi; }
bad()  { FAILS=$((FAILS+1)); if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=$1::$2"; else printf "\033[31mFAIL\033[0m %-28s %s\n" "$1" "$2"; fi; }
info() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=$1::$2"; else printf "INFO %-28s %s\n" "$1" "$2"; fi; }
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
# first column of the first row, or the BigQuery error text
bqq()  { bq --project_id="$PROJECT_ID" query --nouse_legacy_sql --format=json --quiet "$1" 2>&1 \
           | python3 -c "import sys,json
t=sys.stdin.read()
try:
    rows=json.loads(t[t.index('['):])
    print(list(rows[0].values())[0] if rows else '')
except Exception:
    print(' '.join(t.split())[:400])"; }

gcloud container clusters get-credentials tb-otd-autopilot --region "$GKE_LOCATION" --project "$PROJECT_ID" >/dev/null 2>&1 \
  || { bad "gke" "cannot get credentials for tb-otd-autopilot in $GKE_LOCATION"; exit 1; }

# ---------- 0. workloads ----------
for ns in otd legacy; do
  # long-running workloads only (pods created by Jobs/CronJobs are reported separately below)
  PODS=$(kubectl -n "$ns" get pods --no-headers -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,PHASE:.status.phase,OWNER:.metadata.ownerReferences[0].kind 2>/dev/null | grep -v " Job$")
  NOTREADY=$(echo "$PODS" | awk 'NF && ($2 ~ /false/ || $3!="Running") {print $1"("$3")"}' | tr '\n' ' ')
  TOTAL=$(echo "$PODS" | awk 'NF' | wc -l)
  if [ -z "$NOTREADY" ]; then note "pods/$ns" "$TOTAL pods ready: $(kubectl -n "$ns" get deploy,sts -o name 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')"
  else bad "pods/$ns" "not ready: $NOTREADY"; fi
done
for job in $(kubectl -n legacy get pods --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,OWNER:.metadata.ownerReferences[0].kind 2>/dev/null | awk '$3=="Job" && $2=="Failed" {print $1}' | head -1); do
  info "cronjob-diagnostics" "$job: $(kubectl -n legacy logs "$job" --tail=15 2>&1 | tr '\n' ' ' | cut -c1-800)"
done
for svc in shipment-webhook notification-service; do
  URL=$(gcloud run services describe "$svc" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null)
  [ -n "$URL" ] && note "cloudrun/$svc" "$URL" || bad "cloudrun/$svc" "not deployed"
done
DF=$(gcloud dataflow jobs list --project "$PROJECT_ID" --region "$REGION" --status=active --format='value(name,state)' 2>/dev/null | head -3 | tr '\n' ';')
if [ -n "$DF" ]; then note "dataflow" "active: $DF"; else
  bad "dataflow" "no active Dataflow job"
  ALLJOBS=$(gcloud dataflow jobs list --project "$PROJECT_ID" --region "$REGION" --format='value(id,name,state)' --limit 5 2>&1 | tr '\n' ';')
  info "dataflow-diagnostics" "jobs: ${ALLJOBS:0:600}"
  JID=$(gcloud dataflow jobs list --project "$PROJECT_ID" --region "$REGION" --format='value(id)' --limit 1 2>/dev/null)
  if [ -n "$JID" ]; then
    ERRS=$(gcloud logging read "resource.type=\"dataflow_step\" AND resource.labels.job_id=\"$JID\" AND severity>=ERROR" --project "$PROJECT_ID" --limit 6 --freshness=3h --format='value(jsonPayload.message,textPayload)' 2>&1 | tr '\n' ' ' | cut -c1-2500)
    info "dataflow-errors" "${ERRS:-none in Cloud Logging}"
    LAUNCH=$(gcloud logging read "resource.type=\"dataflow_step\" AND resource.labels.job_id=\"$JID\" AND (jsonPayload.message:\"Exception\" OR textPayload:\"Exception\")" --project "$PROJECT_ID" --limit 3 --freshness=3h --format='value(jsonPayload.message,textPayload)' 2>&1 | tr '\n' ' ' | cut -c1-2500)
    info "dataflow-exceptions" "${LAUNCH:-none}"
  fi
fi

# ---------- 1. migration phase: run both bridges ----------
gcloud pubsub topics publish migration-control --project "$PROJECT_ID" --message='{"phase":"DUAL_RUN"}' --attribute=phase=DUAL_RUN >/dev/null \
  && info "migration-phase" "published DUAL_RUN on migration-control (both bridges active)"
sleep 20

# ---------- 2. REST order -> outbox -> Pub/Sub -> inventory -> status ----------
API_IP=""
for i in $(seq 1 30); do
  API_IP=$(kubectl -n otd get svc order-intake-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$API_IP" ] && break; sleep 10
done
if [ -z "$API_IP" ]; then bad "order-intake-api" "no external IP on service otd/order-intake-api"; exit 1; fi
API="http://$API_IP"
note "order-intake-api" "external endpoint $API (Swagger: $API/swagger-ui.html)"

RESP=$(curl -sS --max-time 20 -X POST "$API/v1/orders" -H 'Content-Type: application/json' -H 'X-Correlation-Id: smoke-gcp-1' -d '{
  "orderType":"TAILORED","channel":"STORE","storeId":"0875","customerId":"C-SMOKE","promisedDate":"2026-12-24",
  "lines":[{"sku":"MW-SUIT-NAVY-42R","quantity":1,"unitPrice":599.99,"fulfillmentType":"STORE_PICKUP"},
           {"sku":"ALT-HEM-TROUSER","quantity":1,"unitPrice":50.00,"fulfillmentType":"ALTERATION",
            "alteration":{"type":"HEM","measurementInches":31.5,"tailorShopId":"TS-EASTBAY"}}]}')
ORDER_ID=$(echo "$RESP" | json 'd.get("orderId","")' 2>/dev/null)
if [ -z "$ORDER_ID" ]; then bad "create-order" "unexpected response: ${RESP:0:300}"; exit 1; fi
note "create-order" "POST /v1/orders -> $ORDER_ID"

STATUS=""
for i in $(seq 1 45); do
  STATUS=$(curl -sS --max-time 10 "$API/v1/orders/$ORDER_ID" | json 'd.get("status","")' 2>/dev/null)
  [ "$STATUS" = "RESERVED" ] || [ "$STATUS" = "BACKORDERED" ] && break; sleep 4
done
case "$STATUS" in
  RESERVED|BACKORDERED) note "inventory-roundtrip" "$ORDER_ID -> $STATUS (outbox -> orders-v1 -> inventory-service -> inventory-v1 -> order status)";;
  *) bad "inventory-roundtrip" "$ORDER_ID status stayed '$STATUS'";;
esac

# ---------- 3. carrier webhook (Cloud Run) -> shipments-v1 -> push -> notification-service ----------
WEBHOOK_URL=$(gcloud run services describe shipment-webhook --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null)
SECRET=$(gcloud secrets versions access latest --secret=webhook-shared-secret --project "$PROJECT_ID" 2>/dev/null)
BODY=$(printf '{"trackingNumber":"1Z999AA10123456784","localActivityDate":"20261004","localActivityTime":"081500","gmtOffset":"-07:00","activityStatus":{"type":"I","code":"OT","description":"Out For Delivery Today"},"activityLocation":{"city":"Dublin","stateProvince":"CA","countryCode":"US"},"referenceNumbers":[{"code":"PO","value":"%s"}]}' "$ORDER_ID")
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$WEBHOOK_URL/v1/carriers/UPS/events" -H 'Content-Type: application/json' -H "X-Carrier-Signature: sha256=$SIG" --data "$BODY")
[ "$CODE" = "202" ] && note "carrier-webhook" "signed UPS event accepted (202) by Cloud Run shipment-webhook" || bad "carrier-webhook" "HTTP $CODE"
BADCODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$WEBHOOK_URL/v1/carriers/UPS/events" -H 'Content-Type: application/json' -H "X-Carrier-Signature: sha256=deadbeef" --data "$BODY")
[ "$BADCODE" = "401" ] || [ "$BADCODE" = "403" ] && note "webhook-hmac" "bad signature rejected ($BADCODE)" || bad "webhook-hmac" "bad signature returned $BADCODE"

# ---------- 4. migration: forward (EMS -> Pub/Sub) ----------
kubectl -n legacy port-forward svc/ems-broker 18086:8086 >/dev/null 2>&1 & PF1=$!
kubectl -n legacy port-forward svc/erp-mq-consumer 18087:8087 >/dev/null 2>&1 & PF2=$!
sleep 6
SIM=$(curl -sS --max-time 20 -X POST "http://localhost:18086/simulate/orders?count=2" 2>&1)
info "ems-simulator" "TIBCO EMS stand-in published legacy XML orders: ${SIM:0:200}"

# ---------- 5. migration: reverse (Pub/Sub -> IBM MQ -> ERP) ----------
ERP=""
for i in $(seq 1 30); do
  ERP=$(curl -sS --max-time 5 "http://localhost:18087/received/$ORDER_ID" 2>/dev/null)
  echo "$ERP" | grep -q "$ORDER_ID" && break; sleep 5
done
echo "$ERP" | grep -q "$ORDER_ID" && note "erp-via-ibm-mq" "$ORDER_ID reached the ERP over IBM MQ ERP.ORDERS.IN (pubsub-to-jms-bridge)" \
  || bad "erp-via-ibm-mq" "ERP did not receive $ORDER_ID: ${ERP:0:200}"
kill $PF1 $PF2 2>/dev/null

# ---------- 6. BigQuery: zero-code archive + Dataflow ----------
sleep 30
RAW=$(bqq "SELECT COUNT(*) FROM \`$PROJECT_ID.otd.orders_raw\` WHERE JSON_VALUE(data, '\$.order.orderId') = '$ORDER_ID'")
[ "${RAW:-0}" -ge 1 ] 2>/dev/null && note "bq-subscription" "$ORDER_ID archived in otd.orders_raw by the Pub/Sub BigQuery subscription" || bad "bq-subscription" "orders_raw rows for $ORDER_ID: ${RAW:0:200}"
BRIDGED=$(bqq "SELECT COUNT(*) FROM \`$PROJECT_ID.otd.orders_raw\` WHERE JSON_VALUE(attributes, '\$.source') = 'TIBCO_EMS_BRIDGE' AND publish_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 MINUTE)")
[ "${BRIDGED:-0}" -ge 1 ] 2>/dev/null && note "ems-to-pubsub" "$BRIDGED legacy EMS order(s) bridged onto orders-v1 in the last 30 min" || bad "ems-to-pubsub" "no TIBCO_EMS_BRIDGE messages in orders_raw: ${BRIDGED:0:200}"

FOUND=""
for i in $(seq 1 12); do
  FOUND=$(bqq "SELECT CONCAT(event_type,' store=',store_id,' ',IFNULL(store_name,''),' total=',CAST(total_amount AS STRING),' lines=',CAST(line_count AS STRING)) FROM \`$PROJECT_ID.otd.order_events\` WHERE order_id = '$ORDER_ID' LIMIT 1")
  echo "$FOUND" | grep -q "ORDER_CREATED" && break; sleep 15
done
echo "$FOUND" | grep -q "ORDER_CREATED" && note "dataflow-to-bigquery" "otd.order_events: $FOUND" || bad "dataflow-to-bigquery" "no order_events row for $ORDER_ID yet: ${FOUND:0:300}"

# ---------- 7. notification-service (push with OIDC) ----------
LOGS=$(gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"notification-service\" AND (textPayload:\"$ORDER_ID\" OR jsonPayload.message:\"$ORDER_ID\")" \
  --project "$PROJECT_ID" --limit 3 --freshness=30m --format='value(textPayload,jsonPayload.message)' 2>/dev/null | head -1)
[ -n "$LOGS" ] && note "push-to-cloud-run" "notification-service: ${LOGS:0:300}" || bad "push-to-cloud-run" "no notification log for $ORDER_ID (push subscription / OIDC / invoker)"

# ---------- 7b. diagnostics for the forward bridge ----------
if [ "${BRIDGED:-0}" = "0" ] || ! [ "${BRIDGED:-0}" -ge 1 ] 2>/dev/null; then
  info "jms-bridge-logs" "$(kubectl -n otd logs deploy/jms-to-pubsub-bridge --tail=25 2>&1 | grep -iE 'error|warn|exception|phase|bridged|publish|connect' | tail -8 | tr '\n' ' ' | cut -c1-2500)"
  DLQR=$(gcloud pubsub subscriptions pull events-dlq-monitor --project "$PROJECT_ID" --limit 5 --format='value(message.attributes.dlqReason,message.attributes.dlqStage,message.attributes.originalTopic)' 2>&1 | tr '\n' ';' | cut -c1-1500)
  info "dlq-sample" "${DLQR:-empty}"
fi

# ---------- 7c. compute quota picture ----------
info "compute-vms" "$(gcloud compute instances list --project "$PROJECT_ID" --format='value(name,zone.basename(),machineType.basename(),status)' 2>&1 | tr '\n' ';' | cut -c1-1500)"
info "cpu-quota" "$(gcloud compute project-info describe --project "$PROJECT_ID" --format=json 2>/dev/null | python3 -c "import sys,json; q=[x for x in json.load(sys.stdin).get('quotas',[]) if x['metric']=='CPUS_ALL_REGIONS']; print(q)" 2>&1 | cut -c1-300)"

# ---------- 8. Pub/Sub health ----------
DLQ=$(gcloud pubsub subscriptions pull events-dlq-monitor --project "$PROJECT_ID" --limit 10 --format='value(message.attributes.dlqReason)' 2>/dev/null | wc -l)
info "dead-letter" "$DLQ message(s) visible in events-dlq-monitor"

if [ "$FAILS" -eq 0 ]; then note "smoke" "ALL CHECKS PASSED for $ORDER_ID"; else bad "smoke" "$FAILS check(s) failed"; exit 1; fi
