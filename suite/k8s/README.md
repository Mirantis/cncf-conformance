# suite/k8s

Kubernetes Conformance, tested with [Sonobuoy](https://sonobuoy.io) in `certified-conformance` mode, at the version pinned in `versions.env`.

```
./run.sh --product k0rdent --suite k8s --version v1.11.0
```

Stages:

1. Download the pinned Sonobuoy release and verify its checksum.
2. Check that at least two nodes are schedulable.
3. `sonobuoy run --mode=certified-conformance --wait` (up to `SONOBUOY_WAIT` minutes, default 180), `sonobuoy retrieve`, extract `plugins/e2e/results/global/{e2e.log,junit_01.xml}` into `submission/`. The full tarball, the `sonobuoy results` summary and any failed test names go to `debug/`.
4. `debug/suite.json`: Sonobuoy version, server version, pass/fail/skip counts.

The run fails unless the e2e plugin reports `passed` with zero failures. Needs the `standard` profile (the default for this suite). Runs on demand, once per release; a k0rdent run takes about 2 h 40 min (provisioning 22 min, Sonobuoy 2 h 10 min, teardown 5 min).
