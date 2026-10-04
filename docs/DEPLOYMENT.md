# Deployment guide

## 0. Prerequisites
* A GCP project with billing (`crosscutdata-509514` in the examples) and Owner on it.
* The six `tb-*` repos under github.com/sdhayanand.
* Nothing installed locally: everything runs in Cloud Shell or GitHub Actions.

## 1. Bootstrap (once, ~3 min, Cloud Shell)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sdhayanand/tb-platform-infra/main/bootstrap/bootstrap.sh)
```
Creates: enabled APIs, `gs://<project>-tb-otd-tfstate`, `tb-deployer@` service account (Owner in this
demo), Workload Identity pool `github-pool` + provider `github-provider` restricted to
`assertion.repository_owner == 'sdhayanand'`. Prints the values for step 2.

**Why WIF and not a JSON key:** GitHub mints a short-lived OIDC token per job, Google exchanges it
for a 1-hour access token for `tb-deployer`. No secret exists to leak or rotate.

## 2. GitHub configuration
```bash
export GCP_PROJECT_ID=... GCP_WIF_PROVIDER=... GCP_DEPLOYER_SA=... TF_STATE_BUCKET=...
bash bootstrap/github-config.sh    # sets vars/secrets on all six repos
```
Every deploy job is guarded by `if: vars.GCP_PROJECT_ID != ''`, so repos without these settings
simply skip the GCP jobs and only run CI.

## 3. Platform (this repo)
Push to `main` or run **terraform** → `apply`. Order of creation is handled by module dependencies:
APIs → registry/storage/IAM → BigQuery → Pub/Sub (schemas, topics, subs, BigQuery subscription, push
to Cloud Run URL computed from project number) → Cloud SQL (+ Secret Manager) → GKE Autopilot →
Scheduler → Monitoring. The `cluster-config` job then creates namespaces and the `otd-db` /
`otd-jms` Kubernetes secrets from Secret Manager.

Typical timing: GKE Autopilot 6-8 min, Cloud SQL 5-7 min (parallel), rest < 2 min.

## 4. Workloads (sibling repos, in this order)
| # | Repo → workflow | Deploys |
|---|---|---|
| 1 | tb-legacy-simulators → deploy-gcp | namespace `legacy`: IBM MQ StatefulSet, ems-broker, legacy-oms-soap, erp-mq-consumer, POS CronJob |
| 2 | tb-integration-services → deploy-gcp | GKE `otd`: order-intake-api (LoadBalancer), inventory-service; Cloud Run: shipment-webhook (public), notification-service (private, invoked by `pubsub-push@`) |
| 3 | tb-tibco-to-pubsub-migration → deploy-gcp | GKE `otd`: both bridges; Cloud Run Job: reconciler |
| 4 | tb-order-events-dataflow → deploy-gcp | Flex Templates to `gs://<project>-tb-otd-dataflow/templates/`; optional streaming job start |

After step 2 the first time, re-run `terraform` → `cluster-config` (or
`gcloud run services add-iam-policy-binding notification-service --member=serviceAccount:pubsub-push@... --role=roles/run.invoker`)
so Pub/Sub push can invoke the private Cloud Run service.

`deploy-all.yml` fans these out in order when `CROSS_REPO_TOKEN` (PAT with `actions:write`) is set.

## 5. Verify
```bash
PROJECT_ID=crosscutdata-509514 scripts/smoke-gcp.sh
```
Then look at: Pub/Sub → Subscriptions (ack rates), BigQuery `otd.order_events` / `otd.store_order_metrics`,
Dataflow job graph, Cloud Run logs for `notification-service`, Monitoring → Alerting (4 policies).

## 6. Day-2
* **Migration phase change:** `gcloud pubsub topics publish migration-control --message='{"phase":"DUAL_RUN"}'`
  (or `kubectl -n otd set env deploy/jms-to-pubsub-bridge MIGRATION_PHASE=DUAL_RUN`). See the migration repo RUNBOOK.
* **Replay:** `gcloud pubsub subscriptions seek orders-dataflow --time=<RFC3339>` replays retained
  messages (7-day retention) into the streaming job; consumers are idempotent.
* **Schema change:** add a field to the `.proto` (never remove/renumber), `terraform apply` creates a
  schema revision; publishers can start using the field after the apply.
* **Scale:** HPA on CPU for GKE services; Dataflow autoscaling (`--max-workers`); Cloud Run max instances.

## 7. Destroy
`terraform` workflow with `action=destroy`, or `PROJECT_ID=... scripts/destroy.sh`
(cancels Dataflow jobs and deletes Cloud Run first, then `terraform destroy`).
