#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Mirantis, Inc.
# SPDX-License-Identifier: Apache-2.0

# Orchestrator: provision a cluster for a product, run one CNCF suite against it,
# collect artifacts, destroy the cluster. The only entrypoint; see README.md.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
export REPO_ROOT
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"

print_usage() {
  cat <<USAGE
Usage: $0 --product PRODUCT --suite SUITE [OPTIONS]

  --product  k0s | k0rdent            (must exist under provision/)
  --suite    ai | k8s                 (must exist under suite/)
  --version  main | stable | tag | path   what to install (default: main)
  --profile  gpu | standard           (default: gpu for ai, standard for k8s)
  --suite-sha SHA                     override SUITE_SHA from versions.env (ai)
  --out DIR                           artifact root; a UTC-timestamped subdirectory is
                                      created (default: ./artifacts)
  --run-id ID                         resource naming suffix (default: gha-\$GITHUB_RUN_ID
                                      or the current epoch)
  --location LOCATION                 passed to the provisioner
  --keep-cluster                      do not run 'down'; keep kubeconfig and ssh material
  -h, --help

Exit status: 0 every test passed or was skipped; 1 a test failed or a stage
timed out (submission files are moved to failed/); 2 usage or missing tools.
USAGE
}

PRODUCT=''
SUITE=''
VERSION=main
PROFILE=''
SUITE_SHA_OVERRIDE=''
OUT_ROOT=./artifacts
RUN_ID="${GITHUB_RUN_ID:+gha-$GITHUB_RUN_ID}"
RUN_ID="${RUN_ID:-$(date +%s)}"
LOCATION=''
KEEP_CLUSTER=n

while [ $# -gt 0 ]; do
  case "$1" in
  --product) PRODUCT=$2; shift 2 ;;
  --suite) SUITE=$2; shift 2 ;;
  --version) VERSION=$2; shift 2 ;;
  --profile) PROFILE=$2; shift 2 ;;
  --suite-sha) SUITE_SHA_OVERRIDE=$2; shift 2 ;;
  --out) OUT_ROOT=$2; shift 2 ;;
  --run-id) RUN_ID=$2; shift 2 ;;
  --location) LOCATION=$2; shift 2 ;;
  --keep-cluster) KEEP_CLUSTER=y; shift ;;
  -h | --help) print_usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
  esac
done

PROVISIONER="$REPO_ROOT/provision/$PRODUCT/provision.sh"
SUITE_RUNNER="$REPO_ROOT/suite/$SUITE/run.sh"
[ -n "$PRODUCT" ] && [ -x "$PROVISIONER" ] || die "--product must name a directory under provision/ with a provision.sh (got '$PRODUCT')" 2
[ -n "$SUITE" ] && [ -x "$SUITE_RUNNER" ] || die "--suite must name a directory under suite/ with a run.sh (got '$SUITE')" 2
if [ -z "$PROFILE" ]; then
  case "$SUITE" in
  ai) PROFILE=gpu ;;
  k8s) PROFILE=standard ;;
  *) PROFILE=gpu ;;
  esac
fi
require_tools jq

load_versions
[ -z "$SUITE_SHA_OVERRIDE" ] || export SUITE_SHA=$SUITE_SHA_OVERRIDE

TIMESTAMP=$(date -u +%Y-%m-%dT%H-%MZ)
mkdir -p "$OUT_ROOT/$TIMESTAMP"
OUT=$(cd "$OUT_ROOT/$TIMESTAMP" && pwd)
SUBMISSION="$OUT/submission"
DEBUG="$OUT/debug"
mkdir -p "$SUBMISSION" "$DEBUG"
export TIMINGS="$DEBUG/timings.csv"
: >"$TIMINGS"
export KUBECONFIG="$OUT/kubeconfig"

GPU_NODE=''
PRODUCT_VERSION=''
INFRA=''

print_summary() {
  echo
  echo "$PRODUCT ${PRODUCT_VERSION:-$VERSION} · $SUITE · suite ${SUITE_SHA:0:7} · ${INFRA:-no cluster}"
  if [ -f "$DEBUG/suite.json" ]; then
    jq -r '.tests | to_entries[] | "\(.key)\t\(.value)"' "$DEBUG/suite.json" | awk -F'\t' '{printf "%-36s %s\n", $1, $2}'
  else
    echo "suite did not run"
  fi
  if [ "$KEEP_CLUSTER" = y ]; then
    echo "artifacts: $OUT/  ·  cluster kept (kubeconfig: $KUBECONFIG)"
  else
    echo "artifacts: $OUT/  ·  down issued for run $RUN_ID"
  fi
}

write_run_metadata() {
  local url=''
  [ -z "${GITHUB_SERVER_URL:-}" ] || url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  jq -n \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg run_id "$RUN_ID" --arg product "$PRODUCT" --arg suite "$SUITE" --arg profile "$PROFILE" \
    --arg requested "$VERSION" --arg url "$url" \
    --slurpfile provision <(cat "$DEBUG/provision.json" 2>/dev/null || echo null) \
    --slurpfile suite_json <(cat "$DEBUG/suite.json" 2>/dev/null || echo null) \
    --argjson timings "$(timings_json "$TIMINGS")" \
    '{
      date: $date, run_id: $run_id, product: $product, suite: $suite, profile: $profile,
      requested_version: $requested, workflow_run: (if $url == "" then null else $url end),
      provision: $provision[0], suite_result: $suite_json[0], timings_s: $timings
    }' >"$OUT/run-metadata.json"
}

on_exit() {
  local rc=$1
  trap - EXIT
  set +e
  log "cleanup (rc=$rc)"
  collect_cluster_state "$DEBUG/cluster-state" "$GPU_NODE"
  write_run_metadata
  if [ "$KEEP_CLUSTER" != y ]; then
    "$PROVISIONER" down --run-id "$RUN_ID" --out "$OUT" || log "down failed; clean up run $RUN_ID manually"
    rm -f "$KUBECONFIG"
    rm -rf "$OUT/ssh"
  fi
  # Failed runs must not be submitted by accident.
  if [ "$rc" -ne 0 ] && [ -n "$(ls -A "$SUBMISSION" 2>/dev/null)" ]; then
    mv "$SUBMISSION" "$OUT/failed"
  fi
  rmdir "$SUBMISSION" 2>/dev/null
  print_summary
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || rc=1
  exit "$rc"
}
trap 'on_exit $?' EXIT

provision_up() {
  local args=(up --run-id "$RUN_ID" --out "$OUT" --profile "$PROFILE" --version "$VERSION")
  [ -z "$LOCATION" ] || args+=(--location "$LOCATION")
  "$PROVISIONER" "${args[@]}"
  # shellcheck source=/dev/null
  . "$OUT/cluster.env"
}

run_suite() {
  local args=(--cluster-env "$OUT/cluster.env" --out "$OUT")
  [ -z "$SUITE_SHA_OVERRIDE" ] || args+=(--suite-sha "$SUITE_SHA_OVERRIDE")
  "$SUITE_RUNNER" "${args[@]}"
}

log "run $RUN_ID: product=$PRODUCT suite=$SUITE version=$VERSION profile=$PROFILE artifacts=$OUT"
provision_up
run_suite
