#!/usr/bin/env bash
# End-to-end test of tb-shipment-exception-to-ops:
#   1. create an order (through ORDER_API_BASE, i.e. Apigee when it is live)
#   2. API trigger:     :execute with an EXCEPTION ShipmentEvent -> expect opsTicket with the order
#   3. Pub/Sub trigger: signed UPS exception -> Cloud Run shipment-webhook -> shipments-v1 -> integration
set -uo pipefail
PROJECT="${PROJECT_ID:?}"; REGION="${REGION:-us-central1}"; NAME=tb-shipment-exception-to-ops
API="https://integrations.googleapis.com/v1/projects/${PROJECT}/locations/${REGION}/integrations/${NAME}"
TOKEN="$(gcloud auth print-access-token)"
FAILS=0
ok()  { echo "PASS  $1"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::notice title=app-integration::PASS $1"; return 0; }
bad() { echo "FAIL  $1"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=app-integration::FAIL ${1:0:900}"; FAILS=$((FAILS+1)); }
py()  { python3 -c "$@"; }
explain() { # print why an execution failed: per-task state + error info (without the big payloads)
  curl -sS -m 30 "${API}/executions?pageSize=20" -H "Authorization: Bearer ${TOKEN}" | python3 -c "
import sys,json
want=sys.argv[1]
for e in json.load(sys.stdin).get('executions',[]):
    if not e.get('name','').endswith(want): continue
    for snap in (e.get('executionDetails') or {}).get('executionSnapshots',[]):
        md=snap.get('executionSnapshotMetadata',{})
        print('--', snap.get('checkpointTaskNumber'), md.get('taskLabel',''), md.get('task',''))
        for t in snap.get('taskExecutionDetails',[]):
            print('   task', t.get('taskNumber'), t.get('taskExecutionState'), json.dumps(t.get('taskAttemptStats',''))[:200])
        for k,v in snap.get('params',{}).items():
            if k in ('CloudPubSubMessage','shipmentEventJson','ExecutionTraceInfo'): continue
            txt=json.dumps(v)
            if 'rror' in k or 'Task_2' in k or k in ('orderUrl','requestHeaders','isException','status','opsTicket'):
                print('   ', k, '=', txt[:700])
" "$1"
}

echo "==> 1. create an order via ${ORDER_API_BASE}"
ORDER=$(curl -sS -m 30 -X POST "$ORDER_API_BASE" -H 'Content-Type: application/json' -H "x-api-key: ${ORDER_API_KEY:-}" \
  -d '{"orderType":"TAILORED","channel":"STORE","storeId":"0412","customerId":"C-APPINT","lines":[{"sku":"MW-SUIT-NAVY-42R","quantity":1,"unitPrice":599.99,"fulfillmentType":"STORE_PICKUP"},{"sku":"ALT-HEM-TROUSER","quantity":1,"unitPrice":50.00,"fulfillmentType":"ALTERATION","alteration":{"type":"HEM","measurementInches":31.5}}]}')
ORDER_ID=$(echo "$ORDER" | py "import sys,json;print(json.load(sys.stdin).get('orderId',''))" 2>/dev/null)
[ -n "$ORDER_ID" ] && ok "order ${ORDER_ID} created" || { bad "order create: ${ORDER:0:300}"; exit 1; }
sleep 5

echo "==> 2. API trigger"
EVENT=$(printf '{"eventId":"it-%s","eventType":"SHIPMENT_UPDATED","orderId":"%s","trackingNumber":"1ZAPPINT0001","carrier":"UPS","status":"EXCEPTION","statusTime":"%s","location":"Dublin, CA","correlationId":"appint-test-%s"}' \
  "$(date +%s)" "$ORDER_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%s)")
REQ=$(py "import json,sys; print(json.dumps({'triggerId':'api_trigger/${NAME}_API_1','inputParameters':{'shipmentEventJson':{'jsonValue':sys.argv[1]}}}))" "$EVENT")
RESP=$(curl -sS -m 120 -X POST "${API}:execute" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d "$REQ")
echo "$RESP" | head -c 1500; echo
TICKET_ORDER=$(echo "$RESP" | py "
import sys,json
d=json.load(sys.stdin); t=None
op=d.get('outputParameters') or {}
v=op.get('opsTicket')
if isinstance(v,dict) and 'jsonValue' in v: v=v['jsonValue']
if isinstance(v,str): v=json.loads(v)
print((v or {}).get('order',{}).get('orderId',''))" 2>/dev/null)
if [ "$TICKET_ORDER" = "$ORDER_ID" ]; then ok "API trigger -> REST via order API -> opsTicket for ${ORDER_ID}"
else
  bad "API trigger: opsTicket missing/mismatch (got '${TICKET_ORDER}'): ${RESP:0:400}"
  EXEC_ID=$(echo "$RESP" | py "import sys,json;print(json.load(sys.stdin).get('executionId',''))" 2>/dev/null)
  [ -n "$EXEC_ID" ] && explain "$EXEC_ID"
fi

echo "==> 3. Pub/Sub trigger via the real carrier webhook"
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WEBHOOK_URL=$(gcloud run services describe shipment-webhook --region "$REGION" --project "$PROJECT" --format='value(status.url)')
SECRET=$(gcloud secrets versions access latest --secret=webhook-shared-secret --project "$PROJECT")
BODY=$(printf '{"trackingNumber":"1ZAPPINT0002","localActivityDate":"%s","localActivityTime":"%s","gmtOffset":"-07:00","activityStatus":{"type":"X","code":"DM","description":"Damaged - returning to sender"},"activityLocation":{"city":"Dublin","stateProvince":"CA","countryCode":"US"},"referenceNumbers":[{"code":"PO","value":"%s"}]}' \
  "$(date +%Y%m%d)" "$(date +%H%M%S)" "$ORDER_ID")
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -m 30 -X POST "$WEBHOOK_URL/v1/carriers/UPS/events" -H 'Content-Type: application/json' -H "X-Carrier-Signature: sha256=$SIG" --data "$BODY")
[ "$CODE" = 202 ] && ok "signed UPS exception accepted by Cloud Run (202)" || bad "webhook HTTP $CODE"

FOUND=""
for i in $(seq 1 18); do
  sleep 10
  LIST=$(curl -sS -m 30 "${API}/executions?pageSize=20" -H "Authorization: Bearer ${TOKEN}")
  FOUND=$(echo "$LIST" | py "
import sys,json
d=json.load(sys.stdin)
for e in d.get('executions',[]):
    trig=e.get('triggerId',''); st=(e.get('executionDetails') or {}).get('state','') or e.get('state','')
    if 'pubsub' in trig and e.get('createTime','') >= '${START}':
        print(st, e.get('name','').split('/')[-1]); break" 2>/dev/null)
  [ -n "$FOUND" ] && [[ "$FOUND" == SUCCEEDED* ]] && break
  echo "    waiting for a Pub/Sub-triggered execution... ${FOUND}"
done
if [[ "$FOUND" == SUCCEEDED* ]]; then ok "Pub/Sub trigger: webhook -> shipments-v1 -> integration execution ${FOUND#* } SUCCEEDED"
else
  bad "Pub/Sub trigger: no successful execution after webhook (${FOUND:-none})"
  [ -n "$FOUND" ] && explain "${FOUND#* }"
fi
exit "$FAILS"
