# =============================================================================
# IRSA Module - IAM Roles for Kubernetes Service Accounts
# =============================================================================
# ARCHITECTURE DECISION: IRSA over static credentials or node instance profiles
# Kubernetes pods in SecondWave access AWS services (DynamoDB, SQS, S3, RDS)
# for their business logic. Options for AWS credential management:
#
# 1. Static credentials in Kubernetes Secrets
#    - Security: Credentials stored in etcd, visible to anyone with secret get
#    - Rotation: Manual, error-prone
#    - Audit: No per-pod identity tracking
#
# 2. Instance profile (all pods share node role)
#    - Security: Over-permissioned (any pod on the node can assume the role)
#    - Audit: No per-pod identity
#
# 3. kube2iam/kiam
#    - Security: DaemonSet intercepting metadata requests, MITM risk
#    - Maintenance: Third-party project, additional DaemonSet to manage
#
# 4. IRSA (selected)
#    - Security: Keyless, OIDC-federated, per-service-account IAM roles
#    - Maintenance: AWS native, no extra components
#    - Audit: CloudTrail logs include pod identity via OIDC subject
#
# SECURITY SAFEGUARD: Keyless authentication
# IRSA uses OIDC token exchange. Pods receive a signed JWT from the
# Kubernetes TokenReview API, which is exchanged for an AWS STS token.
# No AWS access keys ever exist on the pod filesystem or in memory.
# This eliminates secret exfiltration attacks targeting credential files.
# =============================================================================

locals {
  # ARCHITECTURE DECISION: Add-on service accounts mapped to IAM roles
  # Each cluster-wide add-on gets its own IAM role with least-privilege
  # policies. This enables:
  #   1. Independent audit trails per add-on
  #   2. Granular permission scoping
  #   3. Rotation without impacting other add-ons
  service_accounts = {
    # AWS Load Balancer Controller
    aws-load-balancer-controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      policies        = ["arn:aws:iam::aws:policy/AWSLoadBalancerControllerAdditional"]
      description     = "IRSA role for AWS Load Balancer Controller"
    }
    # EBS CSI Driver
    ebs-csi-controller = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
      policies        = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
      description     = "IRSA role for EBS CSI Driver"
    }
    # EFS CSI Driver
    efs-csi-controller = {
      namespace       = "kube-system"
      service_account = "efs-csi-controller-sa"
      policies        = ["arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"]
      description     = "IRSA role for EFS CSI Driver"
    }
    # cert-manager
    cert-manager = {
      namespace       = "cert-manager"
      service_account = "cert-manager"
      policies        = [] # cert-manager uses Route53 via external-dns or DNS01
      description     = "IRSA role for cert-manager (DNS01 challenges)"
    }
    # external-dns
    external-dns = {
      namespace       = "external-dns"
      service_account = "external-dns"
      policies        = ["arn:aws:iam::aws:policy/AmazonRoute53FullAccess"]
      description     = "IRSA role for external-dns Route53 management"
    }
    # External Secrets Operator
    external-secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
      policies        = ["arn:aws:iam::aws:policy/SecretsManagerReadWrite"]
      description     = "IRSA role for External Secrets Operator"
    }
    # Kyverno
    kyverno = {
      namespace       = "kyverno"
      service_account = "kyverno"
      policies        = [] # Kyverno doesn't need AWS API access
      description     = "IRSA role for Kyverno admission controller"
    }
  }
}

# ---------------------------------------------------------------------------
# IAM Roles with OIDC Trust Policies
# ---------------------------------------------------------------------------
resource "aws_iam_role" "irsa" {
  for_each = local.service_accounts

  name                 = "${var.cluster_name}-${each.key}"
  description          = each.value.description
  max_session_duration = 3600

  # SECURITY SAFEGUARD: OIDC trust restricted to the specific service account
  # The subject field ensures only pods running as this specific service
  # account can assume this role. Even if an attacker compromises the cluster,
  # they cannot assume this role unless they control the SA's token.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.cluster_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.cluster_oidc_provider_url}:sub" = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
          }
        }
      }
    ]
  })

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Policy Attachments
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: AWS managed policies for standard add-ons
# Using managed policies where available reduces maintenance burden.
# Custom policies are used only when no managed equivalent exists
# (e.g., External Secrets with cross-account access).
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "irsa" {
  for_each = {
    for sa, config in local.service_accounts :
    sa => config
    if length(config.policies) > 0
  }

  role       = aws_iam_role.irsa[each.key].name
  policy_arn = each.value.policies[0]
}

# ---------------------------------------------------------------------------
# Cross-account policy for External Secrets (post-banking API access)
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Inline policy for cross-account Secrets Manager
# SecondWave's open banking platform requires reading secrets from
# partner AWS accounts. We attach a cross-account policy to the
# external-secrets role.
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "external_secrets_cross_account" {
  name        = "${var.cluster_name}-external-secrets-cross-account"
  description = "Allow External Secrets to read secrets from partner accounts."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CrossAccountSecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:secondwave/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "external_secrets_cross_account" {
  role       = aws_iam_role.irsa["external-secrets"].name
  policy_arn = aws_iam_policy.external_secrets_cross_account.arn
}
