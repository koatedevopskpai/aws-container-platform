# ADR-002: External Secrets Operator over CSI Secrets Store Driver

## Status

Accepted

## Context

SecondWave needs to synchronize secrets from AWS Secrets Manager into Kubernetes pods. Two primary approaches exist:

1. **AWS Secrets & Configuration Provider (ASCP) with CSI Secrets Store Driver** — mounts secrets as volumes via CSI
2. **External Secrets Operator (ESO)** — creates native Kubernetes Secret objects synced from external stores

Our requirements:
- Secrets must be available as environment variables (legacy workloads) and volume mounts
- Secret rotation should propagate to pods without restart (where possible)
- Multi-cloud readiness for future GCP/Azure expansion
- Squad autonomy: squads should reference secrets without understanding the underlying store

## Decision

We will use **External Secrets Operator (ESO)** with AWS Secrets Manager as the primary secret store.

## Rationale

| Factor | External Secrets Operator | CSI Secrets Store Driver |
|--------|--------------------------|--------------------------|
| Secret format | Native K8s Secret (env/volume/any) | Only file-based volumes |
| Rotation behavior | Updates Secret object; pod reload depends on workload | Requires CSI driver reload or pod restart |
| Multi-store support | AWS, GCP, Azure, Vault, Kubernetes, Git, etc. | AWS, GCP, Azure, Vault |
| Workload awareness | Transparent — workloads use normal Secret references | Requires CSI volume definition in pod spec |
| RBAC model | Standard K8s RBAC on Secrets | CSI driver RBAC + node-level permissions |

**Specific advantages for SecondWave:**

- **Squad onboarding:** A squad's manifest references `secretRef` like any normal Kubernetes Secret. No CSI knowledge required.
- **Environment variables:** 60% of SecondWave's workloads use env vars for configuration. CSI driver cannot inject directly into env vars without an init container.
- **Rotation propagation:** ESO updates the Secret object immediately. Workloads using tools like Reloader or Stakater can auto-restart on secret change.

## Security Safeguard: Push-based sync

ESO *pushes* secrets from AWS Secrets Manager into the cluster. The cluster does not need outbound internet access to pull secrets (beyond what it already has). This is in contrast to the CSI driver which mounts secrets on demand, requiring the node to have network access to the secret store at pod start time.

## Trade-offs

- **Extra component:** ESO adds a controller that must be maintained and upgraded.
- **Secret duplication:** Secrets exist in both AWS Secrets Manager and Kubernetes etcd. This doubles the storage and introduces a sync window.
- **CRD complexity:** ESO introduces ExternalSecret, SecretStore, and ClusterSecretStore CRDs that team must learn.

## Consequences

1. All squad-facing secrets use `kind: ExternalSecret` which ESO reconciles to `kind: Secret`
2. Platform team maintains the `ClusterSecretStore` pointing to AWS Secrets Manager
3. Cross-account secrets (partner banking APIs) use a separate `SecretStore` with assume-role
4. Monitoring alert if `ExternalSecret` status is not `SecretSynced` for >5 minutes
