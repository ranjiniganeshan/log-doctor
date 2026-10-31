module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.project_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Gives the identity running `terraform apply` cluster-admin via an access entry.
  enable_cluster_creator_admin_permissions = true

  # IRSA: creates the cluster's IAM OIDC provider.
  enable_irsa = true

  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Single AZ to keep the demo cheap (no cross-AZ data transfer to OpenSearch).
      subnet_ids = [module.vpc.private_subnets[0]]

      disk_size = 20
    }
  }
}
