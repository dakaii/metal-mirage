# Velero backups (Blob)

Standby stack exports:

- `veleroStorageAccount`
- `veleroContainer`
- `veleroIdentityClientId`

Install Velero on **primary** (and optionally standby) pointing at that account.
Use Azure Workload Identity / the user-assigned identity created in `infra/standby-aks`.

```bash
# Example — adjust subscription/RG/account from pulumi outputs
velero install \
  --provider azure \
  --plugins velero/velero-plugin-for-microsoft-azure:v1.10.1 \
  --bucket "$(pulumi -C infra/standby-aks stack output veleroContainer)" \
  --secret-file ./credentials-velero \
  --backup-location-config resourceGroup=...,storageAccount=...,subscriptionId=...
```

On failover: restore latest backup to AKS, scale demo replicas 0→N (standby GitOps patch), confirm Traffic Manager health.
