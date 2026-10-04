# Interview study guide — Sr Integration Engineer, Tailored Brands (Dublin, CA)

This is the project you built, explained the way you will talk about it. Read it top to bottom once,
then rehearse §2 (the pitch) and §6 (the questions) out loud.

---

## 1. The 30-second map

"I built a reference Order-to-Delivery integration platform for a specialty retailer on GCP, including
a live migration of the TIBCO EMS / IBM MQ messaging backbone to Pub/Sub. Six repos: Spring Boot
services on GKE and Cloud Run, Apache Beam pipelines on Dataflow, Terraform for the platform, an Apigee
facade, Composer DAGs plus Cloud Scheduler, the migration bridges with a cutover runbook, and a
simulated legacy estate so the migration can be rehearsed end to end. It deploys keylessly from GitHub
Actions and there's a one-command local stack with an end-to-end test."

| Repo | One line |
|---|---|
| tb-platform-infra | Terraform + Apigee + App Integration + local stack + docs (this) |
| tb-integration-services | order-intake-api (REST + SOAP/XSLT, outbox), inventory-service (exactly-once), shipment-webhook (Cloud Run), notification-service (Python Cloud Run) |
| tb-order-events-dataflow | Beam streaming (Pub/Sub → BigQuery, windows, DLQ) + batch reconciliation (XML ⨝ BigQuery) |
| tb-tibco-to-pubsub-migration | JMS ⇄ Pub/Sub bridges, phases, reconciler, concept mapping, runbook |
| tb-legacy-simulators | EMS stand-in (embedded Artemis + BW-style publisher), IBM MQ + ERP consumer, Oracle-mode SOAP OMS, POS load generator |
| tb-orchestration | Composer DAGs, Scheduler, Postman, JMeter, SoapUI |

## 2. The two-minute pitch (rehearse)

"The business flow is an order from a store POS or the website going through inventory reservation,
tailoring, and shipment, with the ERP and analytics fed along the way. Today that runs on TIBCO
BusinessWorks and EMS with IBM MQ into the ERP.

The target I built has one canonical order event, JSON, validated at the Pub/Sub topic with a
protobuf schema. The intake API writes the order and an outbox row in one Postgres transaction and a
relay publishes with the store id as the ordering key, so publishing is exactly-once-ish without
distributed transactions. Inventory service consumes with an exactly-once subscription and an inbox
table, reserves stock, and emits an inventory event that updates the order status. A Beam streaming
job lands everything in BigQuery with the Storage Write API, computes per-store one-minute metrics with
early and late firings, and dead-letters bad payloads. Carrier webhooks hit a Cloud Run service with
HMAC verification and fan out through a push subscription to a notification service.

For the migration I wrote bridges both ways: EMS to Pub/Sub so the new consumers can run in shadow,
and Pub/Sub to MQ so the ERP keeps getting orders until it is migrated. A phase flag moves the whole
estate through legacy-only, shadow, dual-run, Pub/Sub-primary and cutover, with a reconciler writing to
BigQuery and a runbook with rollback per phase. Apigee sits in front with API key, spike arrest, quota and
OpenAPI validation. Terraform owns the infra, each repo deploys itself from GitHub Actions through
Workload Identity Federation, and a docker-compose stack runs the whole thing locally with an e2e script."

## 3. Walkthrough by posting requirement (know where everything is)

### Google Cloud Dataflow / Java + Apache Beam + Maven
`tb-order-events-dataflow`
* `OrderEventsStreamingPipeline`: 3 `PubsubIO.readMessagesWithAttributesAndMessageId()` sources →
  `ParseAndValidateFn` (multi-output `ParDo` with a DLQ `TupleTag`) → `EnrichOrderFn` (side input
  `View.asMap()` from a GCS CSV of stores) → `BigQueryIO.writeTableRows()` with
  `Method.STORAGE_WRITE_API`, `withTriggeringFrequency(10s)`, `CREATE_IF_NEEDED`, explicit `TableSchema`,
  partition on `event_time`, cluster on `store_id`.
