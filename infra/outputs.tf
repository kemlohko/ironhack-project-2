output "cluster_name" {
  value = module.eks.cluster_name
}

output "connect_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}