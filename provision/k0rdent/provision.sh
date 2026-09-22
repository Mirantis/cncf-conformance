#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Mirantis, Inc.
# SPDX-License-Identifier: Apache-2.0

# k0rdent provisioner: an ephemeral kind management cluster running k0rdent (kcm),
# which deploys an Azure child cluster through a ClusterDeployment. The child is the
# cluster under test. See README.md and ../README.md for the contract.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$HERE/../../lib/common.sh"

print_usage() {
  cat <<USAGE
Usage: $0 deps
       $0 up   --run-id ID --out DIR [--profile gpu|standard] [--version V] [--location L]
       $0 down --run-id ID [--out DIR]

up      Creates kind cluster conformance-k0rdent-ID, installs kcm, deploys the Azure
        ClusterDeployment conformance-k0rdent-ID (Azure resource group of the same
        name) and writes DIR/cluster.env, DIR/kubeconfig, DIR/mgmt/kubeconfig and
        DIR/debug/provision.json.
down    Deletes the ClusterDeployment, the resource group and the kind cluster
        (idempotent; needs only the run id).
deps    Installs kind at the version in versions.env (Linux runners).

  --version V   main      kcm built from main: newest staging chart
                          oci://ghcr.io/k0rdent/kcm/staging/kcm whose version matches
                          a recent main commit
                stable    latest k0rdent release (default)
                vX.Y.Z    a k0rdent release
  --profile     gpu       1 control plane + 1 NVIDIA T4 worker (default)
                standard  3 control planes + 2 workers
  --location    Azure location with NCASv3_T4 quota (default: southindia)

Environment: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET (service principal used by the
             Azure provider; required), AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
             (default: the az CLI's current account), K0S_VERSION (override the
             child k0s version pinned by the template), CONTROL_PLANE_SIZE
             (Standard_A4_v2), WORKER_SIZE (gpu: Standard_NC4as_T4_v3,
             standard: Standard_A4_v2)
USAGE
}

SUBCOMMAND=${1:-}
[ $# -eq 0 ] || shift
RUN_ID=''
OUT=''
PROFILE=gpu
VERSION=stable
LOCATION=southindia

while [ $# -gt 0 ]; do
  case "$1" in
  --run-id) RUN_ID=$2; shift 2 ;;
  --out) OUT=$2; shift 2 ;;
  --profile) PROFILE=$2; shift 2 ;;
  --version) VERSION=$2; shift 2 ;;
  --location) LOCATION=$2; shift 2 ;;
  -h | --help) print_usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
  esac
done

load_versions

PRODUCT=k0rdent
NAME="conformance-k0rdent-${RUN_ID}" # kind cluster, ClusterDeployment and Azure resource group
KCM_NAMESPACE=kcm-system
RELEASE_CHART=oci://ghcr.io/k0rdent/kcm/charts/kcm
STAGING_CHART=oci://ghcr.io/k0rdent/kcm/staging/kcm
KCM_REPO=https://github.com/k0rdent/kcm
CONTROL_PLANE_SIZE=${CONTROL_PLANE_SIZE:-Standard_A4_v2}
K0S_VERSION=${K0S_VERSION:-}

case "$PROFILE" in
gpu)
  CONTROL_PLANE_NUMBER=1
  WORKERS_NUMBER=1
  WORKER_SIZE=${WORKER_SIZE:-Standard_NC4as_T4_v3}
  ;;
standard)
  CONTROL_PLANE_NUMBER=3
  WORKERS_NUMBER=2
  WORKER_SIZE=${WORKER_SIZE:-Standard_A4_v2}
  ;;
*) die "--profile must be gpu or standard (got '$PROFILE')" 2 ;;
esac

SOURCE=''
CHART=''
CHART_VERSION=''
MAIN_HEAD_SHA=''
TEMPLATE=''
RELEASE=''
GPU_NODE=''
MGMT_KUBECONFIG=''

# ---------- deps ----------

