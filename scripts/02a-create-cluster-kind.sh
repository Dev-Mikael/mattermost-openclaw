#!/usr/bin/env bash
# scripts/02a-create-cluster-kind.sh
# Creates a kind cluster for LOCAL DEV/TESTING.
# FIX: Properly extracts IPv4 subnet (not IPv6) from Docker network
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "02a — Create kind Cluster (Local Dev)"
require_tool kind
require_tool kubectl

CLUSTER_CONFIG="$ROOT_DIR/kind/kind-cluster.yaml"

# Patch cluster name
sed -i.bak "s/^name:.*/name: ${CLUSTER_NAME}/" "$CLUSTER_CONFIG"
rm -f "${CLUSTER_CONFIG}.bak"

# Delete existing cluster if present
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  log_warn "Existing kind cluster '${CLUSTER_NAME}' found."
  read -r -p "Delete and recreate? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    kind delete cluster --name "$CLUSTER_NAME"
    log_ok "Old cluster deleted"
  else
    log_info "Keeping existing cluster."
    exit 0
  fi
fi

log_step "Creating kind cluster: $CLUSTER_NAME"
kind create cluster \
  --name "$CLUSTER_NAME" \
  --config "$CLUSTER_CONFIG" \
  --wait 120s

log_ok "Cluster created"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ── FIXED: Extract IPv4 subnet specifically (not IPv6) ─────────
log_step "Detecting IPv4 Docker network subnet for MetalLB"

# Use python to reliably parse the JSON and find the IPv4 subnet
IPV4_SUBNET=$(docker network inspect kind 2>/dev/null | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for net in data:
    for cfg in net.get('IPAM', {}).get('Config', []):
        subnet = cfg.get('Subnet', '')
        # Skip IPv6 (contains ':')
        if ':' not in subnet and subnet:
            print(subnet)
            break
" 2>/dev/null || echo "")

if [[ -z "$IPV4_SUBNET" ]]; then
  # Fallback: grep for lines that look like IPv4 CIDRs
  IPV4_SUBNET=$(docker network inspect kind 2>/dev/null | \
    grep '"Subnet"' | grep -v ':' | head -1 | \
    sed 's/.*"Subnet": "\(.*\)".*/\1/' | tr -d ' ' || echo "")
fi

if [[ -z "$IPV4_SUBNET" ]]; then
  log_warn "Could not detect IPv4 subnet. Using fallback 172.18.0.0/16"
  IPV4_SUBNET="172.18.0.0/16"
fi

log_ok "Detected IPv4 subnet: $IPV4_SUBNET"

# Build MetalLB range from the upper end of the subnet
# e.g. 172.19.0.0/16 -> 172.19.255.200-172.19.255.250
BASE=$(echo "$IPV4_SUBNET" | cut -d'/' -f1)    # e.g. 172.19.0.0
PREFIX=$(echo "$BASE" | cut -d'.' -f1-2)        # e.g. 172.19
METALLB_IP_RANGE="${PREFIX}.255.200-${PREFIX}.255.250"

log_ok "MetalLB will use IP range: $METALLB_IP_RANGE"

# Write to .env
if grep -q "^METALLB_IP_RANGE=" "$ROOT_DIR/.env" 2>/dev/null; then
  sed -i.bak "s|^METALLB_IP_RANGE=.*|METALLB_IP_RANGE=${METALLB_IP_RANGE}|" "$ROOT_DIR/.env"
  rm -f "$ROOT_DIR/.env.bak"
else
  echo "METALLB_IP_RANGE=${METALLB_IP_RANGE}" >> "$ROOT_DIR/.env"
fi

log_ok "Written METALLB_IP_RANGE=${METALLB_IP_RANGE} to .env"
log_ok "kind cluster ready. Proceed with: scripts/03-bootstrap-flux.sh"
