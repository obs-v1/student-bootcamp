variable "region" {
  description = "AWS region for the training cluster"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "bankobs-lab"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.42.0.0/16"
}

variable "node_instance_type" {
  description = "Managed node group instance type. The full platform (75 services + Oracle/Cassandra/Kafka/ES) needs real memory."
  type        = string
  default     = "m5.2xlarge" # 8 vCPU / 32 GiB
}

variable "node_count" {
  description = "Desired node count. 3× m5.2xlarge ≈ 24 vCPU / 96 GiB — comfortable for the full stack."
  type        = number
  default     = 3
}
