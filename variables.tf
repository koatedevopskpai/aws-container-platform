# ---------------------------------------------------------------------
# ARCHITECTURE DECISION: Variable-driven platform configuration
# All cluster-defining parameters are surfaced as variables to enable
# environment-specific tfvars (dev/staging/prod) without forking modules.
# This supports SecondWave's 4-squad model where each squad's namespace
# is isolated but the cluster is shared.
# ---------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster name. Must be unique within the AWS account/region."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,99}$", var.cluster_name))
    error_message = "Cluster name must start with a letter, contain only alphanumerics and hyphens, max 100 chars."
  }
}

variable "region" {
  description = "AWS region for all resources. London (eu-west-2) for SecondWave's primary residency requirement."
  type        = string
  default     = "eu-west-2"
}

# SECURITY SAFEGUARD: VPC and subnets are inputs not created here
# Network topology (TGW, NAT, public/private subnets) is managed by the
# networking team's Terraform. Accepting vpc_id prevents accidental
# VPC destruction from this module and enforces separation of concerns.
variable "vpc_id" {
  description = "VPC ID where EKS will be deployed. Must have private subnets with NAT Gateway egress."
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EKS cluster and node groups. Minimum 2 for HA across AZs."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets across different AZs are required for HA."
  }
}

# ARCHITECTURE DECISION: Map of node groups instead of separate variables
# Using a map with environments as keys allows DRY configuration and
# prevents accidental misconfiguration from missing variables.
# Spot is default for dev/staging; prod uses on-demand for reliability.
variable "node_groups" {
  description = "Managed node group configuration per environment tier."
  type = map(object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = number
    capacity_type  = string # SPOT or ON_DEMAND
    k8s_labels     = map(string)
    k8s_taints     = optional(list(map(string)))
  }))
  default = {
    dev = {
      instance_types = ["t3.medium", "t3a.medium"]
      desired_size   = 2
      min_size       = 1
      max_size       = 5
      disk_size      = 50
      capacity_type  = "SPOT"
      k8s_labels     = { "node-lifecycle" = "spot", "environment" = "dev" }
      k8s_taints     = null
    }
    staging = {
      instance_types = ["m5.large", "m5a.large"]
      desired_size   = 2
      min_size       = 1
      max_size       = 8
      disk_size      = 100
      capacity_type  = "SPOT"
      k8s_labels     = { "node-lifecycle" = "spot", "environment" = "staging" }
      k8s_taints     = null
    }
    prod = {
      instance_types = ["m5.xlarge", "m5a.xlarge"]
      desired_size   = 3
      min_size       = 3
      max_size       = 15
      disk_size      = 200
      capacity_type  = "ON_DEMAND"
      k8s_labels     = { "node-lifecycle" = "on-demand", "environment" = "prod" }
      k8s_taints = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      ]
    }
  }
}

# ARCHITECTURE DECISION: Karpenter config as object for flexibility
# Encapsulating Karpenter settings in a single object avoids variable sprawl
# and lets us pass the entire config to the karpenter module cleanly.
variable "karpenter_config" {
  description = "Karpenter provisioner configuration for group-less auto-scaling in prod."
  type = object({
    enabled                       = bool
    subnet_selector_terms         = list(map(string))
    security_group_selector_terms = list(map(string))
    instance_family               = list(string)
    instance_size                 = list(string)
    cpu_limit                     = string
    memory_limit                  = string
    ttl_seconds_after_empty       = optional(number, 30)
  })
  default = {
    enabled                       = true
    subnet_selector_terms         = [{ "karpenter.sh/discovery" = "secondwave" }]
    security_group_selector_terms = [{ "karpenter.sh/discovery" = "secondwave" }]
    instance_family               = ["m5", "m5a", "m6i", "c5", "c5a", "r5", "r5a"]
    instance_size                 = ["large", "xlarge", "2xlarge"]
    cpu_limit                     = "1000"
    memory_limit                  = "1000Gi"
    ttl_seconds_after_empty       = 30
  }
}

variable "gitops_tool" {
  description = "GitOps tool selection. 'argocd' or 'flux'. ArgoCD preferred for multi-squad UI/UX."
  type        = string
  default     = "argocd"

  validation {
    condition     = contains(["argocd", "flux"], var.gitops_tool)
    error_message = "gitops_tool must be 'argocd' or 'flux'."
  }
}

variable "domain_name" {
  description = "Route53 zone domain for external-dns and cert-manager (e.g., secondwave.financial)."
  type        = string
}

variable "cert_email" {
  description = "Email for Let's Encrypt / ACME certificate registration."
  type        = string
}

# SECURITY SAFEGUARD: Allowed CIDRs for cluster access
# Default restricts to RFC1918 addresses (VPC internal). Any expansion
# must go through change review. No 0.0.0.0/0 allowed.
variable "cluster_endpoint_private_cidrs" {
  description = "CIDR blocks allowed to access the EKS private endpoint."
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
    Platform    = "container-platform"
    Project     = "secondwave"
  }
}

# ARCHITECTURE DECISION: KMS key flag
# Encrypting EKS secrets at rest with KMS is a PCI-DSS requirement for
# SecondWave's open banking workloads. This flag enables the encryption config.
variable "enable_cluster_encryption" {
  description = "Enable KMS encryption for EKS secrets at rest (required for PCI-DSS)."
  type        = bool
  default     = true
}

variable "cluster_log_types" {
  description = "EKS control plane log types to enable. All recommended for audit compliance."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "enable_waf" {
  description = "Deploy AWS WAF WebACL and associate with ALB Ingresses."
  type        = bool
  default     = true
}

variable "enable_image_scanning" {
  description = "Enable ECR Inspector continuous scanning for container images."
  type        = bool
  default     = true
}
