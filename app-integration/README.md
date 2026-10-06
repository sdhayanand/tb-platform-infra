# GCP Application Integration — low-code companion to the coded services

Application Integration is Google's iPaaS (triggers → tasks → data mapping → connectors). It is
the closest GCP equivalent of a **TIBCO BusinessWorks process**: a visual flow with mappers and
connectors, without writing a service. The posting lists it next to Apigee and Dataflow, and the
sensible split is:

| Need | Build it with |
|---|---|
| High-volume, ordered, exactly-once event processing with state | **Dataflow** (`tb-order-events-dataflow`) |
| Request/response APIs, custom business logic, DB transactions | **Cloud Run / GKE services** (`tb-integration-services`) |
| Long tail of "when X happens, call Y and Z" with SaaS connectors (Salesforce, ServiceNow, SAP, Jira, email) | **Application Integration** (this folder) |
| Orchestrating steps with retries/compensation | **Workflows** |

## The live integration: `tb-shipment-exception-to-ops`

```
Cloud Pub/Sub trigger (shipments-v1) ─┐
API trigger (tests / replays) ────────┴─▶ 1 JavaScript: parse ShipmentEvent (plain or base64 Pub/Sub data)
                                            └─ [status == EXCEPTION] ─▶ 2 Call REST endpoint: GET /v1/orders/{id}
                                                                          through Apigee (x-api-key)
                                                                          └─▶ 3 JavaScript: build ops ticket (output opsTicket)
```

* `build_integration.py` generates the IntegrationVersion JSON; the task scripts are in `src/*.js`
  so they are reviewed and unit-tested like code (the same JSON can be imported in the console).
* `scripts/app-integration.sh` provisions the region (`clients:provision`), creates the trigger
  service account `tb-app-integration` (Integration Invoker), gives the Application Integration
  service agent Pub/Sub Editor (it creates the trigger's subscription on publish) and actAs on that SA,
  then creates a version and publishes it.
* `scripts/test-app-integration.sh` proves both triggers: `:execute` on the API trigger, and a real
  signed UPS exception through the Cloud Run webhook → `shipments-v1` → Pub/Sub trigger.
* Workflow: `.github/workflows/app-integration.yml` (manual). It routes the REST call through Apigee
  when the proxy answers, otherwise straight to the GKE backend.
* In production the last step would be a ServiceNow/Jira connector task, and the API key would come
  from an Auth Config rather than a default value.

## What to say in the interview
* "I keep the core order path in code because it needs ordering, idempotency and a database
  transaction; Application Integration is for the connector-heavy edge cases, like opening a
  ticket when a carrier reports an exception — the kind of BW process we would otherwise rewrite
  as yet another microservice."
* "It uses the same Pub/Sub topics and the same Apigee facade, so adopting it adds no new
  integration surface."