cmd_deps() {
  local want="$KIND_VERSION" have=''
  command -v kind >/dev/null 2>&1 && have=$(kind version 2>/dev/null | awk '{print $2}')
  if [ "$have" = "$want" ]; then
    log "kind $have present"
  elif [ "$(uname -s)" = Linux ]; then
    log "installing kind $want"
    curl --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors -sSLfo /tmp/kind \
      "https://github.com/kubernetes-sigs/kind/releases/download/$want/kind-linux-amd64"
    chmod +x /tmp/kind
    sudo mv /tmp/kind /usr/local/bin/kind
  elif [ -n "$have" ]; then
    log "warning: kind $have found, pipeline pins $want; install it manually on $(uname -s) to match"
  else
    die "kind $want required; install it manually on $(uname -s)" 2
  fi
  kind version
}

# ---------- up ----------

# Management-cluster kubectl. The child cluster's kubeconfig is $KUBECONFIG.
mk() { kubectl --kubeconfig "$MGMT_KUBECONFIG" "$@"; }

chart_exists() { helm show chart "$1" --version "$2" >/dev/null 2>&1; }

# The staging build tags charts with `git describe --tags --always` (minus the "v"),
# whose abbreviation length git picks by repository size. Walk recent main commits,
# newest first, and probe the plausible spellings until a chart answers.
find_staging_chart() {
  local repo="$WORK/kcm.git" commit describe abbrev version
  git clone -q --bare --filter=tree:0 "$KCM_REPO" "$repo"
  for commit in $(git -C "$repo" rev-list -n 15 HEAD); do
    for abbrev in 7 8 9 10 11 12; do
      describe=$(git -C "$repo" describe --tags --always --abbrev="$abbrev" "$commit")
      version=${describe#v}
      if chart_exists "$STAGING_CHART" "$version"; then
        CHART_VERSION=$version
        MAIN_HEAD_SHA=$commit
        return 0
      fi
    done
    log "no staging chart for kcm main commit ${commit:0:12}; trying its parent"
  done
  die "no staging chart found for the last 15 commits of k0rdent/kcm main"
}

resolve_version() {
  case "$VERSION" in
  main)
    SOURCE=main
    CHART=$STAGING_CHART
    find_staging_chart
    ;;
  stable)
    SOURCE=release
    CHART=$RELEASE_CHART
    VERSION=$(curl -sSfL https://api.github.com/repos/k0rdent/kcm/releases/latest | jq -r .tag_name)
    [ -n "$VERSION" ] && [ "$VERSION" != null ] || die "failed to resolve the latest k0rdent release"
    CHART_VERSION=${VERSION#v}
    ;;
  v[0-9]* | [0-9]*)
    SOURCE=release
    CHART=$RELEASE_CHART
    CHART_VERSION=${VERSION#v}
    chart_exists "$CHART" "$CHART_VERSION" || die "no k0rdent release chart $CHART_VERSION at $CHART"
    ;;
  *) die "--version must be main, stable or a release tag (got '$VERSION')" 2 ;;
  esac
  VERSION="v$CHART_VERSION"
  log "k0rdent $VERSION, source=$SOURCE, chart=$CHART"
}

# The Azure provider runs inside the management cluster and authenticates with a
# service principal, so the OIDC login of the az CLI is not enough on its own.
resolve_azure_identity() {
  : "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID must be set to the application id of the service principal}"
  : "${AZURE_CLIENT_SECRET:?AZURE_CLIENT_SECRET must be set to the secret of the service principal}"
  AZURE_TENANT_ID=${AZURE_TENANT_ID:-$(az account show --query tenantId -o tsv)}
  AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}
  export AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID
  log "azure subscription $AZURE_SUBSCRIPTION_ID, service principal ${AZURE_CLIENT_ID:0:8}…"
}

create_management_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
    log "kind cluster $NAME already exists"
    kind get kubeconfig --name "$NAME" >"$MGMT_KUBECONFIG"
  else
    kind create cluster --name "$NAME" --kubeconfig "$MGMT_KUBECONFIG" --wait 120s
  fi
  mk get nodes -o wide
}

management_ready() {
  mk -n "$KCM_NAMESPACE" get management kcm -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True
}

