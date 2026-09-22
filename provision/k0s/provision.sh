#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Mirantis, Inc.
# SPDX-License-Identifier: Apache-2.0

# k0s provisioner: two Azure VMs (one controller, one NVIDIA T4 worker) bootstrapped
# with k0sctl. See README.md and ../README.md for the contract.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$HERE/../../lib/common.sh"

print_usage() {
  cat <<USAGE
Usage: $0 deps
       $0 up   --run-id ID --out DIR [--profile gpu] [--version V] [--location L]
       $0 down --run-id ID [--out DIR]

up      Creates resource group conformance-k0s-ID with a k0s cluster and writes
        DIR/cluster.env, DIR/kubeconfig, DIR/ssh/ and DIR/debug/provision.json.
down    Deletes the resource group (idempotent; needs only the run id).
deps    Installs k0sctl at the version in versions.env (Linux runners).

  --version V   main      k0s built from main: \$K0S_BINARY if set, else the
                          k0s-linux-amd64 artifact of the latest green main build (needs gh)
                stable    current stable release (default)
                vX.Y.Z+k0s.N  a release tag
                /path/to/k0s  a local linux/amd64 binary to upload
  --profile     gpu (only profile k0s supports)
  --location    Azure location with NCASv3_T4 quota (default: southindia)

Environment: CONTROLLER_SIZE (Standard_D2s_v3), WORKER_SIZE (Standard_NC4as_T4_v3),
             VM_IMAGE (Canonical:ubuntu-24_04-lts:server:latest), K0S_BINARY
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

CONTROLLER_SIZE=${CONTROLLER_SIZE:-Standard_D2s_v3}
WORKER_SIZE=${WORKER_SIZE:-Standard_NC4as_T4_v3}
VM_IMAGE=${VM_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}
K0S_BINARY=${K0S_BINARY:-}

PRODUCT=k0s
RG="conformance-k0s-${RUN_ID}"
VNET=conformance-vnet
SUBNET=conformance-subnet
NSG=conformance-nsg
ROUTE_TABLE=conformance-routes
CONTROLLER_VM=k0s-controller-0
WORKER_VM=k0s-gpu-0
CONTROLLER_PRIVATE_IP=10.0.1.4
WORKER_PRIVATE_IP=10.0.1.5
ADMIN_USER=ubuntu

CONTROLLER_IP=''
WORKER_IP=''
SOURCE=''
BINARY_VERSION_KNOWN=n
MAIN_RUN_ID=''
MAIN_HEAD_SHA=''

# ---------- deps ----------

cmd_deps() {
  local want="v$K0SCTL_VERSION" have=''
  command -v k0sctl >/dev/null 2>&1 && have=$(k0sctl version 2>/dev/null | awk '/^version:/ {print $2}')
  if [ "$have" = "$want" ]; then
    log "k0sctl $have present"
  elif [ "$(uname -s)" = Linux ]; then
    log "installing k0sctl $want"
    curl --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors -sSLfo /tmp/k0sctl \
      "https://github.com/k0sproject/k0sctl/releases/download/$want/k0sctl-linux-amd64"
    chmod +x /tmp/k0sctl
    sudo mv /tmp/k0sctl /usr/local/bin/k0sctl
  elif [ -n "$have" ]; then
    log "warning: k0sctl $have found, pipeline pins $want; install it manually on $(uname -s) to match"
  else
    die "k0sctl $want required; install it manually on $(uname -s)" 2
  fi
  k0sctl version
}

# ---------- up ----------

ssh_cmd() {
  local host=$1
  shift
  ssh -i "$SSH_KEY" -o UserKnownHostsFile="$SSH_DIR/known_hosts" -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 -o BatchMode=yes "$ADMIN_USER@$host" "$@"
}

# Newest unexpired k0s-linux-amd64 artifact from a green run on main. The runs
# endpoint filtered by status returns stale results; the artifacts endpoint does not.
find_main_build() {
  local run sha conclusion
  while read -r run sha; do
    [ -n "$run" ] || continue
    conclusion=$(gh api "repos/k0sproject/k0s/actions/runs/$run" -q '.conclusion // "in progress"')
    if [ "$conclusion" = success ]; then
      MAIN_RUN_ID=$run
      MAIN_HEAD_SHA=$sha
      return 0
    fi
    log "skipping k0s main run $run (${sha:0:12}): $conclusion"
  done < <(gh api "repos/k0sproject/k0s/actions/artifacts?name=k0s-linux-amd64&per_page=20" \
    -q '.artifacts[] | select(.expired == false and .workflow_run.head_branch == "main") | "\(.workflow_run.id) \(.workflow_run.head_sha)"')
  die "no green main build of k0sproject/k0s with a k0s-linux-amd64 artifact found"
}

resolve_version() {
  case "$VERSION" in
  main)
    SOURCE=main
    if [ -z "$K0S_BINARY" ]; then
      require_tools gh
      find_main_build
      log "downloading k0s-linux-amd64 from k0sproject/k0s run $MAIN_RUN_ID (${MAIN_HEAD_SHA:0:12})"
      gh run download "$MAIN_RUN_ID" -R k0sproject/k0s -n k0s-linux-amd64 -D "$WORK/k0s-main"
      K0S_BINARY="$WORK/k0s-main/k0s"
    fi
    ;;
  stable)
    SOURCE=release
    VERSION=$(curl -sSfL https://docs.k0sproject.io/stable.txt)
    [ -n "$VERSION" ] || die "failed to resolve the stable k0s version"
    ;;
  v*)
    SOURCE=release
    ;;
  *)
    [ -f "$VERSION" ] || die "--version must be main, stable, a tag or a path to a binary (got '$VERSION')" 2
    SOURCE=binary
    K0S_BINARY=$VERSION
    ;;
  esac
  if [ -n "$K0S_BINARY" ]; then
    [ -f "$K0S_BINARY" ] || die "k0s binary not found: $K0S_BINARY"
    chmod +x "$K0S_BINARY"
    # On Linux the binary tells its own version; elsewhere it is read from the controller after apply.
    if [ "$(uname -s)" = Linux ] && VERSION=$("$K0S_BINARY" version 2>/dev/null) && [ -n "$VERSION" ]; then
      BINARY_VERSION_KNOWN=y
    fi
    if [ "$BINARY_VERSION_KNOWN" = y ]; then
      log "k0s binary: $K0S_BINARY ($(du -h "$K0S_BINARY" | cut -f1)), source=$SOURCE, version=$VERSION"
    else
      log "k0s binary: $K0S_BINARY ($(du -h "$K0S_BINARY" | cut -f1)), source=$SOURCE, version read from the controller after apply"
    fi
  else
    log "k0s version: $VERSION, source=$SOURCE"
  fi
}

