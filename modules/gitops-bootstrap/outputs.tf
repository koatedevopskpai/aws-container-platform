output "gitops_namespace" {
  description = "Namespace where the GitOps tool is installed."
  value       = var.gitops_tool == "argocd" ? "argocd" : "flux-system"
}

output "gitops_tool" {
  description = "The GitOps tool deployed (argocd or flux)."
  value       = var.gitops_tool
}

output "helm_release_name" {
  description = "Name of the GitOps Helm release."
  value       = helm_release.gitops.name
}
