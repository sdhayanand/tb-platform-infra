# Terraform

```
terraform/
  versions.tf      providers + GCS backend (bucket injected at init)
  variables.tf     feature flags: enable_gke, enable_cloudsql, enable_scheduler, enable_composer, enable_apigee
  main.tf          wires the modules
  outputs.tf
  envs/dev.tfvars
  modules/
    registry/      Artifact Registry (docker + Maven Central remote proxy)
    storage/       dataflow / legacy-extracts / reports / reference buckets (+ store reference CSV)
    iam/           one SA per workload, roles table, Workload Identity bindings
    bigquery/      dataset otd, tables owned by non-Beam writers (orders_raw, migration_reconciliation)
    pubsub/        proto schemas, topics, subscriptions (ordering, exactly-once, DLQ, filter, BigQuery, push/OIDC)
    cloudsql/      Postgres 15 + Secret Manager (db password, webhook secret, JMS)
    gke/           Autopilot cluster
    scheduler/     Cloud Scheduler → Dataflow Flex Template launch
    monitoring/    alert policies + log metric
    composer/      optional Composer 2 environment
    apigee/        optional Apigee X eval org
```

```bash
terraform init -backend-config="bucket=crosscutdata-509514-tb-otd-tfstate"
terraform plan  -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```
