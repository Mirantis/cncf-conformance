# workflows

One workflow, `conformance.yaml`.

| Trigger | Behaviour |
|---|---|
| `schedule` (Mondays) | `suite=ai`, `version=main`, for every product |
| `workflow_dispatch` | Inputs: `product` (k0s, k0rdent, all), `suite` (ai, k8s), `version` (`main`, `stable` or a tag), `suite-sha` override, `keep-cluster` |

Jobs: `plan` turns inputs into a matrix and reads `versions.env`; `run` is the matrix over products with `fail-fast: false`, so one product failing does not cancel the other. For `version=main` the k0s provisioner fetches the `k0s-linux-amd64` artifact of the latest green k0s `main` build with `gh` (reusable workflows cannot be used for this: they check out the calling repository). Steps: checkout, Azure login through OIDC (no long-lived secrets), Go setup, `provision/<product>/provision.sh deps`, `run.sh`, upload artifacts on every exit path (kubeconfig and SSH material excluded), delete the resource group as a safety net if the script could not.

Required repository secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`. The Azure service principal trusts this repository's `main` branch through a federated credential.
