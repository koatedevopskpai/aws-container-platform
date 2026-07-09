# ARCHITECTURE DECISION: Derived outputs from the EKS module
# We re-export the terraform-aws-eks module outputs to decouple
# downstream consumers from the module structure. If we switch from
# the community module to the AWS provider directly, consumers
# don't need to change their source references.

output "cluster_id" {
  description = "EKS cluster ID."
  value       = module.eks.cluster_id
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint (private)."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the cluster."
  value       = module.eks.cluster_certificate_authority_data
}

# ARCHITECTURE DECISION: OIDC provider ARN and URL exposed
# These are consumed by the IRSA module and Karpenter for IAM role
# trust policies. Both are public identifiers, not secrets.
output "oidc_provider_arn" {
  description = "ARN of the OIDC Identity Provider for IRSA."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC Identity Provider for IRSA."
  value       = module.eks.cluster_oidc_issuer_url
}

output "cluster_security_group_id" {
  description = "Security group ID for the EKS cluster."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID for EKS worker nodes."
  value       = module.eks.node_security_group_id
}

# SECURITY SAFEGUARD: Return secret ARN, not the password value
# The actual admin password is stored in AWS Secrets Manager.
# Consumers must use the ARN to retrieve the secret at runtime.
output "argocd_admin_password_secret_arn" {
  description = "Secrets Manager ARN for the ArgoCD admin password."
  value       = aws_secretsmanager_secret.argocd_admin_password.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for EKS secret encryption."
  value       = var.enable_cluster_encryption ? aws_kms_key.eks_secrets[0].arn : null
}
