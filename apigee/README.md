# Apigee — API gateway facade for the Order API

`apiproxy/` is a deployable Apigee X proxy bundle (`tb-order-api-v1`) that fronts
`order-intake-api` running on GKE. It is the "API gateway technologies / Apigee" part of the
posting, and the pattern a retailer uses to expose order intake to 1,200 store POS clients and
partners without every backend re-implementing auth and throttling.

| Policy | Why it is there |
|---|---|
| `VK-VerifyApiKey` | Each store/partner app gets an API key via an API product; `client_id` identifies the caller for quota + logs |
| `SA-SpikeArrest` | Smooths bursts (200/s per app) so a POS reconnect storm after an outage cannot flood the backend |
| `Q-Quota` | Daily allowance per app read from the API product (plan-based, distributed, async) |
| `JTP-JsonThreat` | Caps depth/array/string sizes before the JSON reaches Jackson |
| `OAS-Validate` | Validates `POST` bodies against `resources/oas/order-api.yaml` (the same OpenAPI the backend publishes at `/v3/api-docs`) — fail fast at the edge |
| `AM-CorrelationId` | Propagates `X-Correlation-Id` (mints one from `messageid` if absent) so Apigee → GKE → Pub/Sub → BigQuery logs line up |
| `AM-StripApiKey` | Never forward credentials to the backend |
| `AM-Cors` | Preflight for the web channel |
| `RF-Unauthorized` | RFC 7807 `problem+json` on bad keys, same error shape as the backend |

The target uses a **TargetServer** (`order-intake-api`) + health monitor instead of a hard-coded host.

## Deploy (needs an Apigee org — `enable_apigee = true` in Terraform, ~1h to provision)

```bash
export APIGEE_ORG=$PROJECT_ID APIGEE_ENV=dev BACKEND_HOST=<order-intake-api LB IP>
scripts/deploy-apigee.sh        # uses apigeecli: target server, import bundle, deploy, API product, developer, app
curl -s https://$APIGEE_HOST/v1/orders -H "x-api-key: $KEY" -H 'content-type: application/json' -d @../../tb-orchestration/postman/samples/tailored-order.json
```

## What to say in the interview

* Apigee is the policy layer; the backend stays a plain Spring Boot service. Auth, throttling,
  threat protection and schema validation are config, not code, and can change without a deploy.
* Spike arrest vs quota: spike arrest protects the backend from bursts (per second), quota is the
  business plan (per day). You need both.
* The OpenAPI document is the contract: Apigee validates against it, springdoc publishes it,
  Postman/Newman tests are generated from it.
* Correlation id propagation is what makes distributed debugging possible across Apigee, GKE,
  Pub/Sub attributes and BigQuery rows.
