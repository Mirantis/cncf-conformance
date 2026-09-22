#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Mirantis, Inc.
# SPDX-License-Identifier: Apache-2.0

# Kubernetes AI Conformance suite (kubernetes-sigs/ai-conformance) against the
# cluster described by a cluster.env. See README.md and ../README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$HERE/../../lib/common.sh"

print_usage() {
  cat <<USAGE
Usage: $0 --cluster-env FILE --out DIR [--suite-sha SHA]

Ensures a GPU is allocatable on GPU_NODE (installs the NVIDIA GPU Operator only
if it is not), installs Kueue, runs the suite and writes
  DIR/submission/{junit.xml,results.json,e2e.log}
  DIR/debug/{suite.json,helm-values/,cluster-state/}

Environment: GPU_READY_TIMEOUT seconds to wait for nvidia.com/gpu (default 1200)
USAGE
}

CLUSTER_ENV=''
OUT=''
SUITE_SHA_OVERRIDE=''

while [ $# -gt 0 ]; do
  case "$1" in
  --cluster-env) CLUSTER_ENV=$2; shift 2 ;;
  --out) OUT=$2; shift 2 ;;
  --suite-sha) SUITE_SHA_OVERRIDE=$2; shift 2 ;;
  -h | --help) print_usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
  esac
done

[ -n "$CLUSTER_ENV" ] && [ -f "$CLUSTER_ENV" ] || die '--cluster-env FILE is required' 2
[ -n "$OUT" ] || die '--out DIR is required' 2
require_tools kubectl helm go jq git

load_versions
[ -z "$SUITE_SHA_OVERRIDE" ] || SUITE_SHA=$SUITE_SHA_OVERRIDE
# shellcheck source=/dev/null
. "$CLUSTER_ENV"
: "${KUBECONFIG:?cluster.env must set KUBECONFIG}"
: "${GPU_NODE:?cluster.env must set GPU_NODE for the ai suite}"
export KUBECONFIG

GPU_READY_TIMEOUT=${GPU_READY_TIMEOUT:-1200}
GANG_NAMESPACE=ai-conformance-gang-scheduling
GANG_QUEUE=e2e-lq
SUBMISSION="$OUT/submission"
DEBUG="$OUT/debug"
WORK=$(mktemp -d)
GPU_OPERATOR_STATE=''
SUITE_RC=''

mkdir -p "$SUBMISSION" "$DEBUG"

collect_suite_state() {
  local dir="$DEBUG/cluster-state"
  mkdir -p "$dir"
  local k="kubectl --request-timeout=30s"
  $k -n gpu-operator get pods -o wide >"$dir/gpu-operator-pods.txt" 2>&1 || true
  $k get clusterqueue,localqueue,resourceflavor -A >"$dir/kueue-objects.txt" 2>&1 || true
  $k -n "$GANG_NAMESPACE" get jobs,pods -o wide >"$dir/gang-namespace.txt" 2>&1 || true
  # Driver, toolkit, device plugin and validator logs: the only way to explain a
  # GPU that never became (or stopped being) allocatable once the VMs are gone.
  local pod
  mkdir -p "$dir/gpu-operator-logs"
  for pod in $($k -n gpu-operator get pods -o name 2>/dev/null | grep -E 'driver|toolkit|device-plugin|validator|gpu-operator-[a-z0-9]+-' ); do
    $k -n gpu-operator describe "$pod" >"$dir/gpu-operator-logs/${pod#pod/}.describe.txt" 2>&1 || true
    $k -n gpu-operator logs "$pod" --all-containers --tail=500 >"$dir/gpu-operator-logs/${pod#pod/}.log" 2>&1 || true
    $k -n gpu-operator logs "$pod" --all-containers --previous --tail=200 >"$dir/gpu-operator-logs/${pod#pod/}.previous.log" 2>/dev/null || rm -f "$dir/gpu-operator-logs/${pod#pod/}.previous.log"
  done
}

on_exit() {
  local rc=$1
  trap - EXIT
  set +e
  collect_suite_state
  rm -rf "$WORK"
  exit "$rc"
}
trap 'on_exit $?' EXIT

gpu_capacity_is_one() {
  [ "$(kubectl get node "$GPU_NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)" = 1 ]
}

# The validator pod only becomes Ready once driver, toolkit, device plugin and a
# CUDA workload have all been checked on the node.
gpu_validator_ready() {
  kubectl -n gpu-operator get pods -l app=nvidia-operator-validator \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -q True
}

# gpu_stable [validator] — allocatable can flap while the driver pod restarts;
# require it to hold for 30 s. With "validator", also require the operator's
# validator pod to stay Ready (only meaningful when this suite installed the operator).
gpu_stable() {
  local i
  for i in 1 2 3; do
    gpu_capacity_is_one || return 1
    [ "${1:-}" != validator ] || gpu_validator_ready || return 1
    [ "$i" -eq 3 ] || sleep 15
  done
}

