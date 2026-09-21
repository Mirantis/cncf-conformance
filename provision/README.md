# provision

One directory per product. Each contains a `provision.sh` with three subcommands:

| Subcommand | Contract |
|---|---|
| `deps` | Install the product's tools on an Ubuntu GitHub runner (no-op on a laptop that already has them) |
| `up --run-id ID --profile gpu\|standard --out DIR [--version V]` | Create a cluster and write `DIR/cluster.env` and `DIR/debug/provision.json` |
| `down --run-id ID` | Destroy everything created by `up`. Idempotent. Must work from the run id alone, even if `up` failed before writing `cluster.env` |

## `cluster.env`

The only thing a suite is allowed to read from a provisioner.

| Key | Meaning |
|---|---|
| `PRODUCT`, `PRODUCT_VERSION` | e.g. `k0s`, `v1.36.4+k0s.0` |
| `KUBECONFIG` | Absolute path to an admin kubeconfig |
| `GPU_NODE` | Name of a schedulable node with one NVIDIA GPU (`gpu` profile). Empty for `standard` |
| `INFRA` | One line describing the infrastructure, for summaries and metadata |

## Profiles

| Profile | Shape | Used by |
|---|---|---|
| `gpu` | One control plane, one NVIDIA T4 worker, worker untainted | `suite/ai` |
| `standard` | Three control planes, two workers, no GPU | `suite/k8s` |

Azure resource groups are named `conformance-<product>-<run-id>` so that cleanup and hygiene queries are product-agnostic.
