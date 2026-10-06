#!/usr/bin/env bash
# Smoke test THROUGH Apigee (APIGEE_SCHEME=http|https): client -> external LB -> PSC -> Apigee proxy (policies) -> order-intake-api on GKE.
#   APIGEE_HOST=<ip>.nip.io KEY_FILE=.apigee-key scripts/smoke-apigee.sh
# Prints one PASS/FAIL line per check (also as GitHub annotations when run in Actions). Never prints the key.
set -uo pipefail
HOST="${APIGEE_HOST:?set APIGEE_HOST (e.g. 34.1.2.3.nip.io)}"
KEY="$(cat "${KEY_FILE:-.apigee-key}")"
SCHEME="${APIGEE_SCHEME:-http}"
BASE="${SCHEME}://${HOST}/v1/orders"
FAILS=0
ok()   { set -- "[${SCHEME:-http}] $1"; echo "PASS  $1"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::notice title=apigee smoke::PASS $1"; return 0; }
bad()  { set -- "[${SCHEME:-http}] $1"; echo "FAIL  $1"; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=apigee smoke::FAIL $1"; FAILS=$((FAILS+1)); }
call() { # call METHOD URL [curl args] -> $CODE, body in /tmp/apigee-smoke.json, headers in /tmp/apigee-smoke.h
  CODE="$(curl -sS -m 30 -o /tmp/apigee-smoke.json -D /tmp/apigee-smoke.h -w '%{http_code}' -X "$1" "$2" "${@:3}")" || CODE=000
}
ORDER='{"orderType":"TAILORED","channel":"STORE","storeId":"0412","customerId":"C-APIGEE",
 "lines":[{"sku":"MW-SUIT-NAVY-42R","quantity":1,"unitPrice":599.99,"fulfillmentType":"STORE_PICKUP"},
          {"sku":"ALT-HEM-TROUSER","quantity":1,"unitPrice":50.00,"fulfillmentType":"ALTERATION",
           "alteration":{"type":"HEM","measurementInches":31.5}}]}'

echo "==> waiting for the load balancer + proxy to answer (a new global LB takes 5-10 min)"
for i in $(seq 1 60); do
  call GET "${BASE}/ORD-1999-000000"
  [ "$CODE" = 401 ] && break
  echo "    HTTP $CODE, retrying..."; sleep 15
done

call GET "${BASE}/ORD-1999-000000"
[ "$CODE" = 401 ] && ok "no API key -> 401 (VerifyAPIKey + RaiseFault problem+json)" || bad "no API key -> expected 401, got $CODE"

call GET "${BASE}/ORD-1999-000000" -H "x-api-key: not-a-real-key"
[ "$CODE" = 401 ] && ok "invalid API key -> 401" || bad "invalid API key -> expected 401, got $CODE"

call POST "${BASE}" -H "x-api-key: ${KEY}" -H 'Content-Type: application/json' -d '{"orderType":"RETAIL","storeId":"0412"}'
[ "$CODE" = 400 ] && ok "order without lines -> 400 (OpenAPI validation / API rules)" || bad "order without lines -> expected 400, got $CODE"

call POST "${BASE}" -H "x-api-key: ${KEY}" -H 'Content-Type: application/json' -H 'X-Correlation-Id: apigee-smoke-1' -d "$ORDER"
ORDER_ID="$(python3 -c "import json;print(json.load(open('/tmp/apigee-smoke.json')).get('orderId',''))" 2>/dev/null)"
[ "$CODE" = 201 ] && [ -n "$ORDER_ID" ] && ok "create order through Apigee -> 201 ${ORDER_ID}" || { bad "create order -> expected 201, got $CODE"; cat /tmp/apigee-smoke.json; }

if [ -n "$ORDER_ID" ]; then
  STATUS=""
  for i in $(seq 1 12); do
    call GET "${BASE}/${ORDER_ID}" -H "x-api-key: ${KEY}"
    STATUS="$(python3 -c "import json;print(json.load(open('/tmp/apigee-smoke.json')).get('status',''))" 2>/dev/null)"
    [ "$STATUS" = RESERVED ] && break; sleep 5
  done
  [ "$CODE" = 200 ] && ok "get order through Apigee -> 200 status=${STATUS} (outbox -> Pub/Sub -> inventory)" || bad "get order -> expected 200, got $CODE"
fi

[ "$FAILS" = 0 ] && echo "==> all Apigee checks passed" || echo "==> ${FAILS} Apigee check(s) failed"
exit "$FAILS"