azure_template_valid() {
  TEMPLATE=$(mk -n "$KCM_NAMESPACE" get clustertemplate -o json 2>/dev/null |
    jq -r '[.items[] | select(.metadata.name | startswith("azure-standalone-cp")) | select(.status.valid == true) | .metadata.name] | sort | last // empty')
  [ -n "$TEMPLATE" ]
}

release_exists() {
  RELEASE=$(mk get release -o name 2>/dev/null | sed 's|^release.k0rdent.mirantis.com/||' | head -n1)
  [ -n "$RELEASE" ]
}

install_kcm() {
  # createManagement=false: the chart's default Management enables every CAPI
  # provider, far more than a kind cluster on a runner can run. manifests/management.yaml
  # names only the providers an Azure child needs.
  # Re-running "helm upgrade" on an existing release conflicts with the fields kcm's
  # own helm-controller manages, so an existing release is left alone (laptop reruns
  # against a kept cluster; a fresh kind cluster never has one).
  if helm status kcm --kubeconfig "$MGMT_KUBECONFIG" -n "$KCM_NAMESPACE" >/dev/null 2>&1; then
    log "kcm release already present; skipping install"
  else
    helm install kcm "$CHART" --version "$CHART_VERSION" \
      --kubeconfig "$MGMT_KUBECONFIG" -n "$KCM_NAMESPACE" --create-namespace \
      --set controller.createManagement=false \
      --wait --timeout 15m -o json | jq -r '"kcm chart " + .chart.metadata.version + " " + .info.status'
  fi
  wait_for 300 release_exists || die 'kcm did not create its Release object'
  export RELEASE
  render "$HERE/manifests/management.yaml" | tee "$OUT/debug/management.yaml" | mk apply -f - >/dev/null
  log "Management created for release $RELEASE"
  # The Management object installs the CAPI providers; the Azure ClusterTemplates
  # become valid once the Azure provider is up.
  wait_for 900 management_ready || {
    mk get management kcm -o yaml >"$OUT/debug/management-status.yaml" 2>&1 || true
    mk get pods -A -o wide >"$OUT/debug/kcm-pods.txt" 2>&1 || true
    die 'kcm Management did not become Ready'
  }
  wait_for 300 azure_template_valid || die 'no valid azure-standalone-cp ClusterTemplate'
  log "kcm ready; cluster template $TEMPLATE"
  mk -n "$KCM_NAMESPACE" get pods -o wide >"$OUT/debug/kcm-pods.txt"
}

# render FILE — expand only the ${VARIABLES} the manifests use
render() {
  # shellcheck disable=SC2016 # literal variable names are the envsubst filter
  envsubst '${RELEASE} ${NAME} ${TEMPLATE} ${LOCATION} ${AZURE_SUBSCRIPTION_ID} ${AZURE_CLIENT_ID} ${AZURE_TENANT_ID} ${AZURE_CLIENT_SECRET} ${CONTROL_PLANE_NUMBER} ${WORKERS_NUMBER} ${CONTROL_PLANE_SIZE} ${WORKER_SIZE} ${K0S_BLOCK}' <"$1"
}

apply_credentials() {
  # The secret must not land in the artifacts; render straight into kubectl.
  render "$HERE/manifests/credentials.yaml" | mk apply -f - >/dev/null
  mk -n "$KCM_NAMESPACE" get credential azure-cluster-identity-cred -o wide
}

clusterdeployment_ready() {
  mk -n "$KCM_NAMESPACE" get clusterdeployment "$NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True
}

clusterdeployment_status() {
  mk -n "$KCM_NAMESPACE" get clusterdeployment "$NAME" -o json 2>/dev/null |
    jq -r '[.status.conditions[]? | select(.status != "True") | .type + "=" + .status + (if .message then " (" + (.message | .[0:80]) + ")" else "" end)] | join("; ")'
}

