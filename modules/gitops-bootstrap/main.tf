# =============================================================================
# GitOps Bootstrap Module - ArgoCD / Flux
# =============================================================================
# ARCHITECTURE DECISION: App-of-apps pattern for multi-squad autonomy
# SecondWave has 4 squads (Payments, Accounts, Onboarding, Platform).
# The app-of-apps pattern gives each squad ownership of their own
# application repository without requiring cluster-admin access:
#
#   Root App (platform team)
#   ├── Squad Apps (app-of-apps)
#   │   ├── payments-apps
#   │   ├── accounts-apps
#   │   ├── onboarding-apps
#   │   └── platform-apps
#   ├── Cluster Addons (team-managed)
#   └── Observability Stack
#
# Squads manage deployments through PRs to their repo. The platform
# team controls the root app and addons.
# =============================================================================

locals {
  # ARCHITECTURE DECISION: Conditional Helm values based on GitOps tool
  # This local selector lets the root module choose between ArgoCD and Flux
  # without conditional logic in consuming modules.
  helm_values = var.gitops_tool == "argocd" ? local.argocd_values : local.flux_values
}

# ---------------------------------------------------------------------------
# Provider configuration for this module
# ---------------------------------------------------------------------------
provider "helm" {
  alias = "gitops"
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

provider "kubectl" {
  alias = "gitops"
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

# ---------------------------------------------------------------------------
# Option A: ArgoCD
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: ArgoCD over Flux for SecondWave
# ArgoCD's Web UI provides a visual application tree that non-platform
# squad members find more accessible than Flux's CLI-only approach.
# The app-of-apps pattern is native to ArgoCD via the ApplicationSet
# controller, reducing custom scripting.
#
# Trade-off: Flux is simpler (no CRD-heavy RBAC) and has a smaller
# attack surface. For a team with strong CLI preference, Flux would
# be preferred.
# ---------------------------------------------------------------------------
locals {
  argocd_values = {
    name      = "argocd"
    namespace = "argocd"
    chart     = "argo-cd"
    repository = "https://argoproj.github.io/argo-helm"
    version   = "5.51.0"

    values = [
      <<-VALUES
      # ARCHITECTURE DECISION: Highly available ArgoCD
      # For production, we run multiple ArgoCD replicas with Redis HA.
      # This ensures GitOps reconciliation continues through node failures.
      controller:
        replicas: 2
      repoServer:
        replicas: 2
      server:
        replicas: 2
        ingress:
          enabled: true
          ingressClassName: alb
          host: "argocd.${var.domain_name}"
          annotations:
            kubernetes.io/ingress.class: alb
            alb.ingress.kubernetes.io/scheme: internal
            alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
            alb.ingress.kubernetes.io/certificate-arn: ""
      configs:
        params:
          server.insecure: false
        # SECURITY SAFEGUARD: SSO with Dex/OIDC
        # ArgoCD admin password is stored in Secrets Manager and
        # accessed via the argocd-admin-password secret.
        secret:
          argocdServerAdminPassword: ""
      redis:
        enabled: true
      ha:
        enabled: true
        redisProxy:
          enabled: true
      VALUES
    ]
  }

  flux_values = {
    name      = "flux"
    namespace = "flux-system"
    chart     = "flux2"
    repository = "https://fluxcd-community.github.io/helm-charts"
    version   = "2.12.0"

    values = [
      <<-VALUES
      # ARCHITECTURE DECISION: Flux with SOPS for secret management
      # Flux natively supports Mozilla SOPS for encrypted secrets in Git.
      # Combined with External Secrets Operator for AWS Secrets Manager,
      # this provides defense-in-depth for secret management.
      helmController:
        create: true
      imageAutomationController:
        create: true
      imageReflectionController:
        create: true
      kustomizeController:
        create: true
      notificationController:
        create: true
      sourceController:
        create: true
      CLI:
        enabled: true
      VALUES
    ]
  }
}

# ---------------------------------------------------------------------------
# Helm Release for GitOps tool
# ---------------------------------------------------------------------------
resource "helm_release" "gitops" {
  provider = helm.gitops

  name             = local.helm_values.name
  namespace        = local.helm_values.namespace
  create_namespace = true
  repository       = local.helm_values.repository
  chart            = local.helm_values.chart
  version          = local.helm_values.version

  values = local.helm_values.values

  # SECURITY SAFEGUARD: Wait for all pods to be ready
  wait          = true
  timeout       = 300
  recreate_pods = true

  depends_on = [var.argocd_admin_password_secret]
}

# ---------------------------------------------------------------------------
# App-of-Apps Bootstrap Application
# ---------------------------------------------------------------------------
# ARCHITECTURE DECISION: Bootstrap app lives in the platform repo
# The bootstrap Application/Flux Kustomization is stored alongside
# Terraform in the platform repository. It references squad repos
# via Git sources. This lets the platform team control the initial
# cluster bootstrap while squads own their applications.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "app_of_apps" {
  provider = kubectl.gitops

  yaml_body = var.gitops_tool == "argocd" ? <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: app-of-apps
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://github.com/secondwave/gitops-apps
        targetRevision: HEAD
        path: clusters/${var.cluster_name}
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
  YAML : <<-YAML
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: app-of-apps
      namespace: flux-system
    spec:
      sourceRef:
        kind: GitRepository
        name: platform
      interval: 1m
      path: ./clusters/${var.cluster_name}
      prune: true
      validation: client
  YAML

  depends_on = [helm_release.gitops]
}

data "aws_region" "current" {}
