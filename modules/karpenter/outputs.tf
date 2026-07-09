output "instance_profile" {
  description = "IAM instance profile name for Karpenter-provisioned nodes."
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "controller_role_arn" {
  description = "IAM role ARN for Karpenter controller pod."
  value       = aws_iam_role.karpenter_controller.arn
}

output "node_role_arn" {
  description = "IAM role ARN for Karpenter-provisioned nodes."
  value       = aws_iam_role.karpenter_node.arn
}

output "helm_release_name" {
  description = "Name of the Karpenter Helm release."
  value       = helm_release.karpenter.name
}
