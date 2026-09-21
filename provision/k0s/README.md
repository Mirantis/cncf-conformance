# provision/k0s

Azure VMs plus [k0sctl](https://github.com/k0sproject/k0sctl).

`up`: resource group, VNet, NSG, two VMs with fixed private IPs, route table for pod CIDRs, kernel headers on the worker (the NVIDIA driver is built against the running kernel), `k0sctl apply` with a templated config, telemetry disabled. Writes `cluster.env` with `GPU_NODE` set to the worker.

`down`: `az group delete --no-wait` on `conformance-k0s-<run-id>`.

`deps`: k0sctl at the version in `versions.env`.

Version defaults to the current stable k0s release from `docs.k0sproject.io/stable.txt`. Only the `gpu` profile is planned; k0s Kubernetes conformance is run by the k0s project itself.
