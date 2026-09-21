# workflows

One workflow, `conformance.yaml`.

| Trigger | Behaviour |
|---|---|
| `schedule` (Mondays) | `suite=ai` for every product |
| `workflow_dispatch` | Inputs: `product` (k0s, k0rdent, all), `suite` (ai, k8s), `version`, `suite-sha` override, `keep-cluster` |

Matrix over products with `fail-fast: false`, so one product failing does not cancel the other. Steps: checkout, Azure login through OIDC (no long-lived secrets), Go setup, `provision/<product>/provision.sh deps`, `run.sh`, upload artifacts on every exit path (kubeconfig and SSH material excluded), delete the resource group as a safety net if the script could not.

Required repository secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`. The Azure service principal trusts this repository's `main` branch through a federated credential.
