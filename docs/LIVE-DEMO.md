# Live demo — what is running in `crosscutdata-509514` and where to look

Verified end to end by `smoke-gcp` on 2026-10-05 (run 37251718467, all checks green).

## Endpoints
| What | Where |
|---|---|
| Order API (GKE, LoadBalancer) | `http://34.24.192.104/v1/orders` — Swagger UI `http://34.24.192.104/swagger-ui.html`, WSDL `http://34.24.192.104/ws/orders.wsdl` |
| Carrier webhook (Cloud Run, public, HMAC) | `https://shipment-webhook-bo4wlklhma-uc.a.run.app/v1/carriers/UPS/events` |
| Notification service (Cloud Run, private, Pub/Sub push + OIDC) | `https://notification-service-bo4wlklhma-uc.a.run.app` |
| GKE Autopilot | `tb-otd-autopilot`, **us-east1** (us-central1 had no Autopilot capacity on the day) — namespaces `otd`, `legacy` |
| Cloud SQL | `tb-otd-pg` (Postgres 15), database `otd` |
| BigQuery | dataset `otd`: `orders_raw` (BigQuery subscription), `order_events`, `order_lines`, `inventory_events`, `shipment_events`, `store_order_metrics`, `dead_letter` (Dataflow) |
| Dataflow | streaming job `order-events-streaming-*` (Flex Template), batch template `daily-reconciliation` (Cloud Scheduler 06:10 UTC) |

## 5-minute demo script (Cloud Shell)
```bash
API=http://34.24.192.104
# 1. create a tailored order
curl -s -X POST $API/v1/orders -H 'Content-Type: application/json' -d '{"orderType":"TAILORED","storeId":"0412",
  "lines":[{"sku":"MW-SUIT-NAVY-42R","quantity":1,"unitPrice":599.99,"fulfillmentType":"STORE_PICKUP"},
           {"sku":"ALT-HEM-TROUSER","quantity":1,"unitPrice":50,"fulfillmentType":"ALTERATION","alteration":{"type":"HEM","measurementInches":31.5}}]}'
# 2. watch it become RESERVED (outbox -> Pub/Sub -> inventory-service -> inventory-v1 -> status)
curl -s $API/v1/orders/ORD-2026-0000NN
# 3. Pub/Sub: Console -> Pub/Sub -> Subscriptions (orders-inventory-service = exactly-once + ordering;
#    orders-to-legacy-mq = filter; orders-bq-archive = BigQuery subscription; shipments-notification = push)
# 4. BigQuery
bq query --nouse_legacy_sql 'SELECT event_type, order_id, store_name, total_amount, line_count FROM otd.order_events ORDER BY event_time DESC LIMIT 5'
bq query --nouse_legacy_sql 'SELECT JSON_VALUE(attributes,"$.source") src, COUNT(*) FROM otd.orders_raw GROUP BY 1'
# 5. migration: legacy EMS orders bridged in, new orders bridged out to IBM MQ
gcloud container clusters get-credentials tb-otd-autopilot --region us-east1
kubectl -n legacy port-forward svc/ems-broker 8086:8086 & curl -s -X POST 'localhost:8086/simulate/orders?count=3'
kubectl -n legacy port-forward svc/erp-mq-consumer 8087:8087 & curl -s localhost:8087/received/stats
gcloud pubsub topics publish migration-control --message='{"phase":"PUBSUB_PRIMARY"}' --attribute=phase=PUBSUB_PRIMARY
# 6. Dataflow job graph: Console -> Dataflow -> order-events-streaming-* (windows, DLQ branch, BigQuery Storage Write)
```

## Bugs the live environment found (good interview stories)
| Symptom | Root cause | Fix |
|---|---|---|
| Every EMS order landed in `events-dlq` | OMS contract types `OrderDate` as `xs:date`; the bridge only parsed timestamps | Accept bare dates as start-of-day UTC + regression test. The DLQ + reconciler design caught it instead of silently losing orders. |
| Flex Template launch failed: *"The result of template creation should not be used"* | `main()` called `waitUntilFinish()` | Block only on the DirectRunner |
| Launcher: `NoClassDefFoundError: org/hamcrest/Matcher` | Beam registers `TestPipelineOptions` via ServiceLoader; Hamcrest was test-scoped | Hamcrest at runtime scope |
| Dataflow launcher VM: `QUOTA_EXCEEDED CPUS_ALL_REGIONS 12` | New-project vCPU quota | Right-size GKE (1 replica, PDBs that allow consolidation) + 1 e2-standard-2 worker |
| GKE create: *"does not have enough resources available"* | Autopilot stockout in us-central1 | `gke_location` variable → us-east1 |
| Workload Identity bindings: *"Identity Pool does not exist"* | `<project>.svc.id.goog` is created with the first WI cluster | Bindings `depends_on` the cluster |
| Pub/Sub schema: *"Too many message types"* | Pub/Sub proto schemas allow one top-level message | Nested message types |
| Push would 401 | OIDC audience included the path, service checked the base URL | Audience = Cloud Run base URL |
| SOAP adapter round-trip test: 289.00 ≠ 289.0 | `readTree()` turns decimals into doubles | Bind from JSON text to keep BigDecimal scale |

## Cost and teardown
≈ $8/day while running (GKE Autopilot pods, Cloud SQL f1-micro, 1 Dataflow streaming worker).
Stop the streaming job when not demoing: `gcloud dataflow jobs drain <id> --region us-central1`.
Tear everything down: dispatch `terraform.yml` with `action=destroy`, or `PROJECT_ID=crosscutdata-509514 scripts/destroy.sh` in Cloud Shell.
