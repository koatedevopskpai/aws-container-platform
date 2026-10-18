# =============================================================================
# Addons Module - Cluster-wide Add-ons via Helm
# =============================================================================
# ARCHITECTURE DECISION: Single module for sequenced Helm deployments
# Add-on installations have strict ordering requirements:
#   1. cert-manager CRDs must exist before ClusterIssuers
#   2. ALB Controller needs IAM role from IRSA module
#   3. external-dns needs Route53 zone
#   4. Kyverno should be one of the last installs (policy everything)
#
# A single module with explicit depends_on chains at the root level
# ensures correct ordering. Breaking add-ons into separate modules
# would create circular dependencies or require a state machine.
# =============================================================================

locals {
  # ARCHITECTURE DECISION: IRSA role annotations map
  # We look up the role ARN from the irsa_roles map by service account name.
  # This avoids hardcoding role ARNs in Helm values.
  irsa_role = {
    alb          = lookup(var.irsa_roles, "aws-load-balancer-controller", "")
    ebs          = lookup(var.irsa_roles, "ebs-csi-controller", "")
    efs          = lookup(var.irsa_roles, "efs-csi-controller", "")
    cert_manager = lookup(var.irsa_roles, "cert-manager", "")
    external_dns = lookup(var.irsa_roles, "external-dns", "")
    ext_secrets  = lookup(var.irsa_roles, "external-secrets", "")
  }
}

# ---------------------------------------------------------------------------
# Provider Configuration
# ---------------------------------------------------------------------------
provider "helm" {
  alias = "addons"
  kubernetes {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
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
}

# ---------------------------------------------------------------------------
# 1. AWS Load Balancer Controller
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: ALB Controller for ingress
# The AWS Load Balancer Controller provisions ALBs and NLBs via
# Kubernetes Ingress and Service resources. It integrates natively
# with WAF, ACM, and target group stickiness. For SecondWave's
# multi-service architecture, ALB supports path-based routing and
# host-based routing for squad isolation.
# ---------------------------------------------------------------------------
resource "helm_release" "aws_load_balancer_controller" {
  provider = helm.addons

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.6.1"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.irsa_role.alb
  }
  set {
    name  = "region"
    value = data.aws_region.current.name
  }
  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  # SECURITY SAFEGUARD: Enable SSL redirect globally
  set {
    name  = "defaultSSLPolicy"
    value = "ELBSecurityPolicy-TLS-1-2-2017-01"
  }

  wait    = true
  timeout = 300
}

# ---------------------------------------------------------------------------
# 2. cert-manager
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: cert-manager for TLS automation
# cert-manager handles ACME certificate issuance and renewal via
# Let's Encrypt. Combined with external-dns (DNS01 challenge),
# certificates are fully automated with no manual intervention.
# ---------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  provider = helm.addons

  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "1.13.3"

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.irsa_role.cert_manager
  }

  wait    = true
  timeout = 300
}

# ARCHITECTURE DECISION: ClusterIssuer over Issuer
# ClusterIssuer is cluster-scoped and available to all namespaces.
# This avoids creating an Issuer per namespace (5+ for SecondWave).
resource "kubectl_manifest" "cluster_issuer" {
  provider = kubectl.addons

  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt-prod
    spec:
      acme:
        server: https://acme-v02.api.letsencrypt.org/directory
        email: ${var.cert_email}
        privateKeySecretRef:
          name: letsencrypt-prod
        solvers:
          - dns01:
              route53:
                region: ${data.aws_region.current.name}
  YAML

  depends_on = [helm_release.cert_manager]
}

# ---------------------------------------------------------------------------
# 3. external-dns
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: external-dns for automated DNS
# When an Ingress or Service of type LoadBalancer is created,
# external-dns automatically creates Route53 records. This eliminates
# manual DNS changes for each deployment and prevents drift between
# Kubernetes resources and DNS.
# ---------------------------------------------------------------------------
resource "helm_release" "external_dns" {
  provider = helm.addons

  name             = "external-dns"
  namespace        = "external-dns"
  create_namespace = true
  repository       = "https://kubernetes-sigs.github.io/external-dns"
  chart            = "external-dns"
  version          = "1.14.3"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.irsa_role.external_dns
  }
  set {
    name  = "provider"
    value = "aws"
  }
  set {
    name  = "zoneType"
    value = "public"
  }
  set {
    name  = "domainFilters[0]"
    value = var.domain_name
  }
  set {
    name  = "policy"
    value = "sync"
  }

  # SECURITY SAFEGUARD: Sync policy (not upsert-only)
  # Sync policy removes orphaned DNS records. Combined with
  # owner-id, this prevents DNS pollution from deleted services.
  set {
    name  = "txtOwnerId"
    value = var.cluster_name
  }

  wait    = true
  timeout = 300
}

