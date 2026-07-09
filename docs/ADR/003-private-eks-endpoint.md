# ADR-003: Private EKS Endpoint (No Public Access)

## Status

Accepted

## Context

SecondWave's EKS cluster provides a Kubernetes API endpoint. AWS allows two access modes:

1. **Public endpoint** — API server accessible via public internet (with optional CIDR restrictions)
2. **Private endpoint** — API server accessible only within the VPC via AWS PrivateLink

Our compliance requirements:
- **PCI-DSS:** Requirement 1.3 — restrict inbound/outbound traffic to only necessary
- **GDPR:** Article 32 — appropriate technical measures for data protection
- **SOC2:** CC6.1 — logical and physical access controls
- **Open Banking Standard:** API security requirements

## Decision

The EKS cluster will have **public endpoint disabled** and **private endpoint enabled only**.

## Rationale

| Factor | Private Endpoint | Public Endpoint |
|--------|-----------------|-----------------|
| Attack surface | VPC-internal only, no internet exposure | Internet-accessible, even with CIDR restrictions |
| DDoS protection | Implicit (not reachable) | Requires WAF/shield |
| Compliance alignment | PCI-DSS req 1.3, SOC2 CC6.1 | Requires compensating controls |
| Operational overhead | Requires VPN/Direct Connect for admin access | Direct kubectl from any location |
| Security group control | VPC security groups | CIDR-based (less granular) |

**Security analysis of public endpoint risks:**

1. **Zero-day in Kubernetes API server:** A public endpoint is reachable by anyone who can guess/scan the endpoint DNS name. PrivateLink makes this unreachable from the internet.
2. **Credential stuffing:** Even with OIDC, a public endpoint allows brute-force authentication attempts from anywhere.
3. **MITM on TLS:** PrivateLink traffic stays within AWS network, eliminating risks from public internet TLS interception.

**Specific advantages for SecondWave:**

- **Open Banking compliance:** The Open Banking Standard requires API security above baseline. A private endpoint demonstrates defense-in-depth.
- **Penetration testing scope:** A private endpoint reduces the external attack surface, focusing pen-testing effort on application-layer vulnerabilities.

## Trade-offs

- **Developer experience:** Engineers must be on VPN or use a bastion host for kubectl access. This adds ~5 minutes to onboarding.
- **CI/CD complexity:** Pipelines must run within the VPC (GitHub Actions runners in VPC, or self-hosted runners) to reach the API server.
- **Cost:** VPC endpoints incur hourly charges (~$7/month per AZ). Bastion host adds ~$15/month.

## Consequences

1. All kubectl access requires AWS VPN Client or Session Manager (SSM) port forwarding
2. CI/CD pipelines use OIDC-authenticated `aws eks update-kubeconfig` from within VPC
3. CloudWatch Logs agent ships API server audit logs to centralized SIEM
4. Bastion host is ephemeral (auto-stopped outside business hours) to reduce attack surface
5. Emergency break-glass access documented in runbook (AWS Console + CloudShell within VPC)
