# cncf-conformance

Automation and evidence for CNCF conformance certification of [k0s](https://k0sproject.io) and [k0rdent](https://k0rdent.io):

- **Kubernetes AI Conformance** ([cncf/k8s-ai-conformance](https://github.com/cncf/k8s-ai-conformance)), tested with the [kubernetes-sigs/ai-conformance](https://github.com/kubernetes-sigs/ai-conformance) suite on a GPU cluster.
- **Kubernetes Conformance** ([cncf/k8s-conformance](https://github.com/cncf/k8s-conformance)), tested with Sonobuoy. k0rdent only; k0s runs its own.

A pipeline run provisions a temporary cluster on Azure, runs one suite, collects the submission artifacts, and destroys the cluster. Runs are weekly and on demand through GitHub Actions. Submissions to CNCF are prepared from a green run and opened manually; the upstream repository is the only copy of what was submitted, and the status table below links each submission to the Actions run that produced it. For a given Kubernetes version, the Kubernetes conformance entry must be merged before the AI conformance submission can reference it.

## Layout

Read the top level as the pipeline: provision a cluster, run a suite, upload the artifacts.

| Path | Purpose |
|---|---|
| `run.sh` | Only entrypoint: `run.sh --product k0s\|k0rdent --suite ai\|k8s` |
| `versions.env` | Every pinned version (suite commit, GPU Operator, Kueue, k0sctl, Sonobuoy, ...) |
| `lib/` | Shell helpers shared by all stages |
| `provision/<product>/` | Product-specific: `deps`, `up`, `down`. `up` hands over a `cluster.env` |
| `suite/<program>/` | Product-agnostic: reads `cluster.env`, produces `submission/` and `debug/` |
| `.github/workflows/` | One workflow, matrix over products; artifacts are kept for 90 days |

Each directory has a README describing its contract.

## Status

Each certified entry links to the upstream directory and, for pipeline runs, to the Actions run whose artifacts were submitted.

| Product | Program | v1.35 | v1.36 | v1.37 |
|---|---|---|---|---|
| k0s | AI Conformance | [certified](https://github.com/cncf/k8s-ai-conformance/tree/main/v1.35/k0s) (manual) | pipeline green ([run](https://github.com/Mirantis/cncf-conformance/actions/runs/35737735835)), submission pending | planned |
| k0rdent | AI Conformance | [certified](https://github.com/cncf/k8s-ai-conformance/tree/main/v1.35/k0rdent) (manual) | pipeline green locally, submission pending | planned |
| k0rdent | Kubernetes Conformance | [certified](https://github.com/cncf/k8s-conformance/tree/master/v1.35/k0rdent) (manual) | planned | planned |

## License

Apache-2.0, see [LICENSE](LICENSE). Maintained by Mirantis.
