variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint."
  type        = string
}

variable "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the EKS cluster."
  type        = string
}

variable "gitops_tool" {
  description = "GitOps tool selection: argocd or flux."
  type        = string
}

variable "domain_name" {
  description = "Route53 zone domain for ArgoCD ingress."
  type        = string
}

variable "cert_email" {
  description = "Email for Let's Encrypt certificate registration."
  type        = string
}

variable "argocd_admin_password_secret" {
  description = "ARN of the Secrets Manager secret for ArgoCD admin password."
  type        = string
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