# wait_for_clusterdeployment SECONDS — like wait_for, with a status line every minute
wait_for_clusterdeployment() {
  local deadline i=0
  deadline=$(($(date +%s) + $1))
  until clusterdeployment_ready; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      log "timed out after $1 s waiting for ClusterDeployment $NAME"
      return 1
    }
    i=$((i + 1))
    [ $((i % 6)) -ne 0 ] || log "waiting: $(clusterdeployment_status)"
    sleep 10
  done
}

deploy_cluster() {
  K0S_BLOCK=''
  [ -z "$K0S_VERSION" ] || K0S_BLOCK=$'k0s:\n      version: '"$K0S_VERSION"
  export NAME TEMPLATE LOCATION CONTROL_PLANE_NUMBER WORKERS_NUMBER CONTROL_PLANE_SIZE WORKER_SIZE K0S_BLOCK
  render "$HERE/manifests/clusterdeployment.yaml" >"$OUT/debug/clusterdeployment.yaml"
  mk apply -f "$OUT/debug/clusterdeployment.yaml"
  wait_for_clusterdeployment 2700 || {
    mk -n "$KCM_NAMESPACE" describe clusterdeployment "$NAME" >"$OUT/debug/clusterdeployment-describe.txt" 2>&1 || true
    die "ClusterDeployment $NAME did not become Ready: $(clusterdeployment_status)"
  }
  mk -n "$KCM_NAMESPACE" get clusterdeployment "$NAME"
}

# Every node Ready and initialised by the cloud controller manager (no
# "uninitialized" taint). Control planes keep their control-plane taint.
nodes_ready() {
  local want=$((CONTROL_PLANE_NUMBER + WORKERS_NUMBER)) ready
  ready=$(kubectl get nodes -o json 2>/dev/null |
    jq '[.items[] | select([.spec.taints[]?.key] | index("node.cloudprovider.kubernetes.io/uninitialized") | not) | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')
  [ "${ready:-0}" -eq "$want" ]
}

fetch_kubeconfig() {
  mk -n "$KCM_NAMESPACE" get secret "$NAME-kubeconfig" -o jsonpath='{.data.value}' | base64 -d >"$KUBECONFIG"
  [ -s "$KUBECONFIG" ] || die 'empty child kubeconfig'
  chmod 600 "$KUBECONFIG"
  wait_for 300 api_reachable || die 'child API server not reachable from this machine'
  wait_for 900 nodes_ready || {
    kubectl get nodes -o wide || true
    die "not all $((CONTROL_PLANE_NUMBER + WORKERS_NUMBER)) nodes are Ready and initialised"
  }
  kubectl get nodes -o wide
  if [ "$PROFILE" = gpu ]; then
    # Workers come from the MachineDeployment "<name>-md"; control planes are "<name>-cp-N".
    GPU_NODE=$(kubectl get nodes -o name | sed 's|^node/||' | grep -- "^$NAME-md-" | head -n1)
    [ -n "$GPU_NODE" ] || die 'no worker node found for GPU_NODE'
  fi
}

