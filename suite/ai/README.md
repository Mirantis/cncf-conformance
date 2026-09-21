# suite/ai

Kubernetes AI Conformance, tested with [kubernetes-sigs/ai-conformance](https://github.com/kubernetes-sigs/ai-conformance) at the commit pinned in `versions.env`.

Stages:

1. Ensure a GPU: skip when `nvidia.com/gpu` is already allocatable on `GPU_NODE`, otherwise install the NVIDIA GPU Operator with `manifests/gpu-operator-values.yaml` and wait for capacity.
2. Install Kueue and apply `manifests/kueue-objects.yaml` (ResourceFlavor, ClusterQueue, namespace, LocalQueue used by the gang scheduling test).
3. Run the suite with gotestsum: `-accelerator-type=nvidia -allocation-mode=auto`, gang scheduling namespace and queue label set, autoscaler node pool label unset.
4. Collect `junit.xml`, `results.json`, `e2e.log` into `submission/`; driver and component versions into `debug/suite.json`.

Expected results: `TestSecureAcceleratorAccess` and `TestGangScheduling` pass, `TestAcceleratorClusterAutoscaling` skipped.
