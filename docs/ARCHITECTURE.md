# Tailored Brands — Order-to-Delivery (OTD) Integration Platform

> Reference implementation of an enterprise integration platform on Google Cloud for a
> specialty-retail Order-to-Delivery flow (store POS, e-commerce, OMS, tailoring, warehouse,
> carriers), including the live migration of the legacy TIBCO EMS / IBM MQ messaging
> backbone to Cloud Pub/Sub. Built as a learning and interview-prep project; every component
> maps to a requirement in the Tailored Brands *Sr Integration Engineer* posting.

## 1. Business context

Tailored Brands (Men's Wearhouse, Jos. A. Bank, Moores, K&G) sells suits, tuxedo rentals,
custom clothing and alterations through ~1,200 stores and e-commerce. An order can be:

| Order type | Example | Integration quirks |
|---|---|---|
| `RETAIL` | Suit bought in store, taken home | Simple POS → OMS → ERP |
| `TAILORED` | Suit bought in store, alterations done in store or regional shop | Alteration work order; pickup date; store transfer |
| `CUSTOM` | Made-to-measure suit, manufactured by vendor | Long lead time, vendor EDI/SOAP |
| `RENTAL` | Tux rental for a wedding party | Event date, group linkage, return logistics |
| `ECOM` | Online order, ship-to-home or ship-to-store | Carrier webhooks, BOPIS |

The **legacy** landscape (what the migration starts from):

```
Store POS ──XML──▶ TIBCO BusinessWorks ──▶ TIBCO EMS (TB.ORDERS.*)  ──▶ OMS (Oracle, SOAP)
                                            │                           │
                                            └──▶ IBM MQ (ERP.ORDERS.IN) ─┴─▶ ERP / Finance
```

The **target** landscape (what this platform builds):

```
                     ┌──────────────── Apigee (API key, quota, spike arrest, OAS validation) ────┐
 Store POS / Ecom ───┤ REST  /v1/orders  ──▶  order-intake-api  (GKE Autopilot)                 │
 Legacy stores  ─────┤ SOAP  /ws/orders  ──▶    │  XSLT: XML ▶ canonical JSON                    │
                     └───────────────────────── │  Cloud SQL (orders + transactional outbox)      ┘
                                                ▼  outbox relay
                                   Pub/Sub topic  orders-v1  (proto schema, ordering key = storeId)
                     ┌──────────────────────┬───────────────────┬──────────────────────────────┐
                     ▼                      ▼                   ▼                              ▼
             inventory-service     Dataflow streaming     pubsub-to-jms-bridge        BigQuery subscription
             (GKE, exactly-once,   order-events-streaming  (migration: keeps IBM MQ    (raw archive, no code)
              Cloud SQL)           ──▶ BigQuery otd.*       / ERP fed until cutover)
                     │             ──▶ DLQ events-dlq
                     ▼
            Pub/Sub inventory-v1 ──▶ Dataflow (same job)
                                                      Carrier (UPS/FedEx) ──▶ shipment-webhook (Cloud Run)
                                                                                     │
                                                                          Pub/Sub shipments-v1
                                                                                     │ push (OIDC)
                                                                          notification-service (Cloud Run, Python)

 Legacy side during migration:
   TIBCO EMS  TB.ORDERS.OUT ──▶ jms-to-pubsub-bridge ──▶ orders-v1   (phase 1-2)
   IBM MQ     ERP.ORDERS.IN ◀── pubsub-to-jms-bridge ◀── orders-v1   (phase 2)
   reconciler: counts + ids on both sides ──▶ BigQuery otd.migration_reconciliation

 Batch:
   Cloud Scheduler / Composer ──▶ Dataflow Flex Template daily-reconciliation
     (legacy OMS XML extract in GCS  ⨝  BigQuery otd.order_events) ──▶ otd.order_reconciliation
```

## 2. Repositories

| Repo | Purpose | Stack | Runs on |
|---|---|---|---|
| `tb-platform-infra` | Terraform (Pub/Sub, schemas, GKE Autopilot, Cloud Run, Cloud SQL, BigQuery, Artifact Registry, Secret Manager, Scheduler, monitoring), Cloud Build, Apigee proxy bundle, Application Integration sample, Cloud Shell bootstrap, local docker-compose, this doc, study guide | Terraform 1.9, bash, YAML | GitHub Actions → GCP |
| `tb-integration-services` | `order-intake-api`, `inventory-service`, `shipment-webhook` (Java 21 / Spring Boot 3.5), `notification-service` (Python 3.12 / FastAPI) | Maven multi-module, Jib, Flyway, JUnit 5, Testcontainers | GKE + Cloud Run |
| `tb-order-events-dataflow` | `OrderEventsStreamingPipeline`, `DailyReconciliationPipeline` | Java 21, Apache Beam 2.66, Maven, Flex Templates | Dataflow |
| `tb-tibco-to-pubsub-migration` | `jms-to-pubsub-bridge`, `pubsub-to-jms-bridge`, `reconciler`, migration runbook & concept mapping | Java 21, Spring Boot, JMS (Artemis = EMS stand-in, IBM MQ client) | GKE |
| `tb-legacy-simulators` | `legacy-oms-soap` (Spring WS + XSD + H2 in Oracle mode), `ems-broker` (embedded Artemis publishing XML orders like TIBCO BW would), `erp-mq-consumer` (IBM MQ consumer) | Java 21, Spring Boot | GKE (`legacy` namespace) / docker-compose |
| `tb-orchestration` | Composer/Airflow DAGs, Cloud Scheduler job specs, Postman + Newman, JMeter, SoapUI, store-POS load generator | Python, Airflow 2.x, JMX/XML | Composer / CI |

Every repo: `README.md`, `.github/workflows/ci.yml` (build + unit + integration tests + image push to GHCR),
`deploy/` manifests, and a `docs/` folder. Images are published to **GHCR** (for local compose and CI
e2e) and to **Artifact Registry** (for GKE/Cloud Run), both from Actions.

## 3. Canonical event contract

All events on Pub/Sub share one envelope. Encoding is **JSON** validated by a **Pub/Sub protobuf
schema** attached to each topic (`infra/terraform/modules/pubsub/schemas/*.proto`). Field names in
JSON are lowerCamelCase (proto JSON mapping). Timestamps are RFC-3339 strings (Pub/Sub schemas cannot
import `google.protobuf.Timestamp`).

### 3.1 Envelope (`OrderEvent`, topic `orders-v1`)

```json
{
  "eventId": "6f1c0c8e-6f2a-4d8c-9a8e-4b6b0e2a9c11",
  "eventType": "ORDER_CREATED",
  "eventTime": "2026-10-03T22:14:05.120Z",
  "schemaVersion": "1",
  "source": "ORDER_INTAKE_API",
  "correlationId": "store-0412-txn-889213",
  "legacyMessageId": null,
  "order": {
    "orderId": "ORD-2026-000123",
    "orderType": "TAILORED",
    "channel": "STORE",
    "storeId": "0412",
    "customerId": "C-77812",
    "orderedAt": "2026-10-03T22:14:00Z",
    "promisedDate": "2026-10-10",
    "currency": "USD",
    "totalAmount": 649.99,
    "lines": [
      { "lineNumber": 1, "sku": "MW-SUIT-NAVY-42R", "quantity": 1, "unitPrice": 599.99,
        "fulfillmentType": "STORE_PICKUP" },
      { "lineNumber": 2, "sku": "ALT-HEM-TROUSER", "quantity": 1, "unitPrice": 50.00,
        "fulfillmentType": "ALTERATION", "alteration": { "type": "HEM", "measurementInches": 31.5,
        "tailorShopId": "TS-EASTBAY" } }
    ],
    "rental": null,
    "shipTo": null
  }
}
```

`eventType` ∈ `ORDER_CREATED | ORDER_UPDATED | ORDER_CANCELLED`.
`source` ∈ `ORDER_INTAKE_API | LEGACY_SOAP_ADAPTER | TIBCO_EMS_BRIDGE | REPLAY`.
`legacyMessageId` is the JMS `JMSMessageID` when the event was bridged from EMS/MQ (used for dedup).

**Pub/Sub attributes** (set by every publisher): `eventType`, `schemaVersion`, `source`,
`storeId`, `correlationId`, and `legacyMessageId` when present. **Ordering key** = `storeId`.

### 3.2 `InventoryEvent` (topic `inventory-v1`)

```json
{ "eventId": "...", "eventType": "INVENTORY_RESERVED", "eventTime": "...", "schemaVersion": "1",
  "source": "INVENTORY_SERVICE", "correlationId": "...",
  "orderId": "ORD-2026-000123", "storeId": "0412",
  "lines": [ { "lineNumber": 1, "sku": "MW-SUIT-NAVY-42R", "quantity": 1,
               "status": "RESERVED", "locationId": "0412" } ] }
```
`eventType` ∈ `INVENTORY_RESERVED | INVENTORY_BACKORDERED | INVENTORY_RELEASED`.
Line `status` ∈ `RESERVED | BACKORDERED | RELEASED`.

### 3.3 `ShipmentEvent` (topic `shipments-v1`)

```json
{ "eventId": "...", "eventType": "SHIPMENT_UPDATED", "eventTime": "...", "schemaVersion": "1",
  "source": "SHIPMENT_WEBHOOK", "correlationId": "...",
  "orderId": "ORD-2026-000123", "trackingNumber": "1Z999AA10123456784", "carrier": "UPS",
  "status": "IN_TRANSIT", "statusTime": "...", "location": "Oakland, CA" }
```
`status` ∈ `LABEL_CREATED | IN_TRANSIT | OUT_FOR_DELIVERY | DELIVERED | EXCEPTION`.

### 3.4 Dead letters (`events-dlq`)

Pipeline-level DLQ messages carry the original payload as `data` and attributes
`dlqReason`, `dlqStage`, `originalTopic`, plus the original attributes. Subscription-level
dead-letter policies (5 attempts) forward to the same topic.

## 4. Pub/Sub topology (Terraform `modules/pubsub`)

| Topic | Schema | Subscriptions | Notes |
|---|---|---|---|
| `orders-v1` | `OrderEvent` proto, JSON | `orders-inventory-service` (exactly-once, ordering, DLQ→events-dlq, ack 60s), `orders-dataflow` (ordering), `orders-to-legacy-mq` (migration bridge, filter `attributes.source != "TIBCO_EMS_BRIDGE"` to avoid loops), `orders-bq-archive` (BigQuery subscription → `otd.orders_raw`) | retention 7d |
| `inventory-v1` | `InventoryEvent` | `inventory-dataflow`, `inventory-order-intake` (updates order status) | |
| `shipments-v1` | `ShipmentEvent` | `shipments-dataflow`, `shipments-notification` (push, OIDC → Cloud Run) | |
| `events-dlq` | none | `events-dlq-monitor` (pull; alert on backlog) | retention 7d |
| `migration-control` | none | `migration-control-bridges` | phase changes broadcast to bridges |

Local/CI: the same names are created in the Pub/Sub emulator by `local/pubsub-init.sh` (no schemas).

## 5. Data stores

### 5.1 Cloud SQL (PostgreSQL 15), database `otd` — Flyway migrations in `tb-integration-services/order-intake-api/src/main/resources/db/migration`

```sql
orders(order_id pk, order_type, channel, store_id, customer_id, ordered_at, promised_date,
       currency, total_amount numeric(12,2), status, correlation_id, created_at, updated_at)
order_lines(order_id fk, line_number, sku, quantity, unit_price, fulfillment_type,
            alteration_json jsonb, pk(order_id,line_number))
outbox(id bigserial pk, aggregate_id, topic, ordering_key, payload jsonb, attributes jsonb,
       created_at, published_at null)            -- transactional outbox
inbox(message_id pk, consumer, processed_at)     -- idempotent consumer / inbox
inventory(sku, location_id, on_hand int, reserved int, pk(sku,location_id))
inventory_reservations(order_id, line_number, sku, location_id, quantity, status, created_at)
```

`inventory-service` and `order-intake-api` share the database in this demo (separate schemas
`orders` / `inventory` would be the production split; noted in the study guide).

### 5.2 BigQuery dataset `otd` (Terraform `modules/bigquery`)

| Table | Written by | Partition / cluster |
|---|---|---|
| `orders_raw` | Pub/Sub BigQuery subscription (`write_metadata`, `data` as JSON) | ingestion time |
| `order_events` | Dataflow streaming (flattened envelope + order header, lines as REPEATED RECORD) | `event_time` day / `store_id` |
| `order_lines` | Dataflow streaming | `event_time` day / `sku` |
| `inventory_events` | Dataflow streaming | `event_time` day |
| `shipment_events` | Dataflow streaming | `event_time` day |
| `store_order_metrics` | Dataflow streaming, 1-min fixed windows: orders, revenue, alteration count per store | `window_start` day |
| `dead_letter` | Dataflow streaming | ingestion |
| `order_reconciliation` | Dataflow batch daily | `run_date` |
| `migration_reconciliation` | migration reconciler | `run_time` day |
| `legacy_oms_orders` | Dataflow batch (parsed from OMS XML extract) | `extract_date` |

## 6. Services — ports, env vars, endpoints

| Service | Port | Key env | Endpoints |
|---|---|---|---|
| `order-intake-api` | 8080 | `DB_URL DB_USER DB_PASSWORD CLOUD_SQL_INSTANCE(optional) PUBSUB_PROJECT ORDERS_TOPIC=orders-v1 PUBSUB_EMULATOR_HOST(local) MIGRATION_PHASE LEGACY_JMS_URL(optional) LEGACY_OMS_SOAP_URL` | `POST /v1/orders`, `GET /v1/orders/{id}`, `POST /ws/orders` (SOAP `SubmitOrderRequest`), `GET /actuator/health`, `GET /v3/api-docs` |
| `inventory-service` | 8081 | `DB_* PUBSUB_PROJECT ORDERS_SUBSCRIPTION=orders-inventory-service INVENTORY_TOPIC=inventory-v1` | `GET /v1/inventory/{sku}`, `GET /actuator/health` |
| `shipment-webhook` | 8080 | `PUBSUB_PROJECT SHIPMENTS_TOPIC=shipments-v1 WEBHOOK_SHARED_SECRET` | `POST /v1/carriers/{carrier}/events` (HMAC header `X-Carrier-Signature`) |
| `notification-service` (Python) | 8080 | `PUSH_AUDIENCE` (OIDC), `NOTIFY_MODE=log` | `POST /push/shipments` (Pub/Sub push envelope), `GET /healthz` |
| `jms-to-pubsub-bridge` | 8090 | `JMS_PROVIDER=artemis|ems|ibmmq JMS_URL JMS_USER JMS_PASSWORD JMS_SOURCE=TB.ORDERS.OUT PUBSUB_PROJECT TARGET_TOPIC=orders-v1 MIGRATION_PHASE` | `/actuator/health`, `/actuator/prometheus` |
| `pubsub-to-jms-bridge` | 8091 | `JMS_PROVIDER JMS_URL JMS_DESTINATION=ERP.ORDERS.IN SOURCE_SUBSCRIPTION=orders-to-legacy-mq` | same |
| `legacy-oms-soap` | 8085 | — | `POST /ws` (WSDL at `/ws/oms.wsdl`), ops `SubmitOrder`, `GetOrderStatus`, `ExportOrders` |
| `ems-broker` | 61616 (JMS), 8161 (console) , 8086 (api) | `PUBLISH_RATE_PER_MIN` | embedded Artemis; publishes legacy XML orders to `TB.ORDERS.OUT`; `POST /simulate/orders?count=n` |
| `erp-mq-consumer` | 8087 | `MQ_HOST MQ_PORT MQ_QMGR=QM1 MQ_CHANNEL=DEV.APP.SVRCONN MQ_QUEUE=ERP.ORDERS.IN` | `GET /received` (last 100 messages) |

## 7. Migration: TIBCO EMS / IBM MQ → Pub/Sub

Phases are driven by `MIGRATION_PHASE` (env or `migration-control` topic) and documented in
`tb-tibco-to-pubsub-migration/docs/RUNBOOK.md`:

| Phase | Producers | Bridges | Consumers | Exit criteria |
|---|---|---|---|---|
| 0 `LEGACY_ONLY` | POS → BW → EMS | none | OMS, ERP via MQ | baseline counts captured |
| 1 `SHADOW` | same | EMS→Pub/Sub bridge on | new consumers run in shadow (no side effects), Dataflow fills BigQuery | 7 days, reconciler diff = 0 |
| 2 `DUAL_RUN` | new API dual-writes (Pub/Sub primary + EMS), legacy stores still via EMS→bridge | both directions on (Pub/Sub→MQ keeps ERP fed) | new consumers authoritative, legacy consumers read-only | reconciler diff = 0, latency SLO met |
| 3 `PUBSUB_PRIMARY` | all producers on Pub/Sub | Pub/Sub→MQ only (ERP not yet migrated) | new only | ERP migrated |
| 4 `CUTOVER` | Pub/Sub | none; EMS/MQ decommissioned | new only | — |

Concept mapping (EMS → Pub/Sub) lives in `docs/CONCEPT-MAPPING.md` of the migration repo.

## 8. Cross-cutting

* **Idempotency**: publishers set `eventId`; bridges set `legacyMessageId`; consumers use the
  `inbox` table; `orders-inventory-service` is an exactly-once subscription.
* **Ordering**: ordering key = `storeId`; consumers process per-key sequentially.
* **Schema evolution**: `schemaVersion` attribute; Pub/Sub schema revisions; additive-only rule.
* **Security**: Apigee API key + quota in front of GKE; Cloud Run push endpoints require OIDC from
  the Pub/Sub service account; Workload Identity everywhere; secrets in Secret Manager; carrier
  webhooks HMAC-signed.
* **Observability**: Micrometer → Cloud Monitoring, structured JSON logs with `correlationId`,
  alert policies on DLQ backlog, oldest unacked message age, Dataflow system lag.
* **Testing**: JUnit 5 + Testcontainers (Postgres, Pub/Sub emulator, Artemis, IBM MQ) in every Java
  repo; Beam `TestPipeline`/`PAssert`; Postman/Newman contract tests; JMeter load test; SoapUI for
  the SOAP adapter; docker-compose e2e in `tb-platform-infra/local`.
