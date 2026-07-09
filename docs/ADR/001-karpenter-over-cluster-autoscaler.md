# ADR-001: Karpenter over Cluster Autoscaler

## Status

Accepted

## Context

SecondWave's container platform requires automated node provisioning for Kubernetes workloads. We evaluated two approaches:

1. **Cluster Autoscaler (CA)** — the incumbent AWS solution that adjusts Auto Scaling Group sizes based on pending pods
2. **Karpenter** — AWS's next-generation node provisioning that directly launches EC2 instances

Our workloads include:
- Variable batch processing (credit scoring, fraud detection) with spiky resource demands
- Steady-state microservices (API gateways, account services) with predictable baselines
- GPU-accelerated model inference for real-time transaction monitoring

## Decision

We will use **Karpenter** for node auto-provisioning in production. Managed node groups will support dev/staging environments as a stable baseline.

## Rationale

| Factor | Karpenter | Cluster Autoscaler |
|--------|-----------|-------------------|
| Provisioning speed | Sub-second (direct EC2 API) | 3-5 min (ASG scale-up) |
| Instance diversity | Selects optimal type per pod batch | Fixed to ASG launch template |
| Cost optimization | Continuous consolidation, right-sizing | Only scales in/out, no right-sizing |
| State management | Stateless (no ASG state) | Stateful (ASG dependencies) |
| Spot integration | Native with fallback to on-demand | Requires mixed instances policy |
| GPU support | Automatic if pods request nvidia.com/gpu | Manual GPU-specific node groups |

**Specific advantages for SecondWave:**

- **Batch processing cost savings:** Karpenter's consolidation replaces underutilized nodes with smaller instances, reducing EC2 spend by ~30% based on similar migrations at comparable fintechs.
- **Fraud detection latency:** Karpenter provisions GPU instances for model inference in <10 seconds vs 3-5 minutes with CA. This directly impacts fraud prevention SLA (target: <100ms transaction scoring).
- **Operational simplicity:** No ASG management. Node failures are replaced individually, not as a group.

## Trade-offs

- **Maturity:** Karpenter is newer (GA 2023) vs CA (2017). The API is still evolving (v1beta1 NodePool).
- **Operational expertise:** Team needs Karpenter-specific knowledge for troubleshooting.
- **Cost reporting:** No ASG-based cost allocation; need custom tags for chargeback.

## Consequences

1. Node groups will be marked with `CriticalAddonsOnly: "true"` taint for system components
2. Karpenter NodePool will handle all other workloads
3. Team will monitor Karpenter metrics (pending pods, node claims) via CloudWatch
4. Weekly Karpenter version upgrades during maintenance windows
