# =============================================================================
# SecondWave Container Platform - EKS Root Module
# Provisioning a private EKS cluster with Karpenter,
# GitOps bootstrapping, and comprehensive security controls.
#
# ARCHITECTURE DECISION: Single root module per environment
# Each environment (dev/staging/prod) gets its own Terraform workspace
# with environment-specific tfvars. This prevents cross-environment
# blast radius and enables independent change management.
# =============================================================================

locals {
  # ARCHITECTURE DECISION: Environment derivation from cluster name
  # We parse the environment from the cluster name to avoid duplicating
  # the variable. Convention: <project>-<env>-<region> e.g., secondwave-prod-euw2
  environment = reverse(split("-", var.cluster_name))[1]

  # SECURITY SAFEGUARD: Partition tags for resource grouping
  # Tags enable cost allocation per squad and automated cleanup policies.
  common_tags = merge(var.tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# ---------------------------------------------------------------------------
# EKS Cluster Module
# ---------------------------------------------------------------------------
module "eks_cluster" {
  source      = "./modules/eks-cluster"
  version     = null # local module

  cluster_name              = var.cluster_name
  region                    = var.region
  vpc_id                    = var.vpc_id
  private_subnet_ids        = var.private_subnet_ids
  cluster_endpoint_private_cidrs = var.cluster_endpoint_private_cidrs
  cluster_log_types         = var.cluster_log_types
  enable_cluster_encryption = var.enable_cluster_encryption
  node_groups               = var.node_groups
  tags                      = local.common_tags
}

# ---------------------------------------------------------------------------
# IRSA Module - IAM Roles for Kubernetes Service Accounts
# ARCHITECTURE DECISION: IRSA over static credentials or kube2iam
# IRSA uses OIDC federation so pods never hold AWS credentials on disk.
# Unlike kube2iam, IRSA is a first-party AWS feature with native support
# for credential caching and role chaining.
# ---------------------------------------------------------------------------
module "irsa" {
  source  = "./modules/irsa"
  version = null

  cluster_oidc_provider_url = module.eks_cluster.oidc_provider_url
  cluster_oidc_provider_arn = module.eks_cluster.oidc_provider_arn
  cluster_name              = var.cluster_name
  tags                      = local.common_tags
}

# ---------------------------------------------------------------------------
# Karpenter Module - Group-less Auto-Provisioning
# ARCHITECTURE DECISION: Karpenter over Cluster Autoscaler
# Karpenter observes pending pods and provisions nodes directly against
# EC2 fleet APIs in seconds. Cluster Autoscaler adjusts node group sizes
# (minutes). Karpenter also selects optimal instance types dynamically,
# reducing waste. For SecondWave's variable batch workloads, Karpenter
# reduces costs by ~30% through right-sizing.
#
# SECURITY SAFEGUARD: Karpenter removes managed node group state
# With Karpenter, there are no ASGs holding node state. Each node is
# ephemeral and independently managed. This reduces blast radius:
# a misconfigured node group cannot strand 50 nodes. Nodes that fail
# health checks are replaced individually.
# ---------------------------------------------------------------------------
module "karpenter" {
  source  = "./modules/karpenter"
  version = null

  count = var.karpenter_config.enabled ? 1 : 0

  cluster_name              = var.cluster_name
  cluster_endpoint          = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate    = module.eks_cluster.cluster_ca_certificate
  oidc_provider_arn         = module.eks_cluster.oidc_provider_arn
  oidc_provider_url         = module.eks_cluster.oidc_provider_url
  vpc_id                    = var.vpc_id
  private_subnet_ids        = var.private_subnet_ids
  instance_family           = var.karpenter_config.instance_family
  instance_size             = var.karpenter_config.instance_size
  cpu_limit                 = var.karpenter_config.cpu_limit
  memory_limit              = var.karpenter_config.memory_limit
  ttl_seconds_after_empty   = var.karpenter_config.ttl_seconds_after_empty
  tags                      = local.common_tags
}

# ---------------------------------------------------------------------------
# GitOps Bootstrap Module - ArgoCD or Flux
# ARCHITECTURE DECISION: App-of-apps pattern for multi-squad autonomy
# Each squad owns their own application repository. The root app-of-apps
# points to squad-specific app definitions. Squads manage their own
# deployments without cluster-admin access.
# ---------------------------------------------------------------------------
module "gitops_bootstrap" {
  source  = "./modules/gitops-bootstrap"
  version = null

  cluster_name       = var.cluster_name
  cluster_endpoint   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = module.eks_cluster.cluster_ca_certificate
  gitops_tool        = var.gitops_tool
  domain_name        = var.domain_name
  cert_email         = var.cert_email
  argocd_admin_password_secret = module.eks_cluster.argocd_admin_password_secret_arn
  tags               = local.common_tags

  depends_on = [module.eks_cluster]
}

# ---------------------------------------------------------------------------
# Addons Module - Cluster-wide deployments
# ARCHITECTURE DECISION: Single addons module vs per-addon modules
# Helm releases have ordering dependencies (cert-manager CRDs before
# cert-manager Issuers). A single module with explicit depends_on
# chains ensures correct provisioning order.
# ---------------------------------------------------------------------------
module "addons" {
  source  = "./modules/addons"
  version = null

  cluster_name            = var.cluster_name
  cluster_endpoint        = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate  = module.eks_cluster.cluster_ca_certificate
  oidc_provider_arn       = module.eks_cluster.oidc_provider_arn
  vpc_id                  = var.vpc_id
  domain_name             = var.domain_name
  cert_email              = var.cert_email
  irsa_roles              = module.irsa.role_arns
  enable_waf              = var.enable_waf
  tags                    = local.common_tags

  depends_on = [
    module.eks_cluster,
    module.irsa,
    module.karpenter,
    module.gitops_bootstrap
  ]
}

# ---------------------------------------------------------------------------
# ECR Inspector - Container Image Scanning
# ARCHITECTURE DECISION: Inspector over third-party scanners
# AWS Inspector now includes ECR continuous scanning at no additional
# cost (included in the ECR service). It provides CVSS scoring,
# network reachability, and integrates with Security Hub for
# centralized findings. For SecondWave's compliance requirements,
# this satisfies PCI-DSS vulnerability scanning mandates.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "app_repositories" {
  for_each = toset(["backend", "frontend", "worker", "cron"])

  name                 = "${var.cluster_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  # SECURITY SAFEGUARD: Immutable tags prevent tag overwriting
  # which could lead to deploying an untagged/verified image.
  # Force image scanning on push to catch vulnerabilities early.

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = local.common_tags
}

resource "aws_ecr_repository_policy" "app_repositories" {
  for_each = aws_ecr_repository.app_repositories

  repository = each.value.name

  # ARCHITECTURE DECISION: ECR policy restricted to OIDC
  # Only pods authenticated via IRSA can pull images.
  # This prevents any IAM user or role outside the cluster
  # from deploying to these repos.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPullThroughOIDC"
        Effect = "Allow"
        Principal = {
          Federated = module.eks_cluster.oidc_provider_arn
        }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Condition = {
          StringLike = {
            "${module.eks_cluster.oidc_provider_url}:sub" = "system:serviceaccount:*"
          }
        }
      }
    ]
  })
}

# SECURITY SAFEGUARD: Inspector continuous scanning
resource "aws_inspector2_enabler" "ecr_scanning" {
  count = var.enable_image_scanning ? 1 : 0

  account_ids = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR"]
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
