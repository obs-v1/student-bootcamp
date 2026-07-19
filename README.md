# BankObserve360 — Student Bootcamp

A complete 75-service banking platform for the Observability course.

## Running on a Linux EC2 server Manually and running the commands manually

Works natively (the images are x86_64). Checklist:

1. Instance: **r5.4xlarge minimum** (16 vCPU / 128 GB), **150 GB gp3** root volume. Prefer to take spot to save the cost.
2. Install Docker + the compose. You can clone this repo and run `bash scripts/install-tools.sh`
3. Setup license - 
`sed -e '/^LICENSE_KEY/ c LICENSE_KEY=eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJjb2hvcnRAYmFua29ic2VydmUzNjAudHJhaW5pbmciLCJodyI6IioiLCJ0aWVyIjoic3R1ZGVudCIsImZlYXR1cmVzIjpbImFsbCJdLCJqdGkiOiI0NDY4OTRhNS00NDg5LTQ5ZDctOGE2Mi0zM2FkYTYxY2MwNjMiLCJpc3MiOiJiYW5rb2JzZXJ2ZTM2MCIsImV4cCI6MTc5ODgwMzM0MSwiaWF0IjoxNzgzMjUxMzQxfQ.RuC_RlHu6yHRrLglVd_ExZynHq1Lb9nlYruoyFfEO5Hk1uU7PU9z5b_F9F7nzW3Hj3MHVJMj5MhGOjYYZWeiAQ' .env.example >.env`

4. You can deploy the services using `cd ec2-k8s && make up`


## These all can be alternatively initate with terraform code.

```
make tf-apply
```

