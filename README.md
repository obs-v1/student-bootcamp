# BankObserve360 — Student Bootcamp

A complete 75-service banking platform for the Observability course.

## Running on a Linux EC2 server Manually and running the commands manually

Works natively (the images are x86_64). Checklist:

1. Instance: **r5.4xlarge minimum** (16 vCPU / 128 GB), **150 GB gp3** root volume. Prefer to take spot to save the cost.
2. Install Docker + the compose. You can clone this repo and run `bash scripts/install-tools.sh`
3. Setup license - 
`sed -e '/^LICENSE_KEY/ c LICENSE_KEY=eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJyYWdodWsudml0QGdtYWlsLmNvbSIsImh3IjoiKiIsInRpZXIiOiJzdHVkZW50IiwiZmVhdHVyZXMiOlsiYWxsIl0sImp0aSI6ImFlNmEzM2NhLTk5NGYtNDkzMC1hMGFiLTQ4ZTQ0OTI0OWRjNSIsImx2IjoyLCJpc3MiOiJiYW5rb2JzZXJ2ZTM2MCIsImV4cCI6MTc5NjA1NTg3OCwiaWF0IjoxNzk0NzU5ODc4fQ.VQN6UDfk4ttHJUwS4IjBQPMOq7lyTkR54Oh-oyBKaARl5SDBS2OWHMoCT3EVP1FX40zLhe5Yx2_Schxy3qAOBQ' .env.example >.env`

4. You can deploy the services using `cd ec2-k8s && make up`

Portal login details : `CUST-00000001` / `Training@123`.

## These all can be alternatively initate with terraform code.

```
make tf-apply
```



# Reference for students - Recalling some commands that are needed.

https://github.com/obs-v1/student-bootcamp/blob/main/student-notes/README.md


# Workstation Setup.

In case if you are struggling wiht local setup of Laptop then use a Linux box as workstation.

1. Create a EC2 instance with the given AMI

https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#Images:visibility=public-images;imageName=Redhat-9-DevOps-Practice;v=3;$case=tags:false%5C,client:false;$regex=tags:false%5C,client:false

2. Create a IAM role For Ec2 with Admin Policy & Attach that to workstation ( ec2 )

3. Connect to that instance with your Key or Username / Password : ec2-user / DevOps321



# Google Document

https://docs.google.com/document/d/1dnDU0_FQEgWm75ftqJhCWwstdsrsSEI2VEq-lqWYCMU
