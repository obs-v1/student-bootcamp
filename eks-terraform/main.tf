# eks-lab — the SINGLE-CLUSTER training deployment for `make eks-up`.
#
# Deliberately simpler than the 3-account reference architecture in ../
# (which remains plan-only): one VPC, one EKS cluster, one managed node
# group sized to hold the full 75-service platform. Everything a student
# needs to run the bank on AWS, nothing they don't.

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name     = var.cluster_name
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  tags = {
    Project = "bankobserve360"
    Purpose = "training"
    Stack   = "eks-lab"
  }
}

# ── VPC ─────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway = true
  single_nat_gateway = true # training: cheap beats HA
  enable_dns_support = true
  enable_dns_hostnames = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }

  tags = local.tags
}

# ── EKS ─────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    platform = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_count
      max_size       = var.node_count + 2
      desired_size   = var.node_count
      disk_size      = 100

      labels = { workload = "bankobserve360" }
    }
  }

  tags = local.tags
}

# IRSA role so the EBS CSI driver can provision volumes (Oracle,
# Cassandra, Kafka, ES all want PersistentVolumes).
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.47"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}
