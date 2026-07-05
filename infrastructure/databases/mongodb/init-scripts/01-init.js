// MongoDB init: collections, indexes, and seed for fraud_rules / aml_cases / audit_events / loan_applications / transactions
// Runs once via /docker-entrypoint-initdb.d (mongo image).

db = db.getSiblingDB('bankobs');

// ── Auth user (admin DB) ────────────────────────────────────────────────────
db.getSiblingDB('admin').createUser({
  user: 'bankobs',
  pwd: 'Training123!',
  roles: [
    { role: 'readWrite', db: 'bankobs' },
    { role: 'dbAdmin',   db: 'bankobs' }
  ]
});

// ── Collections + indexes ───────────────────────────────────────────────────
db.createCollection('transactions');
db.transactions.createIndex({ customer_id: 1, created_at: -1 });
db.transactions.createIndex({ payment_type: 1, status: 1, created_at: -1 });
db.transactions.createIndex({ trace_id: 1 });

db.createCollection('aml_cases');
db.aml_cases.createIndex({ customer_id: 1, status: 1 });
db.aml_cases.createIndex({ created_at: -1 });
db.aml_cases.createIndex({ severity: 1, status: 1 });

db.createCollection('fraud_rules');
db.fraud_rules.createIndex({ enabled: 1, severity: 1 });
db.fraud_rules.createIndex({ rule_id: 1 }, { unique: true });

db.createCollection('audit_events');
db.audit_events.createIndex({ account_id: 1, event_timestamp: -1 });
db.audit_events.createIndex({ service: 1, event_type: 1, event_timestamp: -1 });
db.audit_events.createIndex({ correlation_id: 1 });

db.createCollection('loan_applications');
db.loan_applications.createIndex({ customer_id: 1, status: 1 });
db.loan_applications.createIndex({ applied_at: -1 });

// ── Seed: 200 fraud rules ───────────────────────────────────────────────────
const ruleTemplates = [
  { name: 'Large UPI transaction',       condition: 'amount > 50000',  severity: 'MEDIUM', action: 'FLAG' },
  { name: 'Very large UPI transaction',  condition: 'amount > 500000', severity: 'HIGH',   action: 'BLOCK' },
  { name: 'Night-time transaction',      condition: 'hour >= 23 || hour <= 5', severity: 'LOW', action: 'LOG' },
  { name: 'New device + new VPA',        condition: 'new_device && new_vpa', severity: 'HIGH',   action: 'BLOCK' },
  { name: 'Velocity breach 1m',          condition: 'txn_count_1m > 5', severity: 'HIGH',    action: 'BLOCK' },
  { name: 'Velocity breach 10m',         condition: 'txn_count_10m > 10', severity: 'MEDIUM', action: 'FLAG' },
  { name: 'Geo anomaly',                 condition: 'city != usual_city', severity: 'MEDIUM', action: 'FLAG' },
  { name: 'Multiple PIN failures',       condition: 'failed_pins_1h >= 3', severity: 'HIGH', action: 'BLOCK' },
  { name: 'Round-trip suspicious',       condition: 'round_trip_48h', severity: 'HIGH', action: 'FLAG' },
  { name: 'Structuring pattern',         condition: 'structuring_45k_to_50k_24h', severity: 'HIGH', action: 'FLAG' }
];
const fraudRules = [];
for (let i = 1; i <= 200; i++) {
  const t = ruleTemplates[i % ruleTemplates.length];
  fraudRules.push({
    rule_id:   'R' + String(i).padStart(3, '0'),
    name:      t.name + ' #' + i,
    condition: t.condition,
    action:    t.action,
    severity:  t.severity,
    enabled:   i % 20 !== 0,    // 95% enabled
    created_at: new Date(),
    updated_at: new Date()
  });
}
db.fraud_rules.insertMany(fraudRules);

// ── Seed: 500 AML cases ────────────────────────────────────────────────────
const amlCases = [];
const statuses = ['OPEN', 'INVESTIGATING', 'ESCALATED', 'CLOSED_FALSE_POSITIVE', 'CLOSED_CONFIRMED'];
const severities = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];
for (let i = 1; i <= 500; i++) {
  amlCases.push({
    case_id:     'AML-' + String(i).padStart(6, '0'),
    customer_id: 'CUST-' + String((i % 5000) + 1).padStart(8, '0'),
    case_type:   ['STRUCTURING','SANCTIONS_MATCH','LARGE_CASH','ROUND_TRIP'][i % 4],
    severity:    severities[i % 4],
    status:      statuses[i % 5],
    created_at:  new Date(Date.now() - (i * 86400000 / 10)),
    description: 'Auto-seeded AML case for training'
  });
}
db.aml_cases.insertMany(amlCases);

// ── Seed: 50,000 transactions ──────────────────────────────────────────────
const txnTypes = ['UPI','NEFT','RTGS','IMPS','NACH'];
const txnStatuses = ['INITIATED','PROCESSING','COMPLETED','FAILED'];
const batch = [];
for (let i = 1; i <= 50000; i++) {
  batch.push({
    txn_id:       'TXN-' + String(i).padStart(10, '0'),
    customer_id:  'CUST-' + String((i % 5000) + 1).padStart(8, '0'),
    payment_type: txnTypes[i % 5],
    amount:       Math.round(Math.random() * 50000 * 100) / 100,
    status:       txnStatuses[i % 100 === 0 ? 3 : 2],   // 1% failed
    created_at:   new Date(Date.now() - (i * 60000))
  });
  if (batch.length === 5000) {
    db.transactions.insertMany(batch);
    batch.length = 0;
  }
}
if (batch.length > 0) db.transactions.insertMany(batch);

print('MongoDB seed complete: ' +
      db.fraud_rules.countDocuments() + ' fraud_rules, ' +
      db.aml_cases.countDocuments() + ' aml_cases, ' +
      db.transactions.countDocuments() + ' transactions');
