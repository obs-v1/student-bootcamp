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

# Security group allowing SSH so you can connect
resource "aws_security_group" "ssh" {
  name        = "spot-r5-2xlarge-ssh"
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
    Name = "spot-r5-2xlarge-ssh"
  }
}

# Security group that opens ALL ports to any IPv4 source (0.0.0.0/0)
resource "aws_security_group" "all_open" {
  name        = "spot-r5-2xlarge-all-open"
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
    Name = "spot-r5-2xlarge-all-open"
  }
}

resource "aws_instance" "spot" {
  ami           = "ami-0220d79f3f480ecf5"
  instance_type = "r5.2xlarge"
  key_name      = "devops"

  vpc_security_group_ids = [aws_security_group.ssh.id, aws_security_group.all_open.id]

  # Request a Spot instance
  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type = "one-time"
    }
  }

  # 100 GB root disk
  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name = "spot-r5-2xlarge"
  }
}

output "public_ip" {
  description = "Public IP address to connect to the instance"
  value       = aws_instance.spot.public_ip
}

