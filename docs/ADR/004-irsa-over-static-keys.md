# ADR-004: IAM Roles for Service Accounts (IRSA) over Static Credentials

## Status

Accepted

## Context

Kubernetes pods running on SecondWave's EKS cluster need to authenticate to AWS services:
- DynamoDB (account ledger, transaction store)
- SQS (event-driven processing)
- S3 (document storage, data lake)
- Secrets Manager (configuration, API keys)
- Route53 (DNS management via external-dns)

Four approaches were evaluated:

1. **Static AWS credentials in Kubernetes Secrets** — access key + secret key stored in Secret objects
2. **Node instance profile** — all pods on a node share the node's IAM role
3. **kube2iam/kiam** — DaemonSet that proxies EC2 metadata API with per-pod role assumption
4. **IRSA** — OIDC-federated IAM roles via service account annotations

## Decision

All pod-to-AWS authentication will use **IAM Roles for Service Accounts (IRSA)** .

## Rationale

| Factor | IRSA | Static Secrets | Instance Profile | kube2iam |
|--------|------|---------------|-----------------|----------|
| Credential storage | None (OIDC token exchange) | etcd (plaintext or base64) | Node instance metadata | Node instance metadata |
| Per-pod identity | Yes (per SA) | Yes (per SA) | No (all pods share) | Yes (per pod annotation) |
| Credential rotation | Automatic (token expiry) | Manual | Automatic (instance role) | Automatic |
| Audit trail | OIDC subject in CloudTrail | None (shared key) | Node ID only | Pod annotation |
| Management overhead | Once per SA | Per deployment | None | DaemonSet maintenance |

**SECURITY SAFEGUARD: Keyless authentication**

IRSA pods never hold AWS credentials. The authentication flow is:

```
1. Pod gets a signed Kubernetes JWT (TokenReview API)
2. Pod presents JWT to STS (sts:AssumeRoleWithWebIdentity)
3. STS validates JWT against OIDC provider (EKS)
4. STS returns temporary credentials (1h expiry)
5. AWS SDK caches and auto-refreshes credentials
```

At no point do AWS access keys exist on the pod filesystem, in memory as a string, or in etcd. This eliminates:
- Secret exfiltration via `kubectl get secret`
- Credential leakage in log files
- Accidental commit of credentials to Git
- Lateral movement via shared credentials

## Trade-offs

- **Complexity:** OIDC configuration adds initial setup complexity. Must create OIDC provider, IAM roles, and annotate service accounts.
- **Token expiry:** Pods must handle credential refresh (AWS SDKs handle this automatically).
- **Namespace constraint:** The service account must exist in the same namespace as the pod.

## Consequences

1. Every pod that accesses AWS APIs must use a dedicated service account with IRSA annotation
2. Platform team creates IAM roles for each add-on; squad leads request roles for their applications
3. IRSA roles follow least-privilege: each role scoped to specific actions and resources
4. No IAM users or access keys used for pod authentication
5. CI/CD pipeline uses OIDC for Terraform auth, consistent with the IRSA pattern
