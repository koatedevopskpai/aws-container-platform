# Karpenter Troubleshooting Runbook

## Common Issues and Resolution

### 1. Nodes Not Being Provisioned

**Symptoms:**
- Pods stuck in `Pending` state
- No new EC2 instances appearing
- Karpenter controller logs show no provisioning attempts

**Check Karpenter Health:**

```bash
# Check Karpenter controller pod status
kubectl -n karpenter get pods

# View Karpenter logs
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --tail=100

# Check for node claims
kubectl get nodeclaims
kubectl get nodepools
```

**Common Causes:**

| Cause | Check | Fix |
|-------|-------|-----|
| Insufficient instance capacity | `kubectl describe nodeclaim` shows `InsufficientInstanceCapacity` | Add more instance families to NodePool spec |
| Subnet tags missing | EC2NodeClass cannot find subnets | Verify `karpenter.sh/discovery` tag on subnets |
| Security group tags missing | EC2NodeClass cannot find SGs | Verify `karpenter.sh/discovery` tag on security groups |
| IAM role issues | Controller logs show `AccessDenied` | Verify IRSA role and instance profile |
| Resource limits reached | Karpenter NodePool limits exceeded | Check `spec.limits.cpu` and `spec.limits.memory` |

**Resolution:**

```bash
# Force re-evaluation by deleting the NodeClaim
kubectl delete nodeclaim <name>

# Or restart Karpenter controller
kubectl -n karpenter rollout restart deployment/karpenter
```

### 2. Nodes Not Being Consolidated (Scale Down)

**Symptoms:**
- Underutilized nodes persist beyond `ttlSecondsAfterEmpty`
- High EC2 costs despite low workload

**Check Consolidation:**

```bash
# Check Karpenter disruption status
kubectl get nodeclaim -o wide

# View consolidation decisions in logs
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter | grep consolidate

# Check pod disruption budgets blocking eviction
kubectl get pdb --all-namespaces
```

**Common Causes:**

| Cause | Resolution |
|-------|-----------|
| PodDisruptionBudget blocking eviction | Review PDB `maxUnavailable` settings |
| Node has critical add-ons | Ensure add-ons use `CriticalAddonsOnly` taint on node group nodes |
| Consolidation disabled | Verify `spec.disruption.consolidationPolicy: WhenUnderutilized` |
| TTLSecondsAfterEmpty too high | Reduce from default 30 to lower value |

### 3. Node Failing Health Checks

**Symptoms:**
- Node shows `NotReady` status
- Karpenter creates replacement but old node persists

**Check Node Health:**

```bash
# Describe the unhealthy node
kubectl describe node <name>

# Check Karpenter node expiry
kubectl get nodeclaim -o yaml | grep -A5 expiration
```

**Resolution:**

Manual node termination:

```bash
# Drain and delete the failed node
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>

# Karpenter will automatically replace the node
```

### 4. Instance Type Unavailable

**Symptoms:**
- `InsufficientInstanceCapacity` errors in logs
- Particular AZs running out of capacity

**Resolution:**

Expand the NodePool instance family list:

```bash
# Edit the NodePool to add more families
kubectl edit nodepool default
# Add: m6a, c6a, r6a, etc.
```

### 5. Karpenter Controller CrashLoop

**Symptoms:**
- Controller pod restarting continuously
- `CrashLoopBackOff` status

**Resolution:**

```bash
# Check detailed logs
kubectl -n karpenter logs <pod-name> --previous

# Common causes:
# - Invalid NodePool spec (check kubectl describe)
# - Missing IAM permissions on the controller role
# - Network policy blocking EKS API access

# Rollback to previous working version
kubectl -n karpenter set image deployment/karpenter karpenter=public.ecr.aws/karpenter/karpenter:previous-version
```

## Monitoring Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| PendingPods > 10 for 5min | More than 10 pods pending (Karpenter not keeping up) | P1 |
| KarpenterErrors | Controller error rate > 1% | P2 |
| NodeNotReady | Node in NotReady state > 10min | P2 |
| InsufficientCapacity | Instance capacity errors > 5 per hour | P3 |
| KarpenterPodDown | Controller pod not running | P1 |

## Prevention

1. **Instance diversity:** Configure at least 5 instance families in NodePool
2. **Cross-AZ provisioning:** Ensure subnets span at least 3 AZs
3. **Spot diversification:** Use both spot and on-demand capacity types
4. **Regular version upgrades:** Upgrade Karpenter within 2 weeks of release
5. **Load testing:** Regular scale tests to validate Karpenter behavior
