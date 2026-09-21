# suite

One directory per CNCF program. Each contains a `run.sh` that takes the path to a `cluster.env` and an output directory:

```
suite/<program>/run.sh --cluster-env DIR/cluster.env --out DIR
```

Outputs:

| Path | Content |
|---|---|
| `DIR/submission/` | Exactly the files the upstream repository expects, under their canonical names |
| `DIR/debug/` | Everything useful after the cluster is gone: cluster state, component logs, values used, `suite.json` with versions and results |

A suite reads only `cluster.env` and `versions.env`. It must not contain product-specific branches; if a product needs something different, that belongs in its provisioner.

Exit status: `0` when every test passed or was skipped, `1` when a test failed or a stage timed out. `run.sh` moves `submission/` to `failed/` on non-zero exit so a failed run cannot be submitted by accident.