* Metrics branch: `Window.into(FixedWindows.of(1 min))`, trigger
  `AfterWatermark.pastEndOfWindow().withEarlyFirings(AfterProcessingTime…30s).withLateFirings(AfterPane.elementCountAtLeast(1))`,
  `withAllowedLateness(5 min)`, `accumulatingFiredPanes()`, `Combine.perKey(StoreMetricsCombineFn)` →
  `store_order_metrics` with `pane_timing`/`pane_index` so a query can pick the latest pane.
* DLQ: both parse/validate failures and BigQuery insert failures (`getFailedStorageApiInserts`) go to
  `events-dlq` and `otd.dead_letter`.
* `DailyReconciliationPipeline`: `FileIO.match` → DOM parse of legacy XML → `CoGroupByKey` with the
  BigQuery side (`fromQuery … usingStandardSql`) → classifications → BigQuery + CSV (`TextIO…withoutSharding`).
* Flex Templates (`Dockerfile.flex`, `metadata/*.json`), shaded jar via `-Pdataflow`, `TestStream`/`PAssert` tests.
* Local mode `--localOutputDir` swaps BigQuery for JSONL so the DirectRunner proves the DAG in CI.

Key vocabulary: watermark, event time vs processing time, allowed lateness, panes, accumulating vs
discarding, Streaming Engine, autoscaling, fusion, hot keys, `Reshuffle`, side inputs, Storage Write
API exactly-once vs at-least-once, Flex vs classic templates, update vs drain.

### Cloud Run
* `shipment-webhook` (Java): public, HMAC-SHA256 over the raw body, carrier-specific mappers (UPS/FedEx
  shapes), publishes `ShipmentEvent`.
* `notification-service` (Python/FastAPI): private; Pub/Sub push with OIDC token (`audience` = service
  URL, verified with `google-auth`); `pubsub-push@` SA has `run.invoker`.
* `reconciler` as a Cloud Run **Job** (batch semantics, run by Composer or by hand).
* Deploy: `gcloud run deploy --set-secrets WEBHOOK_SHARED_SECRET=webhook-shared-secret:latest`.

### Cloud Scheduler / Composer
* Scheduler job (Terraform) POSTs to `dataflow.googleapis.com/v1b3/.../flexTemplates:launch` with an
  OAuth token from `tb-scheduler@` (needs `dataflow.developer` + `iam.serviceAccountUser` on the runner SA).
* Composer DAGs: `DataflowStartFlexTemplateOperator` (wait_until_finished), `BigQueryCheckOperator`
  as a data-quality gate, `CloudRunExecuteJobOperator`, `PubSubPullOperator`. Integrity tests load the
  `DagBag` with a real Airflow in CI. Composer is a flag because it costs ~$300/month idle.

### GCP Application Integration / Apigee
* Apigee bundle: `VerifyAPIKey` → `SpikeArrest` (200/s per app) → `Quota` (plan from API product) →
  `JSONThreatProtection` → `OASValidation` against the same OpenAPI the backend publishes →
  `AssignMessage` (correlation id, strip key) → `CORS`; `TargetServer` + health monitor; RFC 7807 faults.
* Application Integration: Pub/Sub trigger → data mapping → conditional REST tasks (open an ops
  ticket on shipment `EXCEPTION`); positioned as the BW-process replacement for connector-heavy flows.

### Docker / Kubernetes
* Multi-stage Dockerfiles **and** Jib (no daemon, reproducible layers); non-root, read-only-friendly.
* Kustomize base/overlays; Autopilot; Workload Identity (KSA annotation ↔ GSA `workloadIdentityUser`);
  probes on actuator liveness/readiness; HPA; PDB; NetworkPolicy isolating `legacy` from `otd` except the bridges.
* `Recreate` strategy on bridges (single JMS consumer preserves order); StatefulSet for IBM MQ.

### XML / JSON / XSLT / XPath / XSD / SOAP / REST
* `order-intake-api`: XSD → JAXB (`jaxb2-maven-plugin`), Spring WS `@Endpoint`, WSDL at `/ws/orders.wsdl`,
  XSLT 1.0 `legacy-order-to-canonical.xsl` (code tables R/T/C/X/E, P/S/A), reverse writer for dual-write.
