#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Mirantis, Inc.
# SPDX-License-Identifier: Apache-2.0

# Kubernetes Conformance (Sonobuoy, certified-conformance mode) against the
# cluster described by a cluster.env. See README.md and ../README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$HERE/../../lib/common.sh"

print_usage() {
  cat <<USAGE
Usage: $0 --cluster-env FILE --out DIR

Runs Sonobuoy in certified-conformance mode and writes
  DIR/submission/{e2e.log,junit_01.xml}
  DIR/debug/{suite.json,sonobuoy-results.tar.gz,sonobuoy-results.txt}

Environment: SONOBUOY_WAIT minutes to wait for the run (default 180)
USAGE
}

CLUSTER_ENV=''
OUT=''

while [ $# -gt 0 ]; do
  case "$1" in
  --cluster-env) CLUSTER_ENV=$2; shift 2 ;;
  --out) OUT=$2; shift 2 ;;
  --suite-sha) shift 2 ;; # ai suite only; accepted so run.sh can pass it unconditionally
  -h | --help) print_usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
  esac
done

[ -n "$CLUSTER_ENV" ] && [ -f "$CLUSTER_ENV" ] || die '--cluster-env FILE is required' 2
[ -n "$OUT" ] || die '--out DIR is required' 2
require_tools kubectl jq curl tar

load_versions
# shellcheck source=/dev/null
. "$CLUSTER_ENV"
: "${KUBECONFIG:?cluster.env must set KUBECONFIG}"
export KUBECONFIG

SONOBUOY_WAIT=${SONOBUOY_WAIT:-180}
SUBMISSION="$OUT/submission"
DEBUG="$OUT/debug"
WORK=$(mktemp -d)
SONOBUOY="$WORK/sonobuoy"
SUITE_RC=''

mkdir -p "$SUBMISSION" "$DEBUG"

on_exit() {
  local rc=$1
  trap - EXIT
  set +e
  stage_abort "$rc"
  [ ! -x "$SONOBUOY" ] || "$SONOBUOY" delete --all --wait >/dev/null 2>&1
  rm -rf "$WORK"
  exit "$rc"
}
trap 'on_exit $?' EXIT

install_sonobuoy() {
  local os arch v=${SONOBUOY_VERSION#v} base tarball
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  base="https://github.com/vmware-tanzu/sonobuoy/releases/download/v$v"
  tarball="sonobuoy_${v}_${os}_${arch}.tar.gz"
  curl -fsSL --retry 3 --max-time 300 -o "$WORK/$tarball" "$base/$tarball"
  curl -fsSL --retry 3 --max-time 60 -o "$WORK/checksums.txt" "$base/sonobuoy_${v}_checksums.txt"
  (cd "$WORK" && grep " $tarball\$" checksums.txt | sha256sum -c - >/dev/null) || die "checksum mismatch for $tarball"
  tar -xzf "$WORK/$tarball" -C "$WORK" sonobuoy
  "$SONOBUOY" version --short
}

# Conformance needs at least two schedulable nodes (some tests spread pods).
schedulable_nodes() {
  kubectl get nodes -o json | jq '[.items[] | select(.spec.unschedulable != true)
    | select([.spec.taints[]? | select(.effect == "NoSchedule" or .effect == "NoExecute")] | length == 0)] | length'
}

preflight() {
  local n
  n=$(schedulable_nodes)
  log "$n schedulable nodes"
  [ "$n" -ge 2 ] || die "Kubernetes conformance needs at least 2 schedulable nodes, found $n"
  kubectl version -o json | jq -r '"server " + .serverVersion.gitVersion'
}

run_sonobuoy() {
  "$SONOBUOY" run --mode=certified-conformance --wait="$SONOBUOY_WAIT" || SUITE_RC=$?
  "$SONOBUOY" status --json >"$DEBUG/sonobuoy-status.json" 2>&1 || true
  local tarball
  tarball=$("$SONOBUOY" retrieve "$WORK") || die 'sonobuoy retrieve failed'
  cp "$tarball" "$DEBUG/sonobuoy-results.tar.gz"
  "$SONOBUOY" results "$tarball" --plugin e2e | tee "$DEBUG/sonobuoy-results.txt"
  "$SONOBUOY" results "$tarball" --plugin e2e --mode detailed |
    jq -r 'select(.status == "failed") | .name' >"$DEBUG/failed-tests.txt"
  tar -xzf "$tarball" -C "$WORK" plugins/e2e/results/global/e2e.log plugins/e2e/results/global/junit_01.xml
  cp "$WORK/plugins/e2e/results/global/"{e2e.log,junit_01.xml} "$SUBMISSION/"
  # A run can report "passed" only if the e2e plugin completed with zero failures.
  [ "$(results_field Status)" = passed ] && [ "$(results_field Failed)" = 0 ] || SUITE_RC=${SUITE_RC:-1}
  [ "${SUITE_RC:-0}" -ne 0 ] || [ ! -s "$DEBUG/failed-tests.txt" ] || SUITE_RC=1
  SUITE_RC=${SUITE_RC:-0}
  return "$SUITE_RC"
}

# results_field NAME — value of "NAME: value" in the e2e results summary
results_field() {
  awk -F': ' -v k="$1" '$1 == k {print $2; exit}' "$DEBUG/sonobuoy-results.txt" 2>/dev/null
}

write_suite_json() {
  local tests='{}'
  [ ! -s "$DEBUG/failed-tests.txt" ] ||
    tests=$(jq -R -n '[inputs | {key: ., value: "FAIL"}] | from_entries' "$DEBUG/failed-tests.txt")
  jq -n \
    --arg sonobuoy "$SONOBUOY_VERSION" \
    --arg server "$(kubectl version -o json 2>/dev/null | jq -r .serverVersion.gitVersion)" \
    --arg status "$(results_field Status)" \
    --arg total "$(results_field Total)" --arg passed "$(results_field Passed)" \
    --arg failed "$(results_field Failed)" --arg skipped "$(results_field Skipped)" \
    --argjson rc "${SUITE_RC:-1}" --argjson tests "$tests" \
    '{
      program: "k8s-conformance",
      suite: {tool: "sonobuoy", version: $sonobuoy, mode: "certified-conformance"},
      kubernetes_version: $server,
      results: {status: $status, total: ($total | tonumber? // null), passed: ($passed | tonumber? // null),
        failed: ($failed | tonumber? // null), skipped: ($skipped | tonumber? // null)},
      exit_code: $rc, tests: $tests
    }' >"$DEBUG/suite.json"
  cat "$DEBUG/suite.json"
}

stage k8s-sonobuoy-install install_sonobuoy
stage k8s-preflight preflight
stage k8s-suite run_sonobuoy || true
stage k8s-suite-json write_suite_json
[ "$SUITE_RC" -eq 0 ] || exit 1
