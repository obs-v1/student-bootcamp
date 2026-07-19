# B4 — Application Setup: BankObserve360

This is the system you will observe, break and fix for the whole course. By
the end of this module you should know what it is, how it gets deployed, how
data gets into it, and how to prove it's healthy — because from week 1
onwards, "is the app okay?" is *your* question to answer.

All outputs below come from the training server where the platform is
running.

---

## 1. What the application is

**BankObserve360** — a full retail bank, in miniature: 75 microservices
written in 4 languages (Java, Go, Python, Node.js), spread across 7 business
domains. Count them yourself on the cluster:

```
$ kubectl -n bankobs get deploy -L domain --no-headers | awk '{print $NF}' | sort | uniq -c
     11 core-banking        accounts, ledger, balances, statements, branches...
     10 payments            UPI, NEFT, RTGS, IMPS, payment gateway & router...
      9 retail-banking      loans, FDs, RDs, credit cards, insurance, wealth...
      8 fraud-risk          fraud detection, AML, sanctions, velocity checks...
      7 customer-identity   KYC, Aadhaar/PAN adapters, onboarding, consent...
      6 audit-compliance    audit trail, RBI reports, PCI logging...
      5 notifications       SMS, email, push, WhatsApp dispatch...
      3 legacy-stack        a "mainframe" simulator and its bridges
      2 platform            web portal + license checker
```

Under the services sit **8 data stores**, each chosen the way a real bank
would:

```
$ kubectl -n bankobs get sts
NAME            READY      what it holds
oracle          1/1        core banking ledger — accounts & transactions
postgres        1/1        identity, retail products (loans, FDs, cards)
mongodb         1/1        fraud rules, AML cases, loan applications
redis           1/1        cache, sessions, OTPs, rate limits
cassandra       1/1        UPI transaction history
elasticsearch   1/1        audit & statement search
kafka           1/1        event backbone (12 banking topics)
rabbitmq        1/1        notification dispatch queues
```

On top: a **customer web portal** (what you'll click) and a **load runner**
that can generate realistic traffic (used in later weeks).

Why so much variety? Because that's what real production looks like — and
observability tools earn their pay precisely when a request crosses four
languages and three databases.

All images are public (`public.ecr.aws/w8x4g9h7/obs-v1/*`). You never build
anything.

## 2. Application setup



```
cd student-bootcamp
sed -e '/^LICENSE_KEY/ c LICENSE_KEY=eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJjb2hvcnRAYmFua29ic2VydmUzNjAudHJhaW5pbmciLCJodyI6IioiLCJ0aWVyIjoic3R1ZGVudCIsImZlYXR1cmVzIjpbImFsbCJdLCJqdGkiOiI0NDY4OTRhNS00NDg5LTQ5ZDctOGE2Mi0zM2FkYTYxY2MwNjMiLCJpc3MiOiJiYW5rb2JzZXJ2ZTM2MCIsImV4cCI6MTc5ODgwMzM0MSwiaWF0IjoxNzgzMjUxMzQxfQ.RuC_RlHu6yHRrLglVd_ExZynHq1Lb9nlYruoyFfEO5Hk1uU7PU9z5b_F9F7nzW3Hj3MHVJMj5MhGOjYYZWeiAQ' .env.example >.env
cd ec2-k8s
make up
```


## 3. Functional tour — walk the bank as a customer

Open `http://<server-ip>/` in your browser. Log in as
`CUST-00000001` / `Training@123`. Spend 20 minutes actually *using* the bank
— in the incident weeks you must know what "working" looks like, or you won't
recognise "broken".

What to do, and what's underneath while you do it:

- **Balance, statement, branches** — the core-banking read path. (You now
  know the first balance view may take a second and repeats are instant —
  that's Redis.)
- **UPI payment, end to end** — pay `cust00000002@bankobs` a few hundred
  rupees. One click crosses gateway → upi-service → fraud checks → ledger →
  Cassandra history → a Kafka event for notifications. The receipt shows a
  payment ID *and a trace ID* — from week 2 that trace ID becomes your best
  friend.
- **Loan application and approval** — apply for a personal loan; watch it go
  eligibility → risk scoring → approval → disbursement into your balance.
- **KYC verification** — run the KYC check on your profile; behind it sit the
  identity services and the (simulated) Aadhaar/PAN adapters.
- **Fraud scoring — invisible but always on.** Every payment you made was
  scored. Proof, from the fraud service's live log (that `payment_id` is the
  UPI payment we sent in section 5):

  ```
  $ kubectl -n bankobs logs deploy/fraud-detection | grep score | tail -1
  {"service":"fraud-detection","payment_id":"bbe2dce0-abb9-476a-955f-5e25ea0ac801",
   "score":0,"decision":"ALLOW","event":"scored"}
  ```

- **Notification center** — the bell icon: every payment and loan event
  produced a notification, delivered through RabbitMQ by the notification
  services.
- **Audit trail awareness** — you won't see it in the UI, but every action
  you just took also landed on the `banking.audit.events` Kafka topic and got
  consumed by audit-service into Elasticsearch. Regulators (and week 4 labs)
  read from there. Nothing in a bank happens un-audited.

## 4. Daily commands

Your morning routine on this server, from `student-bootcamp/ec2-k8s`
(compose users: same names, from the repo root, minus the `cd`):

```
$ make status                 # pod summary + anything unhealthy
      3 Completed
      2 CrashLoopBackOff      ← balance-service & cheque-service: our two
     67 Running                 permanently-broken specimens. 67 Running +
                                these 2 = a HEALTHY morning. Memorise that.
$ make health                 # ping the critical /health endpoints
  gateway-service        OK
  auth-service           OK
  account-service        OK
  upi-service            OK
  loan-origination       OK

$ make smoke                  # the 3-step business test from section 5
$ make logs-svc S=upi-service # follow one service's logs
```

Ending the day: Terminate the instance if you have created it manually. If terraform has been used then use `make tf-destroy` to clear the resources.

## 5. Hands-on checklist

Do these now; they're the baseline for every later lab:

1. Log into the portal and complete the tour in section 6 — every bullet.
2. From the CLI: login, balance ×2 (see the cache flip), one UPI payment,
   one loan. Save the trace IDs you get.
3. Run `make seed-verify`, `make status`, `make health`. Screenshot or copy
   your healthy baseline.
4. Find your UPI payment's fraud score in the fraud-detection logs
   (`kubectl -n bankobs logs deploy/fraud-detection | grep <your-payment-id>`).
5. Break-glass drill: which single service, if down, stops *every* other
   service from starting? (You met it in section 2. Check what
   `kubectl -n bankobs logs` of any app pod says at startup.)
