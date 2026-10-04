# tb-platform-infra — Tailored Brands Order-to-Delivery integration platform (hub repo)

> Start here. This repo holds the architecture, the Terraform for the whole Google Cloud
> footprint, the API-gateway (Apigee) and Application Integration assets, the local
> whole-platform stack, the deployment pipeline and the interview study guide.
> The code lives in five sibling repos.

| Repo | What it is |
|---|---|
| **tb-platform-infra** (this) | Terraform (Pub/Sub + schemas, GKE Autopilot, Cloud SQL, BigQuery, Artifact Registry, Secret Manager, Cloud Scheduler, monitoring, optional Composer/Apigee), Apigee proxy bundle, Application Integration sample, Cloud Build, local docker-compose + e2e, bootstrap, docs |
| [tb-integration-services](https://github.com/sdhayanand/tb-integration-services) | Spring Boot services: `order-intake-api` (REST + SOAP/XSLT, transactional outbox), `inventory-service` (exactly-once consumer), `shipment-webhook` (Cloud Run, HMAC), `notification-service` (Python, Cloud Run push target) |
| [tb-order-events-dataflow](https://github.com/sdhayanand/tb-order-events-dataflow) | Apache Beam / Dataflow: streaming (Pub/Sub → BigQuery, windows, DLQ) + batch reconciliation (legacy XML ⨝ BigQuery), Flex Templates |
| [tb-tibco-to-pubsub-migration](https://github.com/sdhayanand/tb-tibco-to-pubsub-migration) | TIBCO EMS / IBM MQ → Pub/Sub bridges (both directions), phase-driven cutover, reconciler, concept mapping + runbook |
| [tb-legacy-simulators](https://github.com/sdhayanand/tb-legacy-simulators) | The legacy estate to migrate from: TIBCO EMS stand-in (embedded Artemis + BW-style publisher), IBM MQ + ERP consumer, Oracle-mode OMS with SOAP/XSD, store POS load generator |
| [tb-orchestration](https://github.com/sdhayanand/tb-orchestration) | Composer/Airflow DAGs, Cloud Scheduler specs, Postman/Newman, JMeter, SoapUI |

```
 Store POS / Ecom ─REST─▶ Apigee ─▶ order-intake-api (GKE) ─outbox─▶ Pub/Sub orders-v1 ─▶ inventory-service (GKE)
 Legacy stores  ─SOAP/XML (XSLT)─▶      │   Cloud SQL                       │  ├─▶ Dataflow streaming ─▶ BigQuery
 TIBCO EMS ──▶ jms-to-pubsub-bridge ────┘                                   │  ├─▶ BigQuery subscription (raw)
 IBM MQ / ERP ◀── pubsub-to-jms-bridge ◀────────────────────────────────────┘  └─▶ events-dlq
 Carriers ─webhook─▶ shipment-webhook (Cloud Run) ─▶ shipments-v1 ─push─▶ notification-service (Cloud Run)
 Cloud Scheduler / Composer ─▶ Dataflow batch reconciliation (legacy OMS extract ⨝ order_events)
```

Full design: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Interview prep: [docs/STUDY-GUIDE.md](docs/STUDY-GUIDE.md).

## How this maps to the job posting

| Posting requirement | Where it is |
|---|---|
| Google Cloud Dataflow, Java + Apache Beam + Maven | `tb-order-events-dataflow` (streaming + batch, Flex Templates, TestPipeline tests) |
| Cloud Run | `shipment-webhook`, `notification-service`, reconciler Cloud Run Job |
| Cloud Scheduler / Composer | `terraform/modules/scheduler` (Flex Template launch via REST) + `tb-orchestration/composer` DAGs (+ optional Composer env) |
| Apigee / API gateway | `apigee/` proxy bundle: API key, spike arrest, quota, JSON threat, OAS validation, correlation id |
| GCP Application Integration | `app-integration/` exported integration (Pub/Sub trigger → mapping → REST) |
| Docker & Kubernetes | Every service: Dockerfile + Jib, kustomize base/overlays, GKE Autopilot, Workload Identity, HPA/PDB/NetworkPolicy |
| XML/JSON, XSLT, XPath, XSD | `order-intake-api` SOAP adapter (XSD → JAXB, XSLT legacy→canonical), `legacy-oms-soap` contract-first XSD, migration `LegacyXmlMapper` |
| SOAP + REST | SOAP endpoints (Spring WS) and REST (springdoc OpenAPI) in both directions |
| SQL (Oracle/MySQL/Postgres/…/Cloud SQL/BigQuery) | Cloud SQL Postgres with Flyway + `FOR UPDATE SKIP LOCKED` outbox; H2 **Oracle mode** OMS; BigQuery partitioned/clustered tables |
| TIBCO suite, IBM MQ | `tb-tibco-to-pubsub-migration` + `tb-legacy-simulators`: JMS bridges, IBM MQ client + container, EMS concept mapping, cutover runbook |
| SOA / REST design | Canonical event contract, Pub/Sub proto schemas, RFC 7807 errors, idempotency, ordering keys |
| SoapUI, Postman, JMeter, JUnit | `tb-orchestration/{soapui,postman,jmeter}`, JUnit 5 + Testcontainers everywhere |
| Git / Agile | Six repos, CI on every push, PR plan / main apply, conventional structure |

## Run it

**Locally (whole platform, 12 containers, no GCP):**
```bash
cd local && docker compose up -d && ./e2e.sh          # WITH_DATAFLOW=1 adds the Beam DirectRunner leg
```
`e2e.sh` creates an order over REST, watches it become `RESERVED` through Pub/Sub, confirms the ERP
received it over JMS via the reverse bridge, pushes legacy XML through the EMS stand-in and the
forward bridge, submits a SOAP order, signs a UPS webhook and checks the notification, and drops a
poison message to see it dead-lettered.

**On Google Cloud (keyless CI/CD from GitHub Actions):**
1. `bootstrap/bootstrap.sh` in Cloud Shell (APIs, state bucket, deployer SA, Workload Identity Federation).
2. `bootstrap/github-config.sh` (repo variables/secrets on all six repos).
3. Push to `main` here → `terraform` workflow applies the platform (≈10 min, GKE + Cloud SQL dominate).
4. Run `deploy-gcp` in `tb-legacy-simulators`, `tb-integration-services`, `tb-tibco-to-pubsub-migration`, `tb-order-events-dataflow` (or `deploy-all` here).
5. `scripts/smoke-gcp.sh` — creates an order and follows it into BigQuery, Cloud Run and the ERP queue.
6. `scripts/destroy.sh` (or the `terraform` workflow with `action=destroy`) when done. See [docs/COST.md](docs/COST.md).

Details: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Layout
```
bootstrap/        one-time GCP + GitHub setup (WIF, no keys)
terraform/        root module + modules/{pubsub,bigquery,gke,cloudsql,iam,storage,registry,scheduler,monitoring,composer,apigee}
k8s/namespaces/   otd + legacy namespaces, network policies
apigee/           apiproxy bundle + OpenAPI 3 contract
app-integration/  Application Integration export + how it complements Dataflow/Cloud Run
cloudbuild/       Cloud Build alternative pipeline
local/            docker-compose for the whole platform + e2e.sh
scripts/          deploy-apigee.sh, smoke-gcp.sh, destroy.sh
docs/             ARCHITECTURE, DEPLOYMENT, COST, STUDY-GUIDE, RUNBOOK-OPERATIONS
.github/          terraform.yml (plan/apply/destroy), local-e2e.yml, deploy-all.yml
```

## What to say in the interview
1. "One canonical event contract, enforced at the topic with Pub/Sub schemas, is what let five teams' worth of code integrate without a meeting."
2. "The outbox table is the answer to 'how do you publish exactly once from a database transaction' — and the inbox table plus exactly-once subscriptions are the consumer side."
3. "Ordering key = store id gives per-store FIFO, which is what the legacy EMS queues gave us, without a global bottleneck."
4. "Apigee holds policy, the services hold logic; the OpenAPI document is the contract shared by the gateway, the backend and the tests."
5. "Everything deploys keylessly from GitHub Actions via Workload Identity Federation; Terraform owns infra, each service repo owns its rollout."
6. "The migration is phase-driven and reversible at every step: bridges both ways, a reconciler with a BigQuery audit table, and a runbook with rollback per phase."
7. "Cost is a feature flag: Composer and Apigee are off by default because Scheduler and the proxy bundle demonstrate the same skills for a fraction of the price."
