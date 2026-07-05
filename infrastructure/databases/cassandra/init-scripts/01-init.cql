-- Cassandra 4 init: bankobs_payments keyspace + tables for upi-service.
-- RF=1 locally (single-node) — see DECISIONS.md for EKS RF=3 split.

CREATE KEYSPACE IF NOT EXISTS bankobs_payments
WITH replication = {'class':'SimpleStrategy','replication_factor':1};

USE bankobs_payments;

CREATE TABLE IF NOT EXISTS upi_transactions (
  transaction_id uuid,
  vpa            text,
  amount         double,
  status         text,
  created_at     timestamp,
  PRIMARY KEY (vpa, created_at)
) WITH CLUSTERING ORDER BY (created_at DESC);

CREATE TABLE IF NOT EXISTS upi_transactions_by_id (
  transaction_id uuid PRIMARY KEY,
  vpa            text,
  payee_vpa      text,
  amount         double,
  status         text,
  remarks        text,
  created_at     timestamp,
  completed_at   timestamp,
  trace_id       text
);

CREATE TABLE IF NOT EXISTS payment_events (
  event_id    uuid,
  payment_id  text,
  event_type  text,
  payload     text,
  created_at  timestamp,
  PRIMARY KEY (payment_id, created_at)
) WITH CLUSTERING ORDER BY (created_at DESC);

CREATE TABLE IF NOT EXISTS transaction_history (
  account_id  text,
  year_month  text,
  txn_id      uuid,
  amount      decimal,
  created_at  timestamp,
  PRIMARY KEY ((account_id, year_month), created_at)
) WITH CLUSTERING ORDER BY (created_at DESC);

CREATE TABLE IF NOT EXISTS vpa_registry (
  vpa             text PRIMARY KEY,
  customer_id     text,
  linked_account  text,
  status          text,
  created_at      timestamp
);