# The NSG is bound to the subnet, not to the NICs: 'az vm create --nsg NAME' may
# re-create an NSG of that name through its own deployment and drop the rules.
provision_network() {
  az group create -n "$RG" -l "$LOCATION" -o none
  az network nsg create -g "$RG" -n "$NSG" -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-ssh --priority 100 \
    --destination-port-ranges 22 --access Allow --protocol Tcp -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-k8s-api --priority 110 \
    --destination-port-ranges 6443 --access Allow --protocol Tcp -o none
  az network vnet create -g "$RG" -n "$VNET" --address-prefix 10.0.0.0/16 \
    --subnet-name "$SUBNET" --subnet-prefix 10.0.1.0/24 --nsg "$NSG" -o none
}

verify_network() {
  local bound
  bound=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SUBNET" \
    --query 'networkSecurityGroup.id' -o tsv 2>/dev/null)
  [ "${bound##*/}" = "$NSG" ] || die "subnet $SUBNET is not bound to NSG $NSG"
  az network nsg rule show -g "$RG" --nsg-name "$NSG" -n allow-k8s-api -o none ||
    die "NSG rule allow-k8s-api (6443) is missing from $NSG"
  log "NSG $NSG bound to subnet with ssh + 6443 rules"
}

create_vm() {
  local name=$1 size=$2 private_ip=$3
  if az vm show -g "$RG" -n "$name" -o none 2>/dev/null; then
    log "$name already exists"
    return 0
  fi
  az vm create -g "$RG" -n "$name" --image "$VM_IMAGE" --size "$size" \
    --admin-username "$ADMIN_USER" --ssh-key-values "$SSH_KEY.pub" \
    --vnet-name "$VNET" --subnet "$SUBNET" --nsg "" \
    --public-ip-sku Standard --private-ip-address "$private_ip" \
    --no-wait -o none 2> >(grep -v '^WARNING' >&2)
}

