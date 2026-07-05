#!/usr/bin/env bash
# Elasticsearch init: ILM policy + index templates + 3 indices.
# Idempotent — safe to re-run.

set -euo pipefail
ES_URL="${ELASTICSEARCH_URL:-http://elasticsearch:9200}"
log() { echo "[es-init] $*"; }

# Wait for cluster yellow.
until curl -s "${ES_URL}/_cluster/health?wait_for_status=yellow&timeout=60s" >/dev/null; do
  log "waiting for elasticsearch…"
  sleep 5
done

# ── ILM policy: hot 7d → warm 30d → delete 90d ─────────────────────────────
curl -s -X PUT "${ES_URL}/_ilm/policy/bankobs-audit-policy" \
  -H 'Content-Type: application/json' -d '{
  "policy": {
    "phases": {
      "hot":    { "min_age": "0ms",  "actions": { "rollover": { "max_age": "7d", "max_size": "5gb" } } },
      "warm":   { "min_age": "7d",   "actions": { "forcemerge": { "max_num_segments": 1 } } },
      "delete": { "min_age": "90d",  "actions": { "delete": {} } }
    }
  }
}'
log "ILM policy installed"

# ── Index template for audit indices ───────────────────────────────────────
curl -s -X PUT "${ES_URL}/_index_template/bankobs-audit" \
  -H 'Content-Type: application/json' -d '{
  "index_patterns": ["bankobs-audit-*"],
  "data_stream": {},
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.lifecycle.name": "bankobs-audit-policy",
      "index.lifecycle.rollover_alias": "bankobs-audit"
    },
    "mappings": {
      "properties": {
        "@timestamp":      { "type": "date" },
        "service":         { "type": "keyword" },
        "event_type":      { "type": "keyword" },
        "account_id":      { "type": "keyword" },
        "customer_id":     { "type": "keyword" },
        "correlation_id":  { "type": "keyword" },
        "trace_id":        { "type": "keyword" },
        "span_id":         { "type": "keyword" },
        "user_id":         { "type": "keyword" },
        "action":          { "type": "keyword" },
        "result":          { "type": "keyword" },
        "ip_address":      { "type": "ip" },
        "metadata":        { "type": "object" },
        "pii_masked":      { "type": "boolean" }
      }
    }
  }
}'
log "audit template installed"

# ── Standalone compliance events index ─────────────────────────────────────
curl -s -X PUT "${ES_URL}/bankobs-compliance-events" \
  -H 'Content-Type: application/json' -d '{
  "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
  "mappings": {
    "properties": {
      "@timestamp":   { "type": "date" },
      "regulator":    { "type": "keyword" },
      "report_type":  { "type": "keyword" },
      "status":       { "type": "keyword" },
      "payload":      { "type": "object", "enabled": false }
    }
  }
}'
log "compliance-events index installed"

# ── Initialize first data stream ───────────────────────────────────────────
curl -s -X PUT "${ES_URL}/_data_stream/bankobs-audit-default"
log "data stream initialized"

log "elasticsearch init complete"
