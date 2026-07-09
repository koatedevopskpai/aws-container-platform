variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint."
  type        = string
}

variable "cluster_ca_certificate" {
  description = "CA certificate for the EKS cluster."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider."
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for node placement."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for Karpenter nodes."
  type        = list(string)
  default     = []
}

variable "instance_family" {
  description = "Allowed EC2 instance families (e.g., m5, c5, r5)."
  type        = list(string)
}

variable "instance_size" {
  description = "Allowed EC2 instance sizes (e.g., large, xlarge)."
  type        = list(string)
}

variable "cpu_limit" {
  description = "Total CPU limit for Karpenter provisioner."
  type        = string
}

variable "memory_limit" {
  description = "Total memory limit for Karpenter provisioner."
  type        = string
}

variable "ttl_seconds_after_empty" {
  description = "Seconds after becoming empty before a node is terminated."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
