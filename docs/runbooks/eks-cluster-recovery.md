# EKS Cluster Recovery Runbook

**Target RTO:** 4 hours
**Target RPO:** 1 hour (state stored in RDS/DynamoDB/S3, not on cluster)

## Scope

This runbook covers recovery from:
- EKS control plane failure (API server unavailable)
- etcd data corruption
- Accidental cluster deletion
- Regional AWS outage

## Prerequisites

- AWS Console access with `AdministratorAccess` or equivalent
- Terraform state file (S3) accessible and uncorrupted
- `kubectl`, `aws` CLI, `terraform` installed on recovery workstation
- VPN/Direct Connect connection to VPC

## Recovery Steps

### 1. Assess the Failure

```bash
# Check control plane status
aws eks describe-cluster --name secondwave-prod-euw2 --region eu-west-2

# Check if cluster exists at all
aws eks list-clusters --region eu-west-2

# Check CloudWatch metrics for API server
aws cloudwatch get-metric-statistics \
  --namespace AWS/EKS \
  --metric-name cluster_failed_request_count \
  --dimensions Name=cluster_name,Value=secondwave-prod-euw2 \
  --start-time $(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Sum
```

### 2. If Control Plane is Degraded (Not Deleted)

Wait 15 minutes for AWS auto-recovery. EKS control plane runs across 3 AZs and auto-heals.

```bash
# If API server is responsive but slow, check node status
kubectl get nodes --request-timeout=30s

# Check core DNS
kubectl -n kube-system get pods -l k8s-app=kube-dns

# Restart CoreDNS if needed
kubectl -n kube-system rollout restart deployment/coredns
```

**Escalation:** If >30 minutes, contact AWS Support (Enterprise Support, severity: high).

### 3. If Cluster is Deleted (Accidental)

#### 3.1 Restore Terraform State

```bash
# Navigate to Terraform directory
cd aws/container-platform

# Pull latest state from S3 (if versioning enabled)
aws s3api get-object-version-id \
  --bucket secondwave-terraform-state-123456789012 \
  --key prod/container-platform/terraform.tfstate \
  --version-id <latest-version-before-deletion> \
  terraform.tfstate

# Initialize and plan
terraform init
terraform plan -var-file=terraform.tfvars
```

#### 3.2 Recreate Cluster

```bash
# Apply with care — this will recreate everything
terraform apply -var-file=terraform.tfvars
```

**Critical:** Before applying, verify:
- [ ] VPC and subnets still exist (they should, managed separately)
- [ ] IAM roles were not deleted (if so, re-run IRSA module)
- [ ] ACM certificates still valid

#### 3.3 Restore Workloads

EKS does not manage application state. Workloads are defined in GitOps:

```bash
# ArgoCD will auto-sync and recreate all applications
argocd app sync app-of-apps

# Verify application status
argocd app list
```

### 4. Verify Recovery

```bash
# Check cluster health
aws eks describe-cluster --name secondwave-prod-euw2
kubectl cluster-info

# Verify add-ons
kubectl -n kube-system get pods
kubectl -n kyverno get pods
kubectl -n cert-manager get pods

# Verify application health
kubectl get pods --all-namespaces | grep -v Running | grep -v Completed
```

## Post-Recovery

1. **Root cause analysis** — Check CloudTrail for who deleted/modified resources
2. **Preventive measures** — Add IAM policy to prevent cluster deletion:
   ```json
   {
     "Effect": "Deny",
     "Action": "eks:DeleteCluster",
     "Resource": "*",
     "Condition": {
       "StringNotEquals": {
         "aws:PrincipalArn": "arn:aws:iam::*:role/break-glass-admin"
       }
     }
   }
   ```
3. **Update backups** — Verify Terraform state backups are current
4. **Notify squads** — Communicate recovery completion and any data loss

## Failure Modes

| Failure | Symptom | Recovery Action |
|---------|---------|----------------|
| API server down | kubectl timeout | Wait for AWS auto-recovery |
| etcd corrupted | API server crash loop | AWS handles etcd (managed) |
| Cluster deleted | describe returns NotFound | Terraform re-apply |
| Node group failure | All nodes NotReady | Karpenter replaces automatically |
| Add-on failure | Pods CrashLoopBackOff | Helm re-apply from Terraform |
