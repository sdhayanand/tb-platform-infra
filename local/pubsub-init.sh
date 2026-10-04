#!/bin/sh
# Creates the ARCHITECTURE §4 topology in the Pub/Sub emulator through its REST API.
# The emulator ignores schemas, filters and dead-letter policies, so only names are created.
set -eu
PUBSUB="${PUBSUB:-http://pubsub-emulator:8085}"
PROJECT="${PROJECT:-tb-otd-local}"

topic() {
  curl -fsS -X PUT "$PUBSUB/v1/projects/$PROJECT/topics/$1" -o /dev/null -w "topic $1 -> %{http_code}\n" \
    || curl -fsS "$PUBSUB/v1/projects/$PROJECT/topics/$1" -o /dev/null -w "topic $1 exists -> %{http_code}\n"
}
sub() { # name topic extra-json
  body="{\"topic\":\"projects/$PROJECT/topics/$2\",\"ackDeadlineSeconds\":60,\"enableMessageOrdering\":true$3}"
  curl -fsS -X PUT -H 'Content-Type: application/json' -d "$body" \
    "$PUBSUB/v1/projects/$PROJECT/subscriptions/$1" -o /dev/null -w "subscription $1 -> %{http_code}\n" \
    || curl -fsS "$PUBSUB/v1/projects/$PROJECT/subscriptions/$1" -o /dev/null -w "subscription $1 exists -> %{http_code}\n"
}

topic orders-v1
topic inventory-v1
topic shipments-v1
topic events-dlq
topic migration-control

sub orders-inventory-service orders-v1 ""
sub orders-dataflow orders-v1 ""
sub orders-to-legacy-mq orders-v1 ""
sub orders-bq-archive orders-v1 ""
sub inventory-dataflow inventory-v1 ""
sub inventory-order-intake inventory-v1 ""
sub shipments-dataflow shipments-v1 ""
sub shipments-notification shipments-v1 ",\"pushConfig\":{\"pushEndpoint\":\"http://notification-service:8080/push/shipments\"}"
sub events-dlq-monitor events-dlq ""
sub migration-control-bridges migration-control ""
sub migration-control-jms-to-pubsub migration-control ""
sub migration-control-pubsub-to-jms migration-control ""
echo "pubsub topology ready"
