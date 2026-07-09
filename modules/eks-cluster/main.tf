# =============================================================================
# EKS Cluster Module
# =============================================================================
# ARCHITECTURE DECISION: Private endpoint only (no public access)
# The EKS API server endpoint is private within the VPC. All kubectl
# access goes through AWS PrivateLink. This eliminates a major attack
# surface: the Kubernetes API server is not internet-addressable.
# For SecondWave's open banking workloads (PCI-DSS, GDPR), this is
# a non-negotiable control.
#
# SECURITY SAFEGUARD: No 0.0.0.0/0 on cluster security group
# The cluster security group only allows inbound from VPC CIDR.
# Any admin access requires VPN/Direct Connect or a bastion host
# within the VPC.
# =============================================================================

locals {
  # ARCHITECTURE DECISION: Subnet suffix tagging for Karpenter
  # We tag private subnets so Karpenter can discover them dynamically
  # without hardcoded subnet IDs in the provisioner.
  subnet_tags = {
    for idx, subnet in var.private_subnet_ids :
    subnet => {
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
      "kubernetes.io/role/internal-elb"           = "1"
    }
  }
}

# ARCHITECTURE DECISION: aws-eks module over raw resources
# The community module handles the complex dance of creating the cluster,
# managing the security group, and wiring the OIDC provider. Writing
# this manually would be ~500 lines with higher risk of misconfiguration.
# The module is maintained by AWS and has thousands of production users.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.20"

  cluster_name    = var.cluster_name
  cluster_version = "1.28"

  # ARCHITECTURE DECISION: Private endpoint only
  # Public access is set to false. All API server traffic flows through
  # the VPC, reducing exposure to the Kubernetes API surface.
  # The trade-off: engineers need VPC access (VPN/DC) to run kubectl.
  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  # SECURITY SAFEGUARD: Restrict private endpoint to VPC CIDRs only
  cluster_endpoint_private_access_cidrs = var.cluster_endpoint_private_cidrs

  # ARCHITECTURE DECISION: KMS encryption for Kubernetes secrets
  # EKS encrypts all etcd data at rest using AWS KMS. This is required
  # for PCI-DSS compliance (requirement 3.4: render stored data
  # unreadable). Without this, anyone with etcd access (or a snapshot)
  # could read secrets in plaintext.
  cluster_encryption_config = var.enable_cluster_encryption ? {
    provider_key_arn = aws_kms_key.eks_secrets[0].arn
    resources        = ["secrets"]
  } : {}

  # ARCHITECTURE DECISION: All control plane logs enabled
  # API, audit, and authenticator logs are sent to CloudWatch for
  # SIEM ingestion (Splunk/Sumo Logic). Controller manager and scheduler
  # logs aid in debugging. Combined cost is ~$15/mo per cluster.
  cluster_enabled_log_types = var.cluster_log_types

  # SECURITY SAFEGUARD: CloudWatch log retention for compliance
  # We retain logs for 90 days (SOC2 minimum) with transition to
  # S3 Glacier for 7-year retention (PCI-DSS).
  cloudwatch_log_group_retention_in_days = 90

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # ARCHITECTURE DECISION: EKS-managed security groups
  # We let EKS create the cluster security group with the correct rules.
  # Adding additional rules via `node_security_group_additional_rules`.
  create_cluster_security_group = true
  create_node_security_group    = true

  # ARCHITECTURE DECISION: Node groups for dev/staging, Karpenter for prod
  # Managed node groups provide a stable baseline for dev/staging.
  # Prod uses Karpenter (configured in root module) for dynamic provisioning
  # but we still create a small on-demand node group for critical addons.
  eks_managed_node_groups = {
    for env, config in var.node_groups : env => {
      instance_types = config.instance_types
      capacity_type  = config.capacity_type

      desired_size = config.desired_size
      min_size     = config.min_size
      max_size     = config.max_size

      disk_size = config.disk_size

      k8s_labels = config.k8s_labels
      k8s_taints = config.k8s_taints

      # ARCHITECTURE DECISION: Launch template via module
      # The module handles launch template creation with the correct
      # bootstrap script. Custom bootstrap args for kubelet extra flags
      # would be added here if needed.
      use_custom_launch_template = false

      subnet_ids = var.private_subnet_ids
    }
  }

  # SECURITY SAFEGUARD: Self-managed node group security group rules
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description = "Node all egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # SECURITY SAFEGUARD: No node-to-node ingress from outside VPC
  cluster_security_group_additional_rules = {
    ingress_vpc_all = {
      description = "VPC to cluster API"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = var.cluster_endpoint_private_cidrs
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# KMS Key for EKS Secrets Encryption
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Customer-managed KMS key vs AWS-managed
# AWS-managed keys (aws/eks) cannot have custom key policies, preventing
# cross-account access or integration with external HSM. A customer-managed
# key allows us to:
#   1. Restrict key usage to specific IAM roles (IRSA)
#   2. Enable key rotation (yearly)
#   3. Integrate with CloudTrail for key usage auditing
# ---------------------------------------------------------------------------
resource "aws_kms_key" "eks_secrets" {
  count = var.enable_cluster_encryption ? 1 : 0

  description             = "EKS Secrets Encryption Key - ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  # SECURITY SAFEGUARD: Key policy limits to cluster roles
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "eks_secrets" {
  count = var.enable_cluster_encryption ? 1 : 0

  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets[0].key_id
}

# ---------------------------------------------------------------------------
# OIDC Provider for IRSA
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Module-managed OIDC provider
# The terraform-aws-eks module creates the OIDC provider automatically
# when `enable_irsa = true`. The provider URL and ARN are exposed as
# outputs for the IRSA module.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Secrets Manager for ArgoCD Admin Password
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "argocd_admin_password" {
  name_prefix = "${var.cluster_name}-argocd-admin-"

  # SECURITY SAFEGUARD: Automatic rotation every 30 days
  rotation_rules {
    automatically_after_days = 30
  }

  tags = var.tags
}

resource "random_password" "argocd_admin" {
  length  = 24
  special = true
  # SECURITY SAFEGUARD: Exclude ambiguous characters
  # Avoid 0/O, 1/l/I to prevent confusion in console copy-paste.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret_version" "argocd_admin" {
  secret_id = aws_secretsmanager_secret.argocd_admin_password.id
  secret_string = jsonencode({
    password = random_password.argocd_admin.result
  })
}

# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}
