locals {
  cluster_name = "eks-${var.student_name}"
}

# --- Network ---
# Note: every student's VPC uses the same CIDR (10.0.0.0/16). That's fine —
# separate VPCs are fully isolated, so identical ranges never conflict.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "vpc-${var.student_name}"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # ONE NAT gateway, not one per AZ (each costs ~$32/mo)
  enable_dns_hostnames = true

  # Tags that let EKS find subnets for load balancers
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

# --- EKS cluster + worker nodes ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.k8s_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true   # you get kubectl admin automatically

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = var.min_nodes
      max_size       = var.max_nodes
      desired_size   = var.desired_nodes
    }
  }
}