provision_vms() {
  [ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "$RG" -f "$SSH_KEY"
  create_vm "$CONTROLLER_VM" "$CONTROLLER_SIZE" "$CONTROLLER_PRIVATE_IP"
  create_vm "$WORKER_VM" "$WORKER_SIZE" "$WORKER_PRIVATE_IP"
  az vm wait -g "$RG" -n "$CONTROLLER_VM" --created
  az vm wait -g "$RG" -n "$WORKER_VM" --created
  CONTROLLER_IP=$(az vm show -g "$RG" -n "$CONTROLLER_VM" -d --query publicIps -o tsv)
  WORKER_IP=$(az vm show -g "$RG" -n "$WORKER_VM" -d --query publicIps -o tsv)
  write_env "$OUT/debug/hosts.env" "CONTROLLER_IP=$CONTROLLER_IP" "WORKER_IP=$WORKER_IP"
  log "controller $CONTROLLER_IP ($CONTROLLER_PRIVATE_IP), worker $WORKER_IP ($WORKER_PRIVATE_IP)"
}

set_pod_route() {
  local node=$1 cidr=$2 next_hop=$3
  az network route-table route create -g "$RG" --route-table-name "$ROUTE_TABLE" \
    -n "pods-$node" --address-prefix "$cidr" \
    --next-hop-type VirtualAppliance --next-hop-ip-address "$next_hop" -o none 2>/dev/null ||
    az network route-table route update -g "$RG" --route-table-name "$ROUTE_TABLE" \
      -n "pods-$node" --address-prefix "$cidr" --next-hop-ip-address "$next_hop" -o none
}

# Azure needs IP forwarding and a route per pod CIDR for pod traffic to flow.
provision_routes() {
  local vm nic_id
  for vm in "$CONTROLLER_VM" "$WORKER_VM"; do
    nic_id=$(az vm show -g "$RG" -n "$vm" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
    az network nic update --ids "$nic_id" --ip-forwarding true -o none
  done
  az network route-table create -g "$RG" -n "$ROUTE_TABLE" -l "$LOCATION" -o none
  set_pod_route "$CONTROLLER_VM" 10.244.0.0/24 "$CONTROLLER_PRIVATE_IP"
  set_pod_route "$WORKER_VM" 10.244.1.0/24 "$WORKER_PRIVATE_IP"
  az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SUBNET" --route-table "$ROUTE_TABLE" -o none
}

ssh_reachable() { ssh_cmd "$1" true 2>/dev/null; }

wait_for_ssh() {
  local ip
  # Azure recycles public IPs and k0sctl reads ~/.ssh/known_hosts.
  for ip in "$CONTROLLER_IP" "$WORKER_IP"; do
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    wait_for 300 sh -c "ssh-keyscan -T 10 '$ip' 2>/dev/null | grep -q ."
    ssh-keyscan -T 10 "$ip" 2>/dev/null | grep -v '^#' | tee -a "$SSH_DIR/known_hosts" >>"$HOME/.ssh/known_hosts"
    wait_for 120 ssh_reachable "$ip"
  done
}

# The NVIDIA driver is built against the running kernel.
install_kernel_headers() {
  # shellcheck disable=SC2016 # $(uname -r) must expand on the remote host
  ssh_cmd "$WORKER_IP" 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-headers-$(uname -r)" >/dev/null'
}

k0sctl_host() {
  local address=$1 role=$2
  cat <<HOST
    - ssh:
        address: $address
        user: $ADMIN_USER
        keyPath: $SSH_KEY
      role: $role
HOST
  if [ -n "$K0S_BINARY" ]; then
    cat <<HOST
      uploadBinary: true
      k0sBinaryPath: $K0S_BINARY
HOST
  fi
}

k0sctl_apply() {
  {
    cat <<CFG
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: $RG
spec:
  hosts:
CFG
    k0sctl_host "$CONTROLLER_IP" controller+worker
    k0sctl_host "$WORKER_IP" worker
    cat <<CFG
  k0s:
CFG
    # With an uploaded binary of unknown version, k0sctl warns and skips the version check.
    if [ -z "$K0S_BINARY" ] || [ "$BINARY_VERSION_KNOWN" = y ]; then echo "    version: $VERSION"; fi
    cat <<CFG
    config:
      spec:
        telemetry:
          enabled: false
CFG
  } >"$OUT/debug/k0sctl.yaml"
  k0sctl apply --config "$OUT/debug/k0sctl.yaml" --kubeconfig-out "$KUBECONFIG" 2>&1 | tee "$OUT/debug/k0sctl.log" |
    grep -E 'level=(warn|error|fatal)' || true
  [ -s "$KUBECONFIG" ] || die 'k0sctl did not write a kubeconfig'
  wait_for 120 api_reachable ||
    die "API server not reachable on 6443 from this machine; check the NSG and the local network"
  if [ -n "$K0S_BINARY" ]; then
    VERSION=$(ssh_cmd "$CONTROLLER_IP" sudo /usr/local/bin/k0s version | tr -d '[:space:]')
    [ -n "$VERSION" ] || die 'could not read k0s version from the controller'
    log "k0s reports version $VERSION"
  fi
  kubectl get nodes -o wide
}

verify_pod_cidrs() {
  local node cidr next_hop
  while read -r node cidr; do
    case "$node" in
    "$CONTROLLER_VM") next_hop=$CONTROLLER_PRIVATE_IP ;;
    "$WORKER_VM") next_hop=$WORKER_PRIVATE_IP ;;
    *) die "unexpected node $node" ;;
    esac
    set_pod_route "$node" "$cidr" "$next_hop"
  done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.podCIDR}{"\n"}{end}')
}

