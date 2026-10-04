# Operations runbook (day-2 for the OTD platform)

## Alerts (terraform/modules/monitoring)
| Alert | Meaning | First actions |
|---|---|---|
| `dead-letter backlog > 0` | A consumer gave up after 5 attempts or the pipeline rejected a payload | `gcloud pubsub subscriptions pull events-dlq-monitor --limit=5 --format=json` → read `dlqReason`/`dlqStage`/`originalTopic`. Bad producer? fix + replay. Bug? fix consumer, then re-publish the DLQ messages to the original topic. |
| `orders-inventory-service oldest unacked > 5 min` | inventory-service down, DB slow, or a stuck ordering key | `kubectl -n otd get pods`, logs, Cloud SQL insights. With ordering, one failing key blocks only that key. |
| `Dataflow system lag > 2 min` | streaming job under-provisioned or stuck | Dataflow UI → step with backlog; raise `--max-workers`; check BigQuery write errors in `otd.dead_letter` |
| `notification-service 5xx` | push target failing | Cloud Run logs; Pub/Sub retries with backoff then dead-letters after 5 |

## Useful queries
```sql
-- end-to-end latency per store (publish → BigQuery)
SELECT store_id, APPROX_QUANTILES(TIMESTAMP_DIFF(ingested_at, publish_time, MILLISECOND), 100)[OFFSET(95)] p95_ms
FROM `otd.order_events` WHERE event_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) GROUP BY 1;

-- live store metrics (latest pane per window)
SELECT * EXCEPT(rn) FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY store_id, window_start ORDER BY pane_index DESC) rn
  FROM `otd.store_order_metrics` WHERE window_start >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)) WHERE rn = 1;

-- dedup check: an event id should appear once
SELECT event_id, COUNT(*) c FROM `otd.order_events` GROUP BY 1 HAVING c > 1;

-- migration health: last reconciler runs
SELECT run_time, phase, matched, only_legacy, only_pubsub, mismatched FROM `otd.migration_reconciliation` ORDER BY run_time DESC LIMIT 10;
```

## Replay
```bash
# re-deliver the last 2 hours to the streaming job (consumers dedup on event_id)
gcloud pubsub subscriptions seek orders-dataflow --time="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
# re-publish DLQ messages (after the fix) — attributes carry originalTopic
gcloud pubsub subscriptions pull events-dlq-monitor --limit=100 --auto-ack --format=json > dlq.json
```

## Rotations
* DB password: `terraform taint module.cloudsql[0].random_password.db && terraform apply`, then re-run `cluster-config` and restart the `otd` deployments.
* Webhook secret: same with `random_password.webhook_secret`; carriers get the new value out of band.

## Scaling knobs
| Where | Knob |
|---|---|
| GKE services | `replicas`, HPA `targetCPUUtilizationPercentage`, resources in `deploy/k8s/base` |
| inventory-service | `setParallelPullCount`, flow control `maxOutstandingElementCount` (ordering keeps per-key FIFO regardless) |
| Dataflow | `--max-workers`, `--worker-machine-type`, Storage Write API `withNumStorageWriteApiStreams` |
| Cloud Run | `--max-instances`, `--concurrency` |
| Pub/Sub | publisher batching/flow control; subscription `ack_deadline_seconds` |
