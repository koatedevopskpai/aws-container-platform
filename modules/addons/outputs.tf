output "alb_controller_namespace" {
  description = "Namespace where ALB controller is deployed."
  value       = helm_release.aws_load_balancer_controller.namespace
}

output "waf_web_acl_arn" {
  description = "ARN of the WAF WebACL for ALB association."
  value       = var.enable_waf ? aws_wafv2_web_acl.alb[0].arn : null
}

output "cert_manager_namespace" {
  description = "Namespace where cert-manager is deployed."
  value       = helm_release.cert_manager.namespace
}

output "kyverno_namespace" {
  description = "Namespace where Kyverno is deployed."
  value       = helm_release.kyverno.namespace
}

output "installed_addons" {
  description = "List of installed add-on Helm releases."
  value = [
    helm_release.aws_load_balancer_controller.name,
    helm_release.cert_manager.name,
    helm_release.external_dns.name,
    helm_release.external_secrets.name,
    helm_release.kyverno.name,
  ]
}
