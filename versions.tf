# ARCHITECTURE DECISION: Terraform Cloud/OSS backend selection
# We use S3 + DynamoDB for state locking over Terraform Cloud to avoid per-user seat licensing costs
# in a multi-squad environment (4 squads ~ $80/mo/seat). S3 backend provides equivalent safety with
# DynamoDB for consistency checks.
#
# Provider version pinning ensures deterministic builds across CI/CD and local dev environments.
# The AWS provider is pinned to ~> 5.0 for EKS API support including pod identity agent and
# security group for pods (VPC CNI enhancements).

terraform {
  # ARCHITECTURE DECISION: Minimum Terraform version 1.5+
  # Required for config-driven remove, improved type constraints, and enhanced function support.
  # Remove blocks (removed { ... }) enable safe state migration when refactoring modules.
  required_version = ">= 1.5, < 2.0"

  # SECURITY SAFEGUARD: S3 backend with encryption at rest and DynamoDB locking
  # Server-side encryption (AES-256 or KMS) protects state files containing resource IDs,
  # connection strings, and metadata. DynamoDB prevents concurrent modification by multiple
  # pipelines or engineers.
  #
  # backend "s3" {
  #   bucket         = "secondwave-terraform-state"
  #   key            = "container-platform/terraform.tfstate"
  #   region         = "eu-west-2"
  #   encrypt        = true
  #   kms_key_id     = "arn:aws:kms:eu-west-2:123456789012:key/terraform-state-key"
  #   dynamodb_table = "secondwave-terraform-locks"
  # }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # ARCHITECTURE DECISION: Separate helm, kubernetes, kubectl providers
    # We use the helm provider for add-on installation (ALB controller, cert-manager, etc.)
    # because Terraform's helm_release handles values merging, dependency ordering,
    # and drift detection better than kubectl_manifest for chart-based deployments.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    # ARCHITECTURE DECISION: kubectl provider for raw YAML
    # Needed for Kyverno ClusterPolicy and ArgoCD Application CRDs that aren't Helm charts.
    # We minimize its use to only resources that cannot be expressed via helm_release.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
