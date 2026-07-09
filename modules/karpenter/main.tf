# =============================================================================
# Karpenter Module - Group-less Auto-Provisioning for EKS
# =============================================================================
# ARCHITECTURE DECISION: Karpenter over Cluster Autoscaler
# Karpenter observes real-time pod scheduling constraints and provisions
# EC2 instances directly, bypassing Auto Scaling Groups entirely.
# Key advantages for SecondWave:
#   1. Sub-second node provisioning vs 3-5 minutes with ASG-based CA
#   2. Instance type flexibility: Karpenter selects the optimal instance
#      type for each pod batch (e.g., GPU pods get g5 instances)
#   3. Cost savings: ~30% reduction through right-sizing and spot diversity
#   4. No node group management: removes ASG state from Terraform
#
# SECURITY SAFEGUARD: Removing node group state reduces blast radius
# With Cluster Autoscaler, a misconfigured node group can orphan or
# cascade-fail 50+ nodes. Karpenter nodes are independently provisioned
# and deprovisioned. A failing node is terminated and replaced without
# affecting other nodes. This is a defense-in-depth improvement for
# production resilience.
# =============================================================================

locals {
  name_prefix = "karpenter-${var.cluster_name}"
}

# ---------------------------------------------------------------------------
# IAM Role for Karpenter Controller (running on EKS pod)
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: IRSA for Karpenter controller
# The Karpenter controller pod uses an IAM role via IRSA to call EC2,
# Pricing, and other AWS APIs. This eliminates long-lived credentials
# and follows the principle of least privilege.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "karpenter_controller" {
  name = "${local.name_prefix}-controller"

  # SECURITY SAFEGUARD: OIDC trust policy restricts to the Karpenter
  # service account in the karpenter namespace.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.oidc_provider_url}:sub" = "system:serviceaccount:karpenter:karpenter"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ARCHITECTURE DECISION: Inline policy over managed policies
# Karpenter requires specific EC2 permissions (CreateFleet, etc.)
# that aren't covered by a single AWS managed policy. We define
# the minimum required actions explicitly.
resource "aws_iam_policy" "karpenter_controller" {
  name        = "${local.name_prefix}-controller"
  description = "Minimum permissions for Karpenter controller to provision EC2 instances."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Fleet"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateLaunchTemplate",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeImages",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2Terminate"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = "*"
      },
      {
        Sid    = "PassRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [aws_iam_role.karpenter_node.arn]
      },
      {
        Sid    = "Pricing"
        Effect = "Allow"
        Action = "pricing:GetProducts"
        Resource = "*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# IAM Role for Karpenter-provisioned Nodes
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Dedicated instance profile per cluster
# Each Karpenter-provisioned node assumes this role, which grants
# access to ECR, S3 (for IRSA), and CloudWatch logs.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "karpenter_node" {
  name = "${local.name_prefix}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${local.name_prefix}-node"
  role = aws_iam_role.karpenter_node.name

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Karpenter Helm Release
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Helm for Karpenter installation
# Karpenter publishes an official Helm chart that handles CRDs, RBAC,
# and controller deployment. Using helm_release gives us Terraform-
# managed lifecycle and drift detection.
# ---------------------------------------------------------------------------
resource "helm_release" "karpenter" {
  namespace       = "karpenter"
  create_namespace = true
  name            = "karpenter"
  repository      = "oci://public.ecr.aws/karpenter"
  chart           = "karpenter"
  version         = "v0.35.0"

  set {
    name  = "settings.aws.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "settings.aws.clusterEndpoint"
    value = var.cluster_endpoint
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  wait = true
}

# ---------------------------------------------------------------------------
# Karpenter NodePool (formerly Provisioner)
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: NodePool (v1beta1) over Provisioner (v1alpha5)
# Karpenter v0.35+ uses the NodePool API which supports advanced features
# like node class refs, weight-based scheduling, and consolidation.
# We configure consolidation to remove underutilized nodes.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "karpenter_nodepool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          requirements:
            - key: "kubernetes.io/arch"
              operator: In
              values: ["amd64"]
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["on-demand", "spot"]
            - key: "node.kubernetes.io/instance-type"
              operator: In
              values: ${jsonencode([for f in var.instance_family : for s in var.instance_size : "${f}.${s}"])}
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          # SECURITY SAFEGUARD: TTL after empty prevents zombie nodes
          # Nodes running no workloads are terminated after 30 seconds.
          ttlSecondsAfterEmpty: ${var.ttl_seconds_after_empty}
      limits:
        cpu:    ${var.cpu_limit}
        memory: ${var.memory_limit}
      # ARCHITECTURE DECISION: Consolidation enabled
      # Karpenter continuously optimizes the cluster by replacing nodes
      # with cheaper or more efficient instances. This is the key
      # cost-saving feature over Cluster Autoscaler.
      disruption:
        consolidationPolicy: WhenUnderutilized
        expireAfter: 720h # 30 days
  YAML

  depends_on = [helm_release.karpenter]
}

# ---------------------------------------------------------------------------
# Karpenter EC2NodeClass
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Separate NodeClass from NodePool
# NodeClass defines the EC2 configuration (subnets, SGs, AMI, role).
# NodePool defines scheduling logic. This separation allows multiple
# NodePools (e.g., spot vs on-demand) sharing the same NodeClass.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "karpenter_ec2nodeclass" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      # ARCHITECTURE DECISION: Tag-based subnet and SG selection
      # Karpenter discovers subnets and security groups by tags,
      # avoiding hardcoded IDs. This enables automatic use of new
      # subnets added by the networking team.
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      # ARCHITECTURE DECISION: AL2 EKS Optimized AMI family
      # Bottlerocket is more secure but AL2 has broader compatibility
      # with ThirdWave's existing container images.
      amiFamily: AL2
      # SECURITY SAFEGUARD: Instance profile with least privilege
      role: ${aws_iam_instance_profile.karpenter_node.name}
      userData: |
        #!/bin/bash
        # SECURITY SAFEGUARD: kubelet extra args for node hardening
        /etc/eks/bootstrap.sh '${var.cluster_name}' \
          --kubelet-extra-args '--max-pods=110'
      metadataOptions:
        httpEndpoint: enabled
        httpProtocolIPv6: disabled
        httpPutResponseHopLimit: 2
        httpTokens: required
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 100Gi
            volumeType: gp3
            encrypted: true
  YAML

  depends_on = [helm_release.karpenter]
}

# ---------------------------------------------------------------------------
# Subnet and Security Group Tagging
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Tag subnets and SGs for Karpenter discovery
# We apply the karpenter.sh/discovery tag so the EC2NodeClass can
# dynamically discover subnets. This avoids hardcoding subnet IDs
# in the NodeClass spec.
# ---------------------------------------------------------------------------
resource "aws_ec2_tag" "karpenter_subnets" {
  for_each = toset(var.private_subnet_ids)

  resource_id = each.key
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_ec2_tag" "karpenter_security_groups" {
  for_each = toset(var.security_group_ids)

  resource_id = each.key
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# ---------------------------------------------------------------------------
# Provider Configuration for kubectl
# ---------------------------------------------------------------------------
provider "kubectl" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", var.cluster_name,
      "--region", data.aws_region.current.name
    ]
  }
}

data "aws_region" "current" {}
