variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for EKS cluster."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS."
  type        = list(string)
}

variable "cluster_endpoint_private_cidrs" {
  description = "CIDRs allowed to access the private endpoint."
  type        = list(string)
}

variable "cluster_log_types" {
  description = "EKS control plane log types."
  type        = list(string)
}

variable "enable_cluster_encryption" {
  description = "Enable KMS encryption for secrets."
  type        = bool
  default     = true
}

variable "node_groups" {
  description = "Managed node group configurations."
  type = map(object({
    instance_types   = list(string)
    desired_size     = number
    min_size         = number
    max_size         = number
    disk_size        = number
    capacity_type    = string
    k8s_labels       = map(string)
    k8s_taints       = optional(list(map(string)))
  }))
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
}
