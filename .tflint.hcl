# =============================================================================
# TFLint Configuration
# =============================================================================
# ARCHITECTURE DECISION: TFLint for Terraform linting in CI/CD
# TFLint catches: unused variables, incorrect instance types, deprecated
# syntax, and AWS provider best practice violations before terraform plan.
# =============================================================================

config {
  format = "default"

  # SECURITY SAFEGUARD: Lint all modules recursively
  module = true
}

plugin "aws" {
  enabled = true
  version = "0.26.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # ARCHITECTURE DECISION: Deep checking for EKS resources
  # These checks validate EKS-specific configurations against best practices.
  deep_check = true
}

# ---------------------------------------------------------------------------
# Rule overrides and customizations
# ---------------------------------------------------------------------------
rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_module_pinned_source" {
  enabled = true
  style = "flexible"
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}
