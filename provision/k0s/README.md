# provision/k0s

Azure VMs plus [k0sctl](https://github.com/k0sproject/k0sctl).

`up`: resource group, VNet, NSG, two VMs with fixed private IPs, route table for pod CIDRs, kernel headers on the worker (the NVIDIA driver is built against the running kernel), `k0sctl apply` with a templated config, telemetry disabled. Writes `cluster.env` with `GPU_NODE` set to the worker.

`down`: `az group delete --no-wait` on `conformance-k0s-<run-id>`.

`deps`: k0sctl at the version in `versions.env`.

`--version` selects what gets installed:

| Value | Source | k0sctl |
|---|---|---|
| `main` (default in the pipeline) | `k0s-linux-amd64` built from k0s `main`: `$K0S_BINARY` when the workflow built it, otherwise the artifact of the latest green main build, fetched with `gh` | `uploadBinary: true` + `k0sBinaryPath`; version read from the controller after apply |
| `stable` | `docs.k0sproject.io/stable.txt` | `spec.k0s.version` |
| `vX.Y.Z+k0s.N` | that release | `spec.k0s.version` |
| a file path | that linux/amd64 binary | as `main` |

Only the `gpu` profile exists; k0s Kubernetes conformance is run by the k0s project itself.