write_outputs() {
  local k8s kernel containerd
  k8s=$(kubectl version -o json | jq -r .serverVersion.gitVersion)
  kernel=$(kubectl get node "$WORKER_VM" -o jsonpath='{.status.nodeInfo.kernelVersion}')
  containerd=$(kubectl get node "$WORKER_VM" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
  write_env "$OUT/cluster.env" \
    "PRODUCT=$PRODUCT" \
    "PRODUCT_VERSION=$VERSION" \
    "KUBECONFIG=$KUBECONFIG" \
    "GPU_NODE=$WORKER_VM" \
    "INFRA=azure $LOCATION $WORKER_SIZE"
  jq -n \
    --arg product "$PRODUCT" --arg version "$VERSION" --arg source "$SOURCE" \
    --arg main_run "$MAIN_RUN_ID" --arg main_sha "$MAIN_HEAD_SHA" \
    --arg k8s "$k8s" --arg kernel "$kernel" --arg containerd "$containerd" \
    --arg k0sctl "$(k0sctl version | awk '/^version:/ {print $2}')" \
    --arg location "$LOCATION" --arg rg "$RG" \
    --arg controller "$CONTROLLER_SIZE" --arg worker "$WORKER_SIZE" --arg image "$VM_IMAGE" \
    '{
      product: $product, version: $version, source: $source,
      main_build: (if $main_run == "" then null else {repo: "k0sproject/k0s", run_id: $main_run, head_sha: $main_sha} end),
      kubernetes_version: $k8s, containerd: $containerd, k0sctl: $k0sctl,
      infra: {cloud: "azure", location: $location, resource_group: $rg,
              controller_size: $controller, worker_size: $worker, image: $image, kernel: $kernel}
    }' >"$OUT/debug/provision.json"
  cat "$OUT/cluster.env"
}

cmd_up() {
  [ -n "$RUN_ID" ] || die '--run-id is required' 2
  [ -n "$OUT" ] || die '--out is required' 2
  [ "$PROFILE" = gpu ] || die "k0s supports only --profile gpu (got '$PROFILE')" 2
  require_tools az k0sctl kubectl jq curl ssh ssh-keygen ssh-keyscan
  az account show --query id -o tsv >/dev/null || die 'az is not logged in' 2

  OUT=$(cd "$OUT" && pwd)
  SSH_DIR="$OUT/ssh"
  SSH_KEY="$SSH_DIR/id_ed25519"
  WORK=$(mktemp -d)
  export KUBECONFIG="$OUT/kubeconfig"
  mkdir -p "$OUT/debug" "$SSH_DIR" "$HOME/.ssh"
  trap 'stage_abort $?; rm -rf "$WORK"' EXIT

  stage k0s-resolve-version resolve_version
  stage k0s-network provision_network
  stage k0s-vms provision_vms
  stage k0s-verify-network verify_network
  stage k0s-routes provision_routes
  stage k0s-ssh wait_for_ssh
  install_kernel_headers &
  local headers_pid=$!
  stage k0s-k0sctl-apply k0sctl_apply
  stage k0s-pod-cidrs verify_pod_cidrs
  stage k0s-kernel-headers wait "$headers_pid"
  stage k0s-outputs write_outputs
}

# ---------- down ----------

cmd_down() {
  [ -n "$RUN_ID" ] || die '--run-id is required' 2
  require_tools az
  if [ -n "$OUT" ] && [ -f "$OUT/debug/hosts.env" ]; then
    # shellcheck source=/dev/null
    . "$OUT/debug/hosts.env"
    for ip in ${CONTROLLER_IP:-} ${WORKER_IP:-}; do
      ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    done
  fi
  if [ "$(az group exists -n "$RG")" = true ]; then
    az group delete -n "$RG" --yes --no-wait -o none
    log "delete issued for resource group $RG"
  else
    log "resource group $RG does not exist"
  fi
}

case "$SUBCOMMAND" in
deps) cmd_deps ;;
up) cmd_up ;;
down) cmd_down ;;
-h | --help | help) print_usage ;;
*) print_usage >&2; exit 2 ;;
esac
