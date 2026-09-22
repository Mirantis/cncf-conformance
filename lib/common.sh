#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Mirantis, Inc.
# SPDX-License-Identifier: Apache-2.0

# Shared helpers. Source this file; do not execute it.
# Knows nothing about products, suites or clouds.

[ -z "${COMMON_SH_LOADED:-}" ] || return 0
COMMON_SH_LOADED=1

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export REPO_ROOT

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

# die MESSAGE [EXIT_CODE]
die() {
  log "error: $1"
  exit "${2:-1}"
}

# load_versions — export every KEY=VALUE from versions.env
load_versions() {
  set -a
  # shellcheck source=/dev/null
  . "$REPO_ROOT/versions.env"
  set +a
}

# require_tools TOOL... — exit 2 if any is missing
require_tools() {
  local missing='' tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  [ -z "$missing" ] || die "missing tools:$missing" 2
}

# stage NAME COMMAND... — run COMMAND, record "NAME,seconds,rc" in $TIMINGS if set.
# COMMAND is not wrapped in "||" so that errexit stays active inside it: a failing
# command aborts the script and the EXIT trap calls stage_abort to record the stage.
# "stage NAME CMD || true" still works: errexit is off in that context and the
# status of CMD is recorded and returned.
STAGE_NAME=''
STAGE_START=0
stage() {
  STAGE_NAME=$1
  shift
  STAGE_START=$(date +%s)
  log "==> $STAGE_NAME"
  "$@"
  stage_done $?
}

# stage_done RC — record the current stage's timing and status; returns RC
stage_done() {
  local rc=$1
  [ -z "${TIMINGS:-}" ] || printf '%s,%s,%s\n' "$STAGE_NAME" "$(($(date +%s) - STAGE_START))" "$rc" >>"$TIMINGS"
  [ "$rc" -eq 0 ] || log "!!! $STAGE_NAME failed (rc=$rc)"
  STAGE_NAME=''
  return "$rc"
}

# stage_abort RC — for EXIT traps: record the stage that was running when the script aborted
stage_abort() {
  [ -z "$STAGE_NAME" ] || stage_done "${1:-1}" || true
}

# wait_for SECONDS COMMAND... — poll every 10 s until COMMAND succeeds
wait_for() {
  local timeout=$1 deadline
  shift
  deadline=$(($(date +%s) + timeout))
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      log "timed out after ${timeout}s waiting for: $*"
      return 1
    }
    sleep 10
  done
}

# write_env FILE KEY=VALUE... — write a sourceable env file (values single-quoted)
write_env() {
  local file=$1 kv
  shift
  : >"$file"
  for kv in "$@"; do
    printf "%s='%s'\n" "${kv%%=*}" "${kv#*=}" >>"$file"
  done
}

# timings_json FILE — {"stage": seconds, ...} from a timings.csv
timings_json() {
  [ -s "$1" ] || { echo '{}'; return 0; }
  jq -R -n '[inputs | split(",") | {key: .[0], value: (.[1] | tonumber)}] | from_entries' "$1"
}

# api_reachable — true when the API server in $KUBECONFIG answers TCP+TLS within 5 s
api_reachable() {
  local server
  [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ] || return 1
  server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  [ -n "$server" ] || return 1
  curl -ksS -o /dev/null --connect-timeout 5 --max-time 10 "$server/livez" 2>/dev/null
}

# collect_cluster_state DIR [GPU_NODE] — generic post-mortem dump; never fails
collect_cluster_state() {
  local dir=$1 gpu_node=${2:-}
  [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ] || return 0
  api_reachable || { log "API server not reachable; skipping cluster-state dump"; return 0; }
  mkdir -p "$dir"
  local k="kubectl --request-timeout=30s"
  $k get nodes -o wide >"$dir/nodes.txt" 2>&1 || true
  $k get nodes -o yaml >"$dir/nodes.yaml" 2>&1 || true
  [ -z "$gpu_node" ] || $k describe node "$gpu_node" >"$dir/gpu-node-describe.txt" 2>&1 || true
  $k get all -A >"$dir/get-all.txt" 2>&1 || true
  $k get events -A --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1 || true
}
