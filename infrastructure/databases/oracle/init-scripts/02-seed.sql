-- Seed data for BANKOBS_CORE
-- 50 branches, 5,000 customers, 10,000 accounts, 100,000 transactions
-- Deterministic so labs always start from the same baseline.

ALTER SESSION SET CONTAINER = XEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = BANKOBS_CORE;

-- ── Branches (50 rows) ──────────────────────────────────────────────────────
DECLARE
  TYPE city_arr IS TABLE OF VARCHAR2(50);
  TYPE state_arr IS TABLE OF VARCHAR2(50);
  cities city_arr := city_arr(
    'Mumbai','Delhi','Bangalore','Chennai','Kolkata','Hyderabad','Pune','Ahmedabad',
    'Jaipur','Lucknow','Kanpur','Nagpur','Indore','Thane','Bhopal','Visakhapatnam',
    'Patna','Vadodara','Ghaziabad','Ludhiana','Agra','Nashik','Faridabad','Meerut',
    'Rajkot','Kalyan','Vasai','Varanasi','Srinagar','Aurangabad','Dhanbad','Amritsar',
    'Navi Mumbai','Allahabad','Ranchi','Howrah','Coimbatore','Jabalpur','Gwalior','Vijayawada',
    'Jodhpur','Madurai','Raipur','Kota','Guwahati','Chandigarh','Solapur','Hubli','Mysore','Tiruchirappalli');
  states state_arr := state_arr(
    'Maharashtra','Delhi','Karnataka','Tamil Nadu','West Bengal','Telangana','Maharashtra','Gujarat',
    'Rajasthan','Uttar Pradesh','Uttar Pradesh','Maharashtra','Madhya Pradesh','Maharashtra','Madhya Pradesh','Andhra Pradesh',
    'Bihar','Gujarat','Uttar Pradesh','Punjab','Uttar Pradesh','Maharashtra','Haryana','Uttar Pradesh',
    'Gujarat','Maharashtra','Maharashtra','Uttar Pradesh','Jammu and Kashmir','Maharashtra','Jharkhand','Punjab',
    'Maharashtra','Uttar Pradesh','Jharkhand','West Bengal','Tamil Nadu','Madhya Pradesh','Madhya Pradesh','Andhra Pradesh',
    'Rajasthan','Tamil Nadu','Chhattisgarh','Rajasthan','Assam','Chandigarh','Maharashtra','Karnataka','Karnataka','Tamil Nadu');
BEGIN
  FOR i IN 1..50 LOOP
    INSERT INTO BRANCHES (branch_id, branch_name, ifsc, city, state, zone) VALUES (
      LPAD(TO_CHAR(i), 6, '0'),
      cities(i) || ' Main Branch',
      'BANK0' || LPAD(TO_CHAR(i), 6, '0'),
      cities(i),
      states(i),
      CASE WHEN i <= 12 THEN 'WEST'
           WHEN i <= 25 THEN 'NORTH'
           WHEN i <= 37 THEN 'SOUTH'
           ELSE 'EAST' END
    );
  END LOOP;
END;
/

-- ── Customers (5,000 rows) ──────────────────────────────────────────────────
DECLARE
  v_first VARCHAR2(20);
  v_last  VARCHAR2(20);
  TYPE first_arr IS TABLE OF VARCHAR2(20);
  TYPE last_arr  IS TABLE OF VARCHAR2(20);
  firsts first_arr := first_arr('Raghu','Priya','Amit','Suman','Vikram','Anjali','Rohit','Neha','Sandeep','Pooja',
                                'Rajesh','Kavita','Anil','Meena','Sunil','Geeta','Mohan','Lata','Deepak','Shilpa');
  lasts  last_arr  := last_arr('Sharma','Verma','Patel','Singh','Kumar','Reddy','Iyer','Nair','Khan','Gupta',
                               'Joshi','Mehta','Shah','Pillai','Rao','Das','Bose','Naidu','Chopra','Bhatt');
BEGIN
  FOR i IN 1..5000 LOOP
    v_first := firsts(MOD(i, 20) + 1);
    v_last  := lasts(MOD(i, 20) + 1);
    INSERT INTO CUSTOMERS (
      customer_id, name_token, dob_masked, pan_masked, aadhaar_masked,
      mobile_masked, email_masked, risk_category
    ) VALUES (
      'CUST-' || LPAD(TO_CHAR(i), 8, '0'),
      LOWER(RAWTOHEX(SYS_GUID())),
      LPAD(MOD(i, 28) + 1, 2, '0') || '/XX/' || (1960 + MOD(i, 50)),
      'XXXXX' || LPAD(MOD(i, 9999), 4, '0') || CHR(65 + MOD(i, 26)),
      'XXXX-XXXX-' || LPAD(MOD(i, 9999), 4, '0'),
      SUBSTR(LPAD(TO_CHAR(9800000000 + i), 10, '0'), 1, 2) || 'XXXXX' || SUBSTR(LPAD(TO_CHAR(9800000000 + i), 10, '0'), 8, 3),
      LOWER(SUBSTR(v_first, 1, 2)) || '****@gmail.com',
      CASE WHEN MOD(i, 100) = 0 THEN 'HIGH'
           WHEN MOD(i, 20) = 0  THEN 'MEDIUM'
           ELSE 'LOW' END
    );
  END LOOP;
END;
/

-- ── Accounts (10,000 rows — 2 accounts per customer on average) ─────────────
DECLARE
  v_branch VARCHAR2(6);
  v_ifsc   VARCHAR2(11);
BEGIN
  FOR i IN 1..10000 LOOP
    v_branch := LPAD(TO_CHAR(MOD(i, 50) + 1), 6, '0');
    SELECT ifsc INTO v_ifsc FROM BRANCHES WHERE branch_id = v_branch;
    INSERT INTO ACCOUNTS (
      account_id, customer_id, account_type, balance, status, branch_code, ifsc
    ) VALUES (
      'ACC' || LPAD(TO_CHAR(i), 12, '0'),
      'CUST-' || LPAD(TO_CHAR(MOD(i, 5000) + 1), 8, '0'),
      CASE MOD(i, 4) WHEN 0 THEN 'SAVINGS' WHEN 1 THEN 'CURRENT' WHEN 2 THEN 'FD' ELSE 'RD' END,
      ROUND(DBMS_RANDOM.VALUE(1000, 500000), 2),
      CASE WHEN MOD(i, 200) = 0 THEN 'FROZEN'
           WHEN MOD(i, 500) = 0 THEN 'CLOSED'
           ELSE 'ACTIVE' END,
      v_branch,
      v_ifsc
    );
  END LOOP;
END;
/

-- ── Transactions (100,000 rows) ─────────────────────────────────────────────
-- Deferred to a background batch in 03-seed-txns.sql to keep init startup snappy.

COMMIT;