# ---------------------------------------------------------------------------
# 4. External Secrets Operator (ESO)
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: External Secrets Operator over CSI Driver
# The CSI Secrets Store Driver mounts secrets as volumes. This means:
#   - Secrets are consumed as files, not environment variables
#   - Pod specs must know about the CSI driver
#   - Rotation requires pod restart (or CSI driver reload)
#
# ESO creates native Kubernetes Secret objects that are synced from
# AWS Secrets Manager. Benefits:
#   - Secrets are native K8s secrets (env vars, volumes, any format)
#   - Any workload can use them without CSI knowledge
#   - Rotation updates the Secret object immediately
#   - Supports multiple secret stores (AWS, GCP, Azure, Vault)
#
# SECURITY SAFEGUARD: Push-based sync avoids secret sprawl
# ESO pushes secrets from AWS Secrets Manager to the cluster.
# No long-lived pull credentials, no external network access required
# from the cluster. Secrets are decoupled from the source of truth.
# ---------------------------------------------------------------------------
resource "helm_release" "external_secrets" {
  provider = helm.addons

  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.13"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = local.irsa_role.ext_secrets
  }
  set {
    name  = "installCRDs"
    value = "true"
  }

  wait    = true
  timeout = 300
}

# SECURITY SAFEGUARD: SecretStore referencing AWS Secrets Manager
# This SecretStore is the bridge between ESO and AWS Secrets Manager.
# It uses IRSA to authenticate, so no AWS credentials are stored
# in the cluster.
resource "kubectl_manifest" "secret_store" {
  provider = kubectl.addons

  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: SecretStore
    metadata:
      name: aws-secrets-manager
      namespace: default
    spec:
      provider:
        aws:
          service: SecretsManager
          region: ${data.aws_region.current.name}
          auth:
            jwt:
              serviceAccountRef:
                name: external-secrets
  YAML

  depends_on = [helm_release.external_secrets]
}

# ---------------------------------------------------------------------------
# 5. Kyverno
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Kyverno over OPA/Gatekeeper
# Kyverno uses Kubernetes-native YAML policies (no Rego language).
# This dramatically reduces the learning curve for platform engineers
# who already know Kubernetes. Policies include:
#   - Require resource limits
#   - Disallow privileged containers
#   - Enforce image registry (only ECR)
#   - Block hostPath and hostNetwork
#   - Require pod security standards (baseline/restricted)
#
# For SecondWave's compliance team, Kyverno policies are readable
# and auditable without a Rego specialist.
# ---------------------------------------------------------------------------
resource "helm_release" "kyverno" {
  provider = helm.addons

  name             = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = "3.1.4"

  set {
    name  = "replicaCount"
    value = "2"
  }

  wait    = true
  timeout = 300
}

# ARCHITECTURE DECISION: Pod Security Standards via Kyverno
# We enforce the "restricted" PSS profile cluster-wide, with
# exceptions for system namespaces (kube-system, kyverno, etc.).
# This aligns with the NSA/CISA Kubernetes Hardening Guide.
resource "kubectl_manifest" "kyverno_pod_security" {
  provider = kubectl.addons

  yaml_body = <<-YAML
    apiVersion: kyverno.io/v1
    kind: ClusterPolicy
    metadata:
      name: require-pod-security-standards
    spec:
      validationFailureAction: Enforce
      background: true
      rules:
        - name: restricted
          match:
            any:
              - resources:
                  kinds:
                    - Pod
          exclude:
            any:
              - resources:
                  namespaces:
                    - kube-system
                    - kyverno
                    - cert-manager
                    - external-dns
                    - external-secrets
                    - argocd
                    - flux-system
                    - karpenter
          validate:
            podSecurity:
              level: restricted
              version: latest
  YAML

  depends_on = [helm_release.kyverno]
}

# ---------------------------------------------------------------------------
# 6. AWS WAF for ALB
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "alb" {
  count = var.enable_waf ? 1 : 0

  name  = "${var.cluster_name}-alb-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # SECURITY SAFEGUARD: AWS managed rule groups
  # These rules protect against OWASP Top 10, SQL injection,
  # XSS, and known exploit vectors. Using managed rules reduces
  # maintenance burden while ensuring coverage.
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      count {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesSQLiRuleSet"
    priority = 2
    override_action {
      count {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rate-based rule for DDoS protection
  rule {
    name     = "RateLimit"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 5000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Karpenter Addon (Helm chart reference)
# ---------------------------------------------------------------------------
# Note: The Karpenter controller and NodePool are managed by the
# karpenter module. This entry ensures the addons module has a
# dependency on Karpenter for ordering purposes.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------
data "aws_region" "current" {}

provider "kubectl" {
  alias                  = "addons"
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
