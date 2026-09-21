# submissions

What was actually sent upstream, kept here so the evidence outlives GitHub Actions artifact retention.

| Directory | Mirrors |
|---|---|
| `k8s-ai-conformance/v1.xx/<product>/` | [cncf/k8s-ai-conformance](https://github.com/cncf/k8s-ai-conformance): `PRODUCT.yaml`, `junit.xml`, `e2e.log`, `results.json` |
| `k8s-conformance/v1.xx/<product>/` | [cncf/k8s-conformance](https://github.com/cncf/k8s-conformance): `PRODUCT.yaml`, `README.md`, `e2e.log`, `junit_01.xml` |

Rules:

- Only the run used for an upstream pull request is committed here, never every weekly run.
- Each directory is byte-identical to the upstream one, so a submission is a copy. The one extra file is `run-metadata.json` (versions, infrastructure, timings, workflow run link), which is excluded when copying upstream.
- `PRODUCT.yaml` is validated locally with the upstream validator before the pull request is opened.
