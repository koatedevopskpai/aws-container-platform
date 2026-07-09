# ARCHITECTURE DECISION: Export role ARNs for addon module consumption
# The addons module needs IAM role ARNs to annotate service accounts.
# We return a map keyed by service account name for easy lookup.

output "role_arns" {
  description = "Map of service account identifiers to IAM role ARNs."
  value = {
    for sa, config in aws_iam_role.irsa :
    sa => config.arn
  }
}

output "role_names" {
  description = "Map of service account identifiers to IAM role names."
  value = {
    for sa, config in aws_iam_role.irsa :
    sa => config.name
  }
}

output "service_account_map" {
  description = "Full map of service account configurations for reference."
  value = {
    for sa, config in local.service_accounts :
    sa => {
      namespace       = config.namespace
      service_account = config.service_account
      role_arn        = aws_iam_role.irsa[sa].arn
    }
  }
}
