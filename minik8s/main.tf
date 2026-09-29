# ──────────────────────────────────────────────────────────────────────────────
#  minik8s — a bare Kubernetes lab box
#
#  Same shape as the root main.tf (spot EC2 in the default VPC, password SSH,
#  provisioned over remote-exec), with two deliberate differences:
#    · t3.large instead of r5.4xlarge — this box runs an EMPTY cluster
#    · it stops after `kind create cluster`. No .env, no license, no Helm
#      release, no loadrunner. Nothing but Kubernetes.
#
#  Drive it from the Makefile in this directory:
#      make tf-apply      → instance + kind cluster
#      make kubeconfig    → talk to it from your laptop
#      make tf-destroy    → tear it all down
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Cluster + context name. Kept in a local so the kind config, the API-server
# forwarder and the emitted kubeconfig can never drift apart.
locals {
  cluster_name = "minik8s"
  context_name = "minik8s-ec2"
}

# Security group allowing SSH so you can connect.
# Named minik8s-* so it can coexist with the root stack's spot-r5-* groups —
# SG names must be unique per VPC, and both stacks land in the default VPC.
resource "aws_security_group" "ssh" {
  name        = "minik8s-ssh"
  description = "Allow SSH inbound"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "minik8s-ssh"
  }
}

# Security group that opens ALL ports to any IPv4 source (0.0.0.0/0).
# Training convenience: NodePorts, :6443, and whatever you expose next all
# work without touching the SG. The cluster API is a root credential — do not
# leave this box running unattended.
resource "aws_security_group" "all_open" {
  name        = "minik8s-all-open"
  description = "Allow all inbound traffic from any IPv4"

  ingress {
    description = "All ports from any IPv4"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "minik8s-all-open"
  }
}

resource "aws_instance" "spot" {
  # Same lab AMI as the root stack — scripts/install-tools.sh depends on the
  # `labauto` helper that only exists on it.
  ami           = "ami-0220d79f3f480ecf5"
  instance_type = "t3.large"

  vpc_security_group_ids = [aws_security_group.ssh.id, aws_security_group.all_open.id]

  # Request a Spot instance
  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type = "one-time"
    }
  }

  # 150 GB root disk. Not arbitrary: install-tools.sh grows the LVM volumes to
  # a fixed 100G /var + 15G / + 5G /home, which fails on a smaller disk.
  root_block_device {
    volume_size = 150
    volume_type = "gp3"
  }

  tags = {
    Name = "minik8s"
  }
}

# ── 1. tools ──────────────────────────────────────────────────────────────────
# docker · kind · kubectl · helm · jq · make, plus the LVM resize.
resource "null_resource" "make_instance_ready" {
  depends_on = [aws_instance.spot]

  triggers = {
    instance_id = timestamp()
  }

  provisioner "remote-exec" {
    inline = [
      "rm -rf student-bootcamp",
      "git clone https://github.com/obs-v1/student-bootcamp.git",
      "cd student-bootcamp",
      "sudo bash scripts/install-tools.sh",
      # So the NEXT connection can run docker without sudo. Group membership is
      # only picked up on login, which is exactly what the second provisioner's
      # fresh SSH session gives us.
      "sudo usermod -aG docker ec2-user || true",
    ]

    connection {
      type     = "ssh"
      host     = aws_instance.spot.public_ip
      user     = "ec2-user"
      password = "DevOps321"
    }
  }
}

# ── 2. the cluster, and nothing else ──────────────────────────────────────────
resource "null_resource" "create_cluster" {
  depends_on = [aws_instance.spot, null_resource.make_instance_ready]

  triggers = {
    instance_id = timestamp()
  }

  # The kind topology lives next to this file so you can edit it (add workers,
  # publish more NodePorts) and re-apply.
  provisioner "file" {
    source      = "${path.module}/kind-config.yaml"
    destination = "/home/ec2-user/kind-config.yaml"

    connection {
      type     = "ssh"
      host     = aws_instance.spot.public_ip
      user     = "ec2-user"
      password = "DevOps321"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "export PATH=/usr/local/bin:$PATH",
      # kind's node is a container full of pods; the stock inotify limits run
      # out well before the node does.
      "sudo sysctl -w fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192",
      "printf 'fs.inotify.max_user_watches=1048576\\nfs.inotify.max_user_instances=8192\\n' | sudo tee /etc/sysctl.d/99-minik8s.conf >/dev/null",
      # Idempotent: a re-apply on a live box is a no-op, not a rebuild.
      "kind get clusters 2>/dev/null | grep -qx ${local.cluster_name} || kind create cluster --name ${local.cluster_name} --config /home/ec2-user/kind-config.yaml",
      "kubectl cluster-info --context kind-${local.cluster_name} | head -2",
      "kubectl get nodes",
      # Republish kind's loopback-bound API server on :6443 so `make kubeconfig`
      # can hand you a kubeconfig pointing at THIS instance's public IP.
      "cd ~/student-bootcamp && CLUSTER=${local.cluster_name} CONTEXT_NAME=${local.context_name} bash scripts/expose-kube-api.sh >/dev/null",
    ]

    connection {
      type     = "ssh"
      host     = aws_instance.spot.public_ip
      user     = "ec2-user"
      password = "DevOps321"
    }
  }
}

output "public_ip" {
  description = "Public IP address to connect to the instance"
  value       = aws_instance.spot.public_ip
}

output "cluster_name" {
  description = "Name of the kind cluster running on the instance"
  value       = local.cluster_name
}

output "next_steps" {
  description = "What to run once apply finishes"
  value       = "make kubeconfig && make kube-check   (or: make ssh)"
}
