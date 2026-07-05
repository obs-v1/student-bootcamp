#!/usr/bin/env bash
# Create the 12 Kafka topics for BankObserve360.
# Replication factor 1 locally (single broker); use 3 for EKS deployment.

set -euo pipefail
BROKER="${KAFKA_BOOTSTRAP_SERVERS:-kafka:9092}"
RF="${KAFKA_REPLICATION_FACTOR:-1}"

# Wait for broker.
until kafka-topics.sh --bootstrap-server "${BROKER}" --list >/dev/null 2>&1; do
  echo "[kafka-init] waiting for broker ${BROKER}…"
  sleep 5
done

create_topic() {
  local name="$1" partitions="$2"
  if kafka-topics.sh --bootstrap-server "${BROKER}" --list | grep -qx "${name}"; then
    echo "[kafka-init] topic ${name} exists, skipping"
    return
  fi
  kafka-topics.sh --bootstrap-server "${BROKER}" \
    --create \
    --topic "${name}" \
    --partitions "${partitions}" \
    --replication-factor "${RF}" \
    --config retention.ms=604800000 \
    --config compression.type=lz4
  echo "[kafka-init] created topic ${name} (partitions=${partitions} rf=${RF})"
}

create_topic banking.payments.upi.initiated   12
create_topic banking.payments.upi.completed   12
create_topic banking.payments.neft.batch       6
create_topic banking.payments.rtgs.initiated   6
create_topic banking.fraud.alerts              8
create_topic banking.fraud.velocity            8
create_topic banking.kyc.events                6
create_topic banking.audit.events             12
create_topic banking.notifications.dispatch    6
create_topic banking.cbs.events                8
create_topic banking.compliance.events         4
create_topic banking.loadrunner.metrics        4

echo "[kafka-init] all topics created"
