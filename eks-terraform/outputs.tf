output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "ecr_registry" {
  description = "Registry prefix for `make eks-push-images` and the Helm global.registry override"
  value       = local.registry
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "node_group_size" {
  value = "${var.node_count} × ${var.node_instance_type}"
}
