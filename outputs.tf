# ---------------------------------------------------------------------
# ARCHITECTURE DECISION: Exposing cluster outputs for CI/CD consumption
# These outputs feed downstream pipelines and squad GitOps repositories.
# Sensitive outputs (kubeconfig, admin password) are marked `sensitive`
# to prevent display in plan/apply output and CI logs.
# ---------------------------------------------------------------------

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint (private, VPC-only)."
  value       = module.eks_cluster.cluster_endpoint
  sensitive   = false
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for authenticating with the cluster."
  value       = module.eks_cluster.cluster_ca_certificate
  sensitive   = true
}

# ARCHITECTURE DECISION: OIDC provider ARN is a non-sensitive output
# It's required by downstream modules (IRSA, Karpenter) which already
# reference it via Terraform state. Exposing the ARN doesn't create
# a security risk as it's a public identifier.
output "oidc_provider_arn" {
  description = "ARN of the cluster's OIDC provider for IRSA configuration."
  value       = module.eks_cluster.oidc_provider_arn
}

# SECURITY SAFEGUARD: Admin password marked sensitive
# ArgoCD admin password is stored in AWS Secrets Manager. We return the
# secret ARN here, not the password value. Pipelines must read from
# Secrets Manager at runtime.
output "argocd_admin_password_secret" {
  description = "ARN of the Secrets Manager secret containing ArgoCD admin password."
  value       = module.eks_cluster.argocd_admin_password_secret_arn
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster control plane."
  value       = module.eks_cluster.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID for EKS managed node groups."
  value       = module.eks_cluster.node_security_group_id
}

output "karpenter_instance_profile" {
  description = "IAM instance profile name for Karpenter-provisioned nodes."
  value       = var.karpenter_config.enabled ? module.karpenter[0].instance_profile : null
}

output "irsa_role_arns" {
  description = "Map of service account names to IAM role ARNs created via IRSA."
  value       = module.irsa.role_arns
  sensitive   = true
}