* `legacy-oms-soap`: contract-first (XSD first, WSDL generated), SOAP faults, schema validation.
* `LegacyXmlMapper` in the migration repo: DOM/StAX, round-trip tests.
* REST: springdoc OpenAPI, Jakarta validation, `ProblemDetail`, `Location` header, 201/400/404/409.

### SQL
* Cloud SQL Postgres 15 + Flyway. Outbox: `SELECT … FOR UPDATE SKIP LOCKED` lets several relay
  replicas drain without double-publishing. Inbox table for idempotency. Reservation with a conditional
  `UPDATE … WHERE on_hand - reserved >= :qty` (no row lock contention on reads).
* H2 in **Oracle mode** for the OMS (VARCHAR2/NUMBER/sequences) — talk about dialect differences
  (sequences vs identity, `NVL` vs `COALESCE`, pagination `ROWNUM` vs `LIMIT`, `MERGE`, date handling).
* BigQuery: partition by event day, cluster by store/sku; dedup on `event_id`; latest-pane query.

### TIBCO / IBM MQ
* `docs/CONCEPT-MAPPING.md` (migration repo) — the table you must know cold (see §5).
* Bridges: `DefaultMessageListenerContainer`, CLIENT_ACKNOWLEDGE after the Pub/Sub publish future
  completes (at-least-once + dedup on `legacyMessageId`), JMS headers → attributes, ordering key from a
  JMS property, poison → DLQ then ack; reverse bridge with transacted send + loop guard
  (`source != TIBCO_EMS_BRIDGE` filter and in-code check).
* IBM MQ: `MQConnectionFactory`, `WMQ_CM_CLIENT`, channel/qmgr/host/port, dev container, MQSC queue definitions.
* EMS specifics: `tibjms.jar` not on Maven Central → reflection + optional profile.

### Testing tools
* JUnit 5 + Testcontainers (Postgres, Pub/Sub emulator, Artemis, IBM MQ), Beam `TestPipeline`,
  Postman/Newman with HMAC pre-request script, JMeter CSV-driven plan with duration assertions,
  SoapUI schema-compliance + fault assertions.

## 4. Design decisions you should defend

| Decision | Why | Trade-off |
|---|---|---|
| Transactional outbox instead of publishing in the request | DB commit and publish cannot be atomic; outbox makes the DB the source of truth | 500 ms relay latency; relay is extra moving part |
| Ordering key = storeId | Per-store FIFO like the EMS queues, parallel across stores | 1 MB/s per key limit; a stuck key blocks that store |
| JSON + proto schema (not Avro binary) | Human-readable, schema-validated, works for Python/Java/Apigee | Larger payloads than binary |
| Exactly-once subscription + inbox table | Belt and braces: Pub/Sub dedups redeliveries, inbox protects against replays/bridged duplicates | Exactly-once adds latency; inbox needs cleanup |
| BigQuery Storage Write API | Exactly-once, cheaper than streaming inserts | Needs triggering frequency tuning; schema must be explicit |
| Separate repos | Independent deploy cadence, realistic team boundaries | Cross-repo contract changes need coordination (the canonical model lives in docs + schema) |
| Bridges both ways | Shadow validation before cutover; ERP migrates last | Loop risk (solved by filter + attribute) |
| Autopilot over Standard GKE | No node management, per-pod billing | Less control over node config; some DaemonSets unsupported |
| Cloud Scheduler default, Composer optional | Cost; one launch doesn't need Airflow | Composer gives dependencies/backfills |
| Workload Identity Federation | No keys to leak | Setup friction; attribute conditions must be right |

## 5. TIBCO EMS → Pub/Sub, the mapping you must know

