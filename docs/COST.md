# Cost (us-central1, list prices, approximate)

| Component | Setting | ≈ per day | Notes |
|---|---|---|---|
| GKE Autopilot | cluster fee + ~8 small pods (0.25 vCPU / 0.5 GiB each) | $2.40 + $2.50 | Cluster fee $0.10/h; pods billed per requested vCPU/GiB. One free zonal/Autopilot cluster credit per billing account may cover the fee. |
| Cloud SQL Postgres | db-f1-micro, 10 GB SSD, zonal | $0.30 | Shared-core; fine for the demo |
| Dataflow streaming | 1 × n1-standard-2, Streaming Engine | $2.60 | Biggest line item while running; cancel the job when idle |
| Dataflow batch | daily, 2 workers × ~3 min | $0.05 | |
| Pub/Sub | < 1 GB/day | $0.00 | First 10 GB/month free |
| BigQuery | streaming writes + queries, < 1 GB | $0.00–0.05 | Storage Write API first 2 TiB/month free |
| Cloud Run | 2 services, scale to zero; 1 job | $0.00–0.10 | |
| Artifact Registry | ~3 GB images | $0.01 | |
| Cloud Scheduler | 1 job | $0.00 | 3 jobs free |
| Secret Manager, Logging, Monitoring | | $0.00–0.10 | within free tiers |
| **Total while fully running** | | **≈ $8–9/day** | **≈ $5/day** with the streaming job stopped |
| Optional: Cloud Composer 2 small | `enable_composer=true` | +$10–12/day | Off by default; DAGs are CI-tested instead |
| Optional: Apigee X eval | `enable_apigee=true` | $0 for 60 days | Provisioning ~1 h; proxy bundle is reviewable without it |

Teardown: `scripts/destroy.sh` or the terraform workflow with `action=destroy`. Confirm in
Billing → Reports the next day that only the tfstate bucket (cents) remains.