write_outputs() {
  local k8s kernel containerd k0s kind_node worker_node
  worker_node=${GPU_NODE:-$(kubectl get nodes -o name | sed 's|^node/||' | grep -- "^$NAME-md-" | head -n1)}
  k8s=$(kubectl version -o json | jq -r .serverVersion.gitVersion)
  k0s=$(kubectl get node "$worker_node" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
  kernel=$(kubectl get node "$worker_node" -o jsonpath='{.status.nodeInfo.kernelVersion}')
  containerd=$(kubectl get node "$worker_node" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
  kind_node=$(mk get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
  write_env "$OUT/cluster.env" \
    "PRODUCT=$PRODUCT" \
    "PRODUCT_VERSION=$VERSION" \
    "KUBECONFIG=$KUBECONFIG" \
    "GPU_NODE=$GPU_NODE" \
    "INFRA=azure $LOCATION $WORKER_SIZE via k0rdent $TEMPLATE"
  jq -n \
    --arg product "$PRODUCT" --arg version "$VERSION" --arg source "$SOURCE" \
    --arg chart "$CHART" --arg chart_version "$CHART_VERSION" --arg main_sha "$MAIN_HEAD_SHA" \
    --arg template "$TEMPLATE" --arg k8s "$k8s" --arg k0s "$k0s" \
    --arg kernel "$kernel" --arg containerd "$containerd" \
    --arg kind "$(kind version | awk '{print $2}')" --arg kind_node "$kind_node" \
    --arg location "$LOCATION" --arg rg "$NAME" --arg profile "$PROFILE" \
    --argjson cps "$CONTROL_PLANE_NUMBER" --argjson workers "$WORKERS_NUMBER" \
    --arg cp_size "$CONTROL_PLANE_SIZE" --arg worker_size "$WORKER_SIZE" \
    '{
      product: $product, version: $version, source: $source,
      chart: {url: $chart, version: $chart_version},
      main_build: (if $main_sha == "" then null else {repo: "k0rdent/kcm", head_sha: $main_sha} end),
      cluster_template: $template, kubernetes_version: $k8s, k0s: $k0s, containerd: $containerd,
      management: {kind: $kind, kubernetes_version: $kind_node},
      infra: {cloud: "azure", location: $location, resource_group: $rg, profile: $profile,
              control_planes: $cps, workers: $workers,
              control_plane_size: $cp_size, worker_size: $worker_size, kernel: $kernel}
    }' >"$OUT/debug/provision.json"
  cat "$OUT/cluster.env"
}

cmd_up() {
  [ -n "$RUN_ID" ] || die '--run-id is required' 2
  [ -n "$OUT" ] || die '--out is required' 2
  require_tools az kind helm kubectl jq curl git envsubst
  az account show --query id -o tsv >/dev/null || die 'az is not logged in' 2

  OUT=$(cd "$OUT" && pwd)
  MGMT_KUBECONFIG="$OUT/mgmt/kubeconfig"
  WORK=$(mktemp -d)
  export KUBECONFIG="$OUT/kubeconfig"
  mkdir -p "$OUT/debug" "$OUT/mgmt"
  trap 'stage_abort $?; rm -rf "$WORK"' EXIT

  stage k0rdent-resolve-version resolve_version
  stage k0rdent-azure-identity resolve_azure_identity
  stage k0rdent-kind create_management_cluster
  stage k0rdent-kcm install_kcm
  stage k0rdent-credentials apply_credentials
  stage k0rdent-clusterdeployment deploy_cluster
  stage k0rdent-child-kubeconfig fetch_kubeconfig
  stage k0rdent-outputs write_outputs
}

# ---------- down ----------

rg_gone() { [ "$(az group exists -n "$NAME")" != true ]; }

cmd_down() {
  [ -n "$RUN_ID" ] || die '--run-id is required' 2
  require_tools az kind kubectl
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
    MGMT_KUBECONFIG="$WORK/kubeconfig"
    kind get kubeconfig --name "$NAME" >"$MGMT_KUBECONFIG" 2>/dev/null || true
    if mk -n "$KCM_NAMESPACE" get clusterdeployment "$NAME" -o name >/dev/null 2>&1; then
      # Let k0rdent tear the child down itself; the resource group goes with it.
      mk -n "$KCM_NAMESPACE" delete clusterdeployment "$NAME" --wait=false --timeout=60s || true
      log "delete issued for ClusterDeployment $NAME; waiting for its resource group"
      wait_for 900 rg_gone || log "resource group $NAME still exists after 15 min; deleting it directly"
    fi
    kind delete cluster --name "$NAME"
    log "kind cluster $NAME deleted"
  else
    log "kind cluster $NAME does not exist"
  fi
  if rg_gone; then
    log "resource group $NAME does not exist"
  else
    az group delete -n "$NAME" --yes --no-wait -o none
    log "delete issued for resource group $NAME"
  fi
  [ -z "$OUT" ] || rm -rf "$OUT/mgmt"
}

case "$SUBCOMMAND" in
deps) cmd_deps ;;
up) cmd_up ;;
down) cmd_down ;;
-h | --help | help) print_usage ;;
*) print_usage >&2; exit 2 ;;
esac
