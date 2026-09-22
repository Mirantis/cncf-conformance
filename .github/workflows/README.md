# workflows

One workflow, `conformance.yaml`.

| Trigger | Behaviour |
|---|---|
| `schedule` (Mondays) | `suite=ai`, `version=main`, for every product. Retries once on failure, so a transient infrastructure problem is not a red week; two failures in a row are |
| `workflow_dispatch` | No retry: a dispatched run's artifacts may be submitted, so they must come from a first-attempt pass. Inputs: `product` (k0s, k0rdent, all), `suite` (ai, k8s), `version` (`main`, `stable` or a tag), `suite-sha` override, `keep-cluster` |

Jobs: `plan` turns inputs into a matrix, reads `versions.env` and sets a per-product timeout (`ai`: 60 min for k0s, 75 min for k0rdent, whose run is about 36 min including the kind management cluster and the CAPZ teardown; `k8s`: 180 min; doubled for scheduled runs because of the retry); `run` is the matrix over products with `fail-fast: false`, so one product failing does not cancel the other. For `version=main` the k0s provisioner fetches the `k0s-linux-amd64` artifact of the latest green k0s `main` build with `gh` (reusable workflows cannot be used for this: they check out the calling repository). Steps: checkout, Azure login through OIDC (no long-lived secrets), Go setup, `provision/<product>/provision.sh deps`, `run.sh`, upload artifacts on every exit path (kubeconfig and SSH material excluded), delete the resource group as a safety net if the script could not.

Required repository secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_SECRET`. The az CLI logs in through OIDC: the service principal trusts this repository's `main` branch through a federated credential. The client secret exists only for the k0rdent provisioner, whose Azure CAPI provider runs inside a kind cluster on the runner and authenticates as the service principal itself.
