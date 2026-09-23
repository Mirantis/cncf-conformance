# provision/k0rdent

An ephemeral [kind](https://kind.sigs.k8s.io) management cluster running [k0rdent](https://k0rdent.io) (kcm), which deploys an Azure child cluster through a `ClusterDeployment`. The child cluster is the one under test.

| Subcommand | What happens |
|---|---|
| `deps` | kind at the version in `versions.env`. helm, kubectl, az, jq, git and envsubst must be present |
| `up` | kind cluster → `helm install kcm` with `controller.createManagement=false` → `Management` with only the k0smotron, Azure and Sveltos providers (the default enables every provider, too much for a kind cluster on a runner) → wait for it and for the `azure-standalone-cp` `ClusterTemplate` → Azure `Secret`, `AzureClusterIdentity`, `Credential` and the `azure-cluster-identity-resource-template` ConfigMap → `ClusterDeployment` → wait `Ready` → child kubeconfig → wait for every node Ready and initialised by the cloud controller manager |
| `down` | delete the `ClusterDeployment` and wait for its resource group to go, fall back to `az group delete`, delete the kind cluster |

Everything is named `conformance-k0rdent-<run-id>`: the kind cluster, the `ClusterDeployment` and, because CAPZ names the resource group after the cluster, the Azure resource group. The name must stay within 36 characters: CAPZ names the worker availability set `<name>_<name>-md-as` and Azure caps that at 80.

## Versions

| `--version` | Chart |
|---|---|
| `stable` (default) | latest GitHub release of `k0rdent/kcm`, `oci://ghcr.io/k0rdent/kcm/charts/kcm` |
| `vX.Y.Z` | that release |
| `main` | `oci://ghcr.io/k0rdent/kcm/staging/kcm`, published by every push to kcm `main`. The version is `git describe --tags` of the commit; the provisioner probes the last 15 main commits until a chart answers |

The child runs the k0s version the cluster template pins. `K0S_VERSION` in the environment overrides it.

## Profiles

| Profile | Shape |
|---|---|
| `gpu` | 1 control plane `Standard_A4_v2`, 1 worker `Standard_NC4as_T4_v3`. `GPU_NODE` is the worker |
| `standard` | 3 control planes, 2 workers, all `Standard_A4_v2` |

Control planes keep the `node-role.kubernetes.io/control-plane` taint; only the worker is schedulable for the suite.

## Environment

| Variable | Meaning |
|---|---|
| `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` | Service principal the Azure provider inside the management cluster uses. Required; the az CLI login alone is not enough |
| `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | Default to the az CLI's current account |
| `K0S_VERSION` | Override the child k0s version |
| `CONTROL_PLANE_SIZE`, `WORKER_SIZE` | Override the VM sizes |

The secret is rendered straight into `kubectl apply` and never written under the output directory. The management cluster's kubeconfig lives at `mgmt/kubeconfig` and is removed by `down`.

## Notes

- The GPU Operator is installed by `suite/ai`, not here, with the same values as for k0s. Installing it through the k0rdent catalog as a `MultiClusterService` is a possible later step; the suite already skips its own install when a GPU is allocatable.
- The CAPI worker image ships its own containerd (with `SystemdCgroup = true` for runc) next to the one k0s bundles. The NVIDIA toolkit would read that stock config by default and write a systemd-cgroup runtime into k0s's containerd while kubelet stays on cgroupfs. `suite/ai` sets the toolkit's `RUNTIME_CONFIG_SOURCE=file` to prevent it; a kubelet `--cgroup-driver` flag does not help because kubelet 1.36 takes the driver from containerd.