| EMS / BW / MQ | Pub/Sub / GCP | Gotcha |
|---|---|---|
| Queue | Topic + one subscription | Many consumers on one subscription = competing consumers, like a queue |
| Topic + durable subscriber | Topic + one subscription per consumer group | Non-durable → subscription with `expiration_policy` |
| JMS selector | Subscription filter | Attributes only, not payload; set at creation |
| Message priority | Not supported | Separate topics / separate subscriptions by urgency |
| TTL / expiration | `message_retention_duration` (topic/sub), ack deadline | Retention up to 31 days; replay with `seek` |
| Redelivery count / DLQ | `delivery_attempt` + dead-letter policy | Service agent needs publisher on DLQ + subscriber on source |
| XA / transacted sessions | Outbox + idempotent consumers; exactly-once subscriptions | No 2PC with a database |
| Request/reply (`JMSReplyTo`) | Reply topic + `correlationId`, or synchronous REST | Pub/Sub is not a request broker |
| Strict FIFO per queue | Ordering keys (FIFO per key, per region) | 1 MB/s per key; ordered subscriptions deliver per key sequentially |
| 512 MB messages | 10 MB | Claim-check pattern with GCS |
| Fault-tolerant pairs | Regional, replicated | Nothing to configure |
| Routes / bridges | Cross-project topics & subscriptions | IAM per subscription |
| `tibemsadmin`, Hawk | gcloud / Terraform / Cloud Monitoring | Metrics: `oldest_unacked_message_age`, `num_undelivered_messages` |
| BW process | Dataflow / Cloud Run / Application Integration / Workflows | Pick by throughput, state and connector needs |
| Mappers / XSLT | Typed DoFns + unit tests; App Integration data mapping | Keep XSLT where the legacy contract is XML |
| Flow control | Publisher flow-control settings, subscriber `maxOutstanding*` | |
| Browse | BigQuery subscription / snapshots | Pull is destructive to delivery attempts |

Phases: 0 LEGACY_ONLY → 1 SHADOW (EMS→Pub/Sub bridge, new consumers no side effects) → 2 DUAL_RUN
(new API dual-writes, both bridges, reconciler diff = 0) → 3 PUBSUB_PRIMARY (Pub/Sub→MQ only, ERP
last) → 4 CUTOVER. Each phase has go/no-go and rollback in the runbook.

## 6. Likely questions, with the answer in one breath

**Beam/Dataflow**
* *Difference between event time and processing time?* Event time is in the data (`eventTime`,
  Pub/Sub publish time); processing time is when the worker sees it. Windows are event time; the
  watermark estimates completeness; triggers decide when to emit; allowed lateness keeps the window open.
* *How do you handle late data?* `withAllowedLateness` + late firings + accumulating panes, write
  pane index so readers can take the latest; beyond lateness, drop and count a metric.
* *Exactly-once in Dataflow?* Dataflow dedups Pub/Sub by message id within the pipeline; sinks matter:
  Storage Write API exactly-once mode, or idempotent writes keyed by `event_id`.
* *Streaming vs batch Beam?* Same model; bounded vs unbounded PCollections; in batch the watermark
  jumps to infinity at end of input; Flex Templates package both.
* *How do you update a streaming job?* `--update` with transform name compatibility, or drain and
  relaunch; subscription retains messages during the gap.
* *Hot keys?* Store id is a decent key; for a mega-store use `withFanout` / `Combine.perKey` with hot key fanout, or `Reshuffle`.
* *Why Storage Write API over streaming inserts?* Cheaper, exactly-once, schema enforcement; streaming inserts are legacy.

**Pub/Sub**
* *Ordering?* Ordering key + ordered subscription; FIFO per key within a region; publisher must set
  `enableMessageOrdering` and resume on failure.
* *At-least-once means?* Duplicates on redelivery; consumer idempotency (inbox) or exactly-once subscription (it dedups by message id within the ack deadline window).
* *Push vs pull?* Push for Cloud Run/HTTP endpoints with OIDC, scales to zero; pull (streaming pull) for
  high throughput with flow control.
* *Schemas?* Proto/Avro attached to topic; JSON or binary encoding; revisions; validation on publish.
* *DLQ?* Dead-letter policy after N attempts; monitor backlog; replay by re-publishing.

**GKE / Cloud Run**
* *Why GKE for intake and Cloud Run for webhooks?* Intake needs a DB connection pool, steady traffic,
  and sidecar-free Cloud SQL connector with Workload Identity; webhooks are bursty, stateless, scale to
  zero. Cloud Run cold start is fine for a 202-ack webhook.
