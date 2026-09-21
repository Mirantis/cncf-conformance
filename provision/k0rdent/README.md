# provision/k0rdent

A k0rdent management cluster plus an Azure `ClusterDeployment`.

`up`: management cluster (kind on the runner, or a standing cluster; decision pending), Azure credential objects, a `ClusterDeployment` from the profile's template, wait for the child cluster to be ready, fetch its kubeconfig. Writes `cluster.env` with `GPU_NODE` set to the GPU worker for the `gpu` profile.

`down`: delete the `ClusterDeployment` and wait for the Azure resources to go, then remove the management cluster if it was ephemeral.

`deps`: kind, helm and the k0rdent chart version from `versions.env`.

Manifests planned here: `clusterdeployment-gpu.yaml` (one control plane, one T4 worker), `clusterdeployment-standard.yaml` (three control planes, two workers), credential and identity templates.

GPU drivers may come from the k0rdent catalog rather than from the suite, which is why `suite/ai` only ensures a GPU is allocatable and installs the GPU Operator when it is not.
