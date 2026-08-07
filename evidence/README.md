# POC Evidence

`scripts/verify-poc.ps1` writes the Phase 6 completion artefacts here:

- `phase6-<environment>.state.json` checkpoints slow and mutating steps for `-Resume`.
- `phase6-<environment>-<run>.json` contains source commits, full audit envelopes, Databricks run IDs, Blob paths, KQL queries/results, latency, restart/replay observations, resource names, configuration assertions, and normalized RBAC role/scope sets.
- `phase6-<environment>-<run>.md` is the concise human-readable proof summary.

Generated evidence is intentionally ignored by Git. The verifier uses identity-only reads and does not persist credentials, SAS tokens, account keys, or secret-bearing connection strings.