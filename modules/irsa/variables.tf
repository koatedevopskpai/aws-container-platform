variable "cluster_oidc_provider_url" {
  description = "URL of the EKS cluster's OIDC provider (e.g., oidc.eks.eu-west-2.amazonaws.com/id/EXAMPLEDCID)."
  type        = string
}

variable "cluster_oidc_provider_arn" {
  description = "ARN of the EKS cluster's OIDC provider."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name for resource naming."
  type        = string
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
