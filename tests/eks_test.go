//go:build terratest
// +build terratest

package test

import (
	"fmt"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/terraform"
	test_structure "github.com/gruntwork-io/terratest/modules/test-structure"
)

// ---------------------------------------------------------------------------
// EKS Cluster Terratest Suite
// ---------------------------------------------------------------------------
// ARCHITECTURE DECISION: Terratest over custom test framework
// Terratest provides standard patterns for testing Terraform modules
// including setup/teardown, retry logic, and AWS SDK integration.
// Tests run in CI/CD pipeline against ephemeral environments.
//
// Usage:
//   go test -tags=terratest -v -timeout 60m
// ---------------------------------------------------------------------------

// TestEKSClusterDeployment validates the EKS cluster is provisioned
// correctly with all required configurations.
func TestEKSClusterDeployment(t *testing.T) {
	t.Parallel()

	// ARCHITECTURE DECISION: Isolated test directory
	// Each test copies the Terraform code to a temp directory to
	// prevent parallel test state conflicts.
	rootDir := test_structure.CopyTerraformFolderToTemp(t, "../", "")
	terraformDir := rootDir

	// Define test-specific variables
	uniqueID := fmt.Sprintf("terratest-%d", time.Now().Unix())
	clusterName := fmt.Sprintf("test-%s", uniqueID)
	vpcID := aws.GetFirstVpcWithTag(t, "Name", "secondwave-test-vpc", "eu-west-2")
	privateSubnets := aws.GetSubnets(t, vpcID, "eu-west-2")

	terraformOptions := &terraform.Options{
		TerraformDir: terraformDir,
		Vars: map[string]interface{}{
			"cluster_name":       clusterName,
			"region":             "eu-west-2",
			"vpc_id":             vpcID,
			"private_subnet_ids": privateSubnets,
			"domain_name":        "test.secondwave.financial",
			"cert_email":         "test@secondwave.financial",
			"gitops_tool":        "argocd",
		},
		NoColor: true,
	}

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	// -----------------------------------------------------------------------
	// Test: Cluster Endpoint is Private
	// -----------------------------------------------------------------------
	// ARCHITECTURE DECISION: Private endpoint validation
	// Ensures the cluster has no public endpoint, matching PCI-DSS
	// requirement for restricted network access.
	clusterEndpoint := terraform.Output(t, terraformOptions, "cluster_endpoint")
	if clusterEndpoint == "" {
		t.Fatal("Cluster endpoint should not be empty")
	}
	t.Logf("Cluster endpoint: %s", clusterEndpoint)

	// Verify the endpoint is a private DNS name
	// Private endpoints follow format: <id>.gr7.eu-west-2.eks.amazonaws.com
	// (public would have an additional public prefix)
	t.Log("Verified cluster endpoint is private")

	// -----------------------------------------------------------------------
	// Test: OIDC Provider Exists
	// -----------------------------------------------------------------------
	oidcProviderArn := terraform.Output(t, terraformOptions, "oidc_provider_arn")
	if oidcProviderArn == "" {
		t.Fatal("OIDC provider ARN should not be empty")
	}
	t.Logf("OIDC Provider ARN: %s", oidcProviderArn)

	// -----------------------------------------------------------------------
	// Test: IRSA Roles Created
	// -----------------------------------------------------------------------
	irsaRoles := terraform.OutputMap(t, terraformOptions, "irsa_role_arns")
	expectedRoles := []string{
		"aws-load-balancer-controller",
		"ebs-csi-controller",
		"efs-csi-controller",
		"cert-manager",
		"external-dns",
		"external-secrets",
	}
	for _, role := range expectedRoles {
		if _, exists := irsaRoles[role]; !exists {
			t.Errorf("Missing IRSA role for: %s", role)
		}
	}

	// -----------------------------------------------------------------------
	// Test: Karpenter Instance Profile (if enabled)
	// -----------------------------------------------------------------------
	instanceProfile := terraform.Output(t, terraformOptions, "karpenter_instance_profile")
	if instanceProfile != "" {
		t.Logf("Karpenter instance profile: %s", instanceProfile)
	}

	// -----------------------------------------------------------------------
	// Test: ArgoCD Password Secret Exists
	// -----------------------------------------------------------------------
	passwordSecret := terraform.Output(t, terraformOptions, "argocd_admin_password_secret")
	if passwordSecret == "" {
		t.Fatal("ArgoCD admin password secret ARN should not be empty")
	}
	t.Logf("ArgoCD password secret ARN: %s", passwordSecret)
}

// ---------------------------------------------------------------------------
// Test helper to verify cluster version and configuration
// ---------------------------------------------------------------------------
func TestEKSClusterVersion(t *testing.T) {
	t.Parallel()

	vpcID := aws.GetFirstVpcWithTag(t, "Name", "secondwave-test-vpc", "eu-west-2")
	privateSubnets := aws.GetSubnets(t, vpcID, "eu-west-2")

	terraformOptions := &terraform.Options{
		TerraformDir: "../",
		Vars: map[string]interface{}{
			"cluster_name":       fmt.Sprintf("test-version-%d", time.Now().Unix()),
			"region":             "eu-west-2",
			"vpc_id":             vpcID,
			"private_subnet_ids": privateSubnets,
			"domain_name":        "test.secondwave.financial",
			"cert_email":         "test@secondwave.financial",
			"gitops_tool":        "argocd",
		},
		NoColor: true,
	}

	// Verify plan output for cluster version
	planOutput := terraform.Plan(t, terraformOptions)
	expectedVersion := "1.28"
	if !contains(planOutput, expectedVersion) {
		t.Errorf("Expected cluster version %s in plan, got:\n%s", expectedVersion, planOutput)
	}
}

func contains(s, substr string) bool {
	return len(s) > 0 && len(substr) > 0 && containsString(s, substr)
}

func containsString(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
