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

`shipment-notification-integration.json` is an exported integration (import via the console:
*Application Integration → Integrations → Upload/Import*, or
`gcloud integrations versions upload --integration=tb-shipment-exception-to-ops --file=...` where supported):

```
Pub/Sub trigger (shipments-v1, subscription shipments-app-integration)
   └─ Data mapping: parse ShipmentEvent, pick status/orderId
        └─ condition status == EXCEPTION
             └─ REST task: GET /v1/orders/{orderId} through Apigee (x-api-key)
                  └─ REST task: POST ops webhook → ticket with order + carrier context
```

The exact export schema evolves with the product; treat the file as a reference of the shape
(triggers, `FieldMappingTask`, `GenericRestV2Task`, parameters) and re-save it from the editor
after import.

## Provisioning
1. Enable `integrations.googleapis.com` and provision the region (`gcloud integrations ... ` or console).
2. Create the subscription `shipments-app-integration` on `shipments-v1` (Terraform: add to `modules/pubsub`),
   and a service account `tb-app-integration` with `roles/pubsub.subscriber` + `roles/integrations.integrationInvoker`.
3. Import the JSON, set `apiKey` and `opsWebhookUrl`, publish.

## What to say in the interview
* "I keep the core order path in code because it needs ordering, idempotency and a database
  transaction; Application Integration is for the connector-heavy edge cases, like opening a
  ticket when a carrier reports an exception — the kind of BW process we would otherwise rewrite
  as yet another microservice."
* "It uses the same Pub/Sub topics and the same Apigee facade, so adopting it adds no new
  integration surface."
