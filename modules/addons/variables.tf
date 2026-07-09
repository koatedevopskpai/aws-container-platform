variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API server endpoint."
  type        = string
}

variable "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the EKS cluster."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for ALB controller."
  type        = string
  default     = ""
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA."
  type        = string
}

variable "domain_name" {
  description = "Route53 zone domain for external-dns and cert-manager."
  type        = string
}

variable "cert_email" {
  description = "Email for Let's Encrypt certificate registration."
  type        = string
}

variable "irsa_roles" {
  description = "Map of IRSA role ARNs keyed by service account name."
  type        = map(string)
  default     = {}
}

variable "enable_waf" {
  description = "Enable AWS WAF WebACL for ALB."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
