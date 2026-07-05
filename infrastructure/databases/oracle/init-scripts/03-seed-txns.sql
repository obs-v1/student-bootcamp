-- 100,000 transactions across the 10,000 seeded accounts.
-- Mix of UPI/NEFT/RTGS/IMPS/ATM channels for realistic distributions.

ALTER SESSION SET CONTAINER = XEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = BANKOBS_CORE;

DECLARE
  v_acct  VARCHAR2(20);
  v_type  VARCHAR2(10);
  v_chan  VARCHAR2(20);
  v_amt   NUMBER(18,2);
BEGIN
  FOR i IN 1..100000 LOOP
    v_acct := 'ACC' || LPAD(TO_CHAR(MOD(i, 10000) + 1), 12, '0');
    v_type := CASE WHEN MOD(i, 2) = 0 THEN 'DEBIT' ELSE 'CREDIT' END;
    v_chan := CASE MOD(i, 5)
                WHEN 0 THEN 'UPI'
                WHEN 1 THEN 'NEFT'
                WHEN 2 THEN 'IMPS'
                WHEN 3 THEN 'ATM'
                ELSE      'BRANCH'
              END;
    v_amt := ROUND(DBMS_RANDOM.VALUE(10, 50000), 2);
    INSERT INTO TRANSACTIONS (
      txn_id, account_id, txn_type, amount, currency, status, reference_no, channel, created_at
    ) VALUES (
      LOWER(RAWTOHEX(SYS_GUID())),
      v_acct, v_type, v_amt, 'INR',
      CASE WHEN MOD(i, 100) = 0 THEN 'FAILED' ELSE 'COMPLETED' END,
      'REF' || LPAD(TO_CHAR(i), 12, '0'),
      v_chan,
      SYSTIMESTAMP - NUMTODSINTERVAL(DBMS_RANDOM.VALUE(0, 90 * 86400), 'SECOND')
    );
    IF MOD(i, 10000) = 0 THEN COMMIT; END IF;
  END LOOP;
  COMMIT;
END;
/

-- ── GL entries: double-entry mirror of transactions ────────────────────────
DECLARE
  v_id    VARCHAR2(36);
  v_acct  VARCHAR2(20);
  v_amt   NUMBER(18,2);
  v_type  VARCHAR2(10);
BEGIN
  FOR rec IN (SELECT txn_id, account_id, amount, txn_type, created_at
              FROM TRANSACTIONS WHERE ROWNUM <= 50000) LOOP
    INSERT INTO GL_ENTRIES (account_id, debit_amount, credit_amount, narration, posting_date, batch_id)
    VALUES (
      rec.account_id,
      CASE WHEN rec.txn_type = 'DEBIT'  THEN rec.amount ELSE 0 END,
      CASE WHEN rec.txn_type = 'CREDIT' THEN rec.amount ELSE 0 END,
      'Auto-seeded GL entry for ' || rec.txn_id,
      TRUNC(rec.created_at),
      'SEED-BATCH-001'
    );
  END LOOP;
  COMMIT;
END;
/