* *How do pods reach Cloud SQL?* Cloud SQL Java connector (socket factory) with the pod's Workload
  Identity; no proxy sidecar, IAM-authorized, TLS automatic.
* *Rolling vs Recreate?* Rolling for stateless APIs; Recreate for the single-consumer JMS bridge to keep order.

**Apigee**
* Spike arrest (per second, smoothing) vs quota (per plan period, counting). Keys in API products.
  OAS validation at the edge; strip credentials before the backend; correlation id for tracing.

**XML / SOAP**
* XSD → JAXB contract-first; XSLT for structural mapping, Java for lookups; XPath for assertions;
  SOAP faults vs HTTP status; WS-Security exists but we used TLS + API key; SoapUI schema compliance.

**SQL**
* `FOR UPDATE SKIP LOCKED` for queue-like tables; conditional `UPDATE` for reservations; indexes on
  `outbox(published_at, id)`; Oracle vs Postgres dialect; BigQuery partition pruning and clustering;
  dedup with `ROW_NUMBER()`.

**TIBCO migration**
* *How do you prove the migration is safe?* Shadow phase with the reconciler diffing ids, amounts and
  line counts on both sides into BigQuery; go/no-go on zero gaps for 7 days; rollback = flip the phase.
* *What breaks?* Priority, selectors on payload, XA, request/reply habits, big messages. Each has a mapped pattern.

**Operations**
* Alerts on DLQ backlog, oldest unacked age, Dataflow system lag, Cloud Run 5xx. Structured JSON logs
  with correlation id. Seek/replay. Secret rotation via Terraform taint.

## 7. Demo script (10 minutes, local or GCP)
1. `cd tb-platform-infra/local && docker compose up -d && ./e2e.sh` — read the PASS lines aloud; each is an integration path.
2. Open `http://localhost:8080/swagger-ui.html`; POST the tailored order example; GET it until `RESERVED`.
3. `curl localhost:8081/v1/inventory/MW-SUIT-NAVY-42R` — reserved count moved.
4. `curl -X POST localhost:8086/simulate/orders?count=3` — legacy XML on EMS; `curl localhost:8090/actuator/bridge` — bridged count.
5. `curl localhost:8087/received | jq '.[0]'` — ERP got the REST order as legacy XML through the reverse bridge.
6. Show `docs/CONCEPT-MAPPING.md` and `RUNBOOK.md` phase table.
7. On GCP: BigQuery `otd.order_events`, Dataflow job graph, Pub/Sub subscription metrics, Cloud Run logs.

## 8. Things you "learned the hard way" (real talking points)
* Pub/Sub emulator ignores schemas, filters and dead-letter policies — local tests pass, cloud rejects.
  Hence schema validation is a Terraform flag and the e2e has a cloud smoke test.
* The Pub/Sub service agent needs IAM for DLQ forwarding, BigQuery subscriptions and OIDC push; forgetting
  it fails silently (messages pile up).
* `tibjms.jar` is not on Maven Central: reflection + optional profile keeps the build green without the licensed jar.
* Three repos diverged on the `Rental`/`Address` sub-fields because the architecture doc left them
  `null` — the fix was the proto schema as the single contract. Contracts must be complete.
* Jackson treats record helper methods like `isRental()` as properties — rename them or annotate.
* Beam `Flatten` requires identical windowing **and** triggers; re-window before merging DLQ branches.
* Cloud Scheduler bodies are static: the batch pipeline defaults `runDate` to yesterday.
* Composer ≈ $300/month idle: flag it off, keep DAGs CI-tested.

## 9. Your résumé line for this
"Designed and built a GCP integration platform for retail Order-to-Delivery (Pub/Sub, Dataflow/Beam in
Java, GKE Autopilot, Cloud Run, Cloud SQL, BigQuery, Apigee, Composer/Scheduler), with a phase-driven
TIBCO EMS/IBM MQ → Pub/Sub migration (bidirectional JMS bridges, reconciliation, runbook), Terraform
and keyless GitHub Actions CI/CD, and contract/load tests (JUnit/Testcontainers, Postman, JMeter, SoapUI)."