ensure_gpu() {
  if gpu_capacity_is_one; then
    GPU_OPERATOR_STATE=preexisting
    log "nvidia.com/gpu already allocatable on $GPU_NODE; skipping GPU Operator install"
    gpu_stable || die "nvidia.com/gpu on $GPU_NODE is allocatable but not stable"
    return 0
  fi
  GPU_OPERATOR_STATE=installed
  mkdir -p "$DEBUG/helm-values"
  cp "$HERE/manifests/gpu-operator-values.yaml" "$DEBUG/helm-values/"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update >/dev/null
  helm upgrade --install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace \
    --version "$GPU_OPERATOR_VERSION" -f "$HERE/manifests/gpu-operator-values.yaml" -o json |
    jq -r '"gpu-operator " + .info.status'
  wait_for "$GPU_READY_TIMEOUT" gpu_capacity_is_one
  wait_for 300 gpu_validator_ready
  gpu_stable validator || die "nvidia.com/gpu on $GPU_NODE did not stay allocatable for 30 s after the validator reported Ready"
  kubectl -n gpu-operator get pods -o wide
}

kueue_active() {
  kubectl get clusterqueue e2e-cq -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null | grep -q True
}

install_kueue() {
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_VERSION/manifests.yaml" >/dev/null
  kubectl -n kueue-system rollout status deployment kueue-controller-manager --timeout=5m
  wait_for 120 kubectl apply -f "$HERE/manifests/kueue-objects.yaml"
  wait_for 120 kueue_active
}

run_suite() {
  git clone -q https://github.com/kubernetes-sigs/ai-conformance "$WORK/ai-conformance"
  git -C "$WORK/ai-conformance" checkout -q "$SUITE_SHA"
  SUITE_SHA=$(git -C "$WORK/ai-conformance" rev-parse HEAD)
  # -autoscaler-node-pool-label is left unset: the autoscaling test is skipped.
  (
    cd "$WORK/ai-conformance"
    go run "gotest.tools/gotestsum@$GOTESTSUM_VERSION" \
      --junitfile "$SUBMISSION/junit.xml" --jsonfile "$SUBMISSION/results.json" --format standard-verbose -- \
      ./test -v -timeout 30m \
      -kubeconfig="$KUBECONFIG" \
      -accelerator-type=nvidia \
      -allocation-mode=auto \
      -gang-scheduler-namespace="$GANG_NAMESPACE" \
      -gang-job-labels="kueue.x-k8s.io/queue-name=$GANG_QUEUE" \
      2>&1 | tee "$SUBMISSION/e2e.log" | { grep -E '^(=== RUN|--- (PASS|FAIL|SKIP)|PASS|FAIL|ok|DONE)' || true; }
    exit "${PIPESTATUS[0]}"
  ) || SUITE_RC=$?
  SUITE_RC=${SUITE_RC:-0}
  return "$SUITE_RC"
}

write_suite_json() {
  local driver tests
  driver=$(kubectl -n gpu-operator exec ds/nvidia-driver-daemonset -- \
    nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null || echo 'unknown,unknown')
  tests='{}'
  if [ -f "$SUBMISSION/e2e.log" ]; then
    tests=$(grep -E '^--- (PASS|FAIL|SKIP): Test[A-Za-z]+ ' "$SUBMISSION/e2e.log" |
      awk '{sub(":", "", $2); print $3 "\t" $2}' | sort -u |
      jq -R -n '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')
  fi
  jq -n \
    --arg suite "$SUITE_SHA" \
    --arg gpu_state "$GPU_OPERATOR_STATE" --arg gpu_operator "$GPU_OPERATOR_VERSION" \
    --arg kueue "$KUEUE_VERSION" --arg gotestsum "$GOTESTSUM_VERSION" \
    --arg driver "${driver%%,*}" --arg gpu "$(echo "${driver#*,}" | xargs)" \
    --argjson rc "${SUITE_RC:-1}" --argjson tests "$tests" \
    '{
      program: "k8s-ai-conformance",
      suite: {repo: "https://github.com/kubernetes-sigs/ai-conformance", sha: $suite},
      gpu_operator: {state: $gpu_state, chart: $gpu_operator}, kueue: $kueue, gotestsum: $gotestsum,
      nvidia_driver: $driver, gpu: $gpu, allocation_mode: "device-plugin",
      exit_code: $rc, tests: $tests
    }' >"$DEBUG/suite.json"
  cat "$DEBUG/suite.json"
}

stage ai-ensure-gpu ensure_gpu
stage ai-kueue install_kueue
stage ai-suite run_suite || true
stage ai-suite-json write_suite_json
[ "$SUITE_RC" -eq 0 ] || exit 1
