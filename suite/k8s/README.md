# suite/k8s

Kubernetes Conformance, tested with [Sonobuoy](https://sonobuoy.io) in `certified-conformance` mode, at the version pinned in `versions.env`.

Stages:

1. `sonobuoy run --mode=certified-conformance --wait`.
2. `sonobuoy retrieve`, extract `plugins/e2e/results/global/e2e.log` and `junit_01.xml` into `submission/`.
3. Keep the full tarball in `debug/`.

Requires the `standard` profile (at least two workers). Runs on demand only, once per release. Not yet implemented; planned after the first AI conformance submissions from this repository.
