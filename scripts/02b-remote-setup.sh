#!/usr/bin/env bash
# scripts/02b-remote-setup.sh
# ─────────────────────────────────────────────────────────────────────────────
# Remote kubeadm provisioner — called automatically by bootstrap.sh.
# You do NOT run this script manually.
#
# What it does (end-to-end, no manual SSH required):
#   1. Waits until SSH is available on the server (useful right after VPS launch)
#   2. Copies .env and all required scripts to the server, mirroring the
#      scripts/ directory structure so ROOT_DIR and SCRIPT_DIR resolve correctly
#   3. Runs the kubeadm setup remotely as root (streams output live)
#   4. Fetches kubeconfig back to ~/.kube/config on your local machine
#   5. Syncs METALLB_IP_RANGE and SERVER_PRIVATE_IP back into your local .env
#   6. Verifies the cluster is reachable via kubectl
#
# Required .env variables:
#   SSH_KEY_PATH  — path to the private key (.pem / id_rsa) for the server
#   SSH_USER      — SSH username (ubuntu/ec2-user/admin/root)
#   SERVER_IP     — public/elastic IP of the server
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY_PATH:-}"

# ── Validate SSH key ──────────────────────────────────────────────────────────
if [[ -z "$SSH_KEY" ]]; then
  log_error "SSH_KEY_PATH is not set in .env"
  echo ""
  echo "  Set SSH_KEY_PATH to the path of your private key, e.g.:"
  echo "    SSH_KEY_PATH=./my-server-key.pem       (relative to repo root)"
  echo "    SSH_KEY_PATH=/home/you/.ssh/id_rsa"
  exit 1
fi

# Resolve relative paths against repo root
if [[ "$SSH_KEY" != /* ]]; then
  SSH_KEY="$ROOT_DIR/$SSH_KEY"
fi

if [[ ! -f "$SSH_KEY" ]]; then
  log_error "SSH key not found: $SSH_KEY"
  echo "  Check SSH_KEY_PATH in .env — the file must exist before running bootstrap."
  exit 1
fi

chmod 600 "$SSH_KEY"

# Build SSH options string (no arrays — avoids quoting issues with scp)
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o BatchMode=yes -o ServerAliveInterval=30"

log_section "02b — Remote kubeadm Setup via SSH"
log_info "Target  : ${SSH_USER}@${SERVER_IP}"
log_info "SSH key : $SSH_KEY"

# ── Step 1: Wait for SSH ─────────────────────────────────────────────────────
log_step "Waiting for SSH on ${SERVER_IP} (up to 4 min — normal after VPS launch)..."
ATTEMPT=0
MAX_ATTEMPTS=24
until ssh $SSH_OPTS "${SSH_USER}@${SERVER_IP}" "echo ssh-ok" &>/dev/null; do
  ATTEMPT=$((ATTEMPT + 1))
  if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
    log_error "SSH not available after $((MAX_ATTEMPTS * 10))s."
    echo ""
    echo "  Checklist:"
    echo "    - SERVER_IP (${SERVER_IP}) is correct and the instance is running"
    echo "    - Security group allows port 22 inbound from your IP"
    echo "    - SSH_USER (${SSH_USER}) is correct for your OS:"
    echo "        AWS Ubuntu = ubuntu | Amazon Linux = ec2-user | Debian = admin"
    exit 1
  fi
  log_info "Attempt ${ATTEMPT}/${MAX_ATTEMPTS} — retrying in 10s..."
  sleep 10
done
log_ok "SSH connection established"

# ── Step 2: Copy files to server ─────────────────────────────────────────────
# IMPORTANT: Mirror the local scripts/ directory structure on the remote.
# 02b-setup-kubeadm.sh uses:
#   SCRIPT_DIR = dirname(BASH_SOURCE[0])
#   ROOT_DIR   = $SCRIPT_DIR/..
# So if the script lives at /tmp/mm-setup/scripts/02b-setup-kubeadm.sh:
#   SCRIPT_DIR = /tmp/mm-setup/scripts  ← correct
#   ROOT_DIR   = /tmp/mm-setup          ← correct, .env is here
# If placed flat at /tmp/mm-setup/02b-setup-kubeadm.sh:
#   ROOT_DIR   = /tmp                   ← WRONG, .env not found
log_step "Creating remote directory structure at /tmp/mm-setup/"
ssh $SSH_OPTS "${SSH_USER}@${SERVER_IP}" "mkdir -p /tmp/mm-setup/scripts/lib"

log_step "Copying files to server"

# .env goes at ROOT_DIR level
scp $SSH_OPTS "$ROOT_DIR/.env" \
  "${SSH_USER}@${SERVER_IP}:/tmp/mm-setup/.env"

# Script goes under scripts/ to mirror local layout
scp $SSH_OPTS "$SCRIPT_DIR/02b-setup-kubeadm.sh" \
  "${SSH_USER}@${SERVER_IP}:/tmp/mm-setup/scripts/02b-setup-kubeadm.sh"

# common.sh goes under scripts/lib/
scp $SSH_OPTS "$SCRIPT_DIR/lib/common.sh" \
  "${SSH_USER}@${SERVER_IP}:/tmp/mm-setup/scripts/lib/common.sh"

log_ok "Files staged at /tmp/mm-setup/ on server"

# ── Step 3: Run kubeadm setup remotely ───────────────────────────────────────
log_step "Running kubeadm setup remotely (takes ~5 min — streaming output below)"
echo ""

# Run from ROOT_DIR so relative paths in the script resolve correctly
ssh $SSH_OPTS -tt "${SSH_USER}@${SERVER_IP}" \
  "cd /tmp/mm-setup && sudo bash scripts/02b-setup-kubeadm.sh 2>&1 | tee /tmp/mm-setup/setup.log; exit \${PIPESTATUS[0]}" || {
    log_error "Remote kubeadm setup failed. Last 50 lines of log:"
    ssh $SSH_OPTS "${SSH_USER}@${SERVER_IP}" "tail -50 /tmp/mm-setup/setup.log" 2>/dev/null || true
    exit 1
  }

echo ""
log_ok "Remote kubeadm setup complete"

# ── Step 4: Fetch kubeconfig ─────────────────────────────────────────────────
log_step "Fetching kubeconfig from server"
mkdir -p "$HOME/.kube"
REMOTE_KUBECONFIG_FETCHED=false

# Try the non-root user home first (ubuntu, ec2-user etc.)
if [[ "${SSH_USER}" != "root" ]]; then
  if ssh $SSH_OPTS "${SSH_USER}@${SERVER_IP}" "test -f ~/.kube/config" 2>/dev/null; then
    scp $SSH_OPTS "${SSH_USER}@${SERVER_IP}:~/.kube/config" "$HOME/.kube/config"
    REMOTE_KUBECONFIG_FETCHED=true
    log_ok "kubeconfig fetched from ~${SSH_USER}/.kube/config"
  fi
fi

# Fallback: root's kubeconfig via sudo
if [[ "$REMOTE_KUBECONFIG_FETCHED" == "false" ]]; then
  log_info "Falling back to sudo cat /root/.kube/config"
  ssh $SSH_OPTS "${SSH_USER}@${SERVER_IP}" "sudo cat /root/.kube/config" \
    > "$HOME/.kube/config" 2>/dev/null || {
      log_error "Could not fetch kubeconfig. Remote setup may not have completed."
      exit 1
    }
  log_ok "kubeconfig fetched from /root/.kube/config"
fi

# ── Step 5: Sync variables written by remote setup back to local .env ─────────
# 02b-setup-kubeadm.sh writes METALLB_IP_RANGE and SERVER_PRIVATE_IP to .env
log_step "Syncing METALLB_IP_RANGE and SERVER_PRIVATE_IP from server"

sync_env_var() {
  local var_name="$1"
  local fallback="${2:-}"
  local value
  value=$(ssh $SSH_OPTS "${SSH_USER}@${SERVER_IP}" \
    "grep '^${var_name}=' /tmp/mm-setup/.env | cut -d= -f2" 2>/dev/null || true)

  if [[ -z "$value" ]]; then
    log_warn "Could not read ${var_name} from remote .env — using fallback: ${fallback}"
    value="$fallback"
  fi

  if grep -q "^${var_name}=" "$ROOT_DIR/.env"; then
    sed -i.bak "s|^${var_name}=.*|${var_name}=${value}|" "$ROOT_DIR/.env"
    rm -f "$ROOT_DIR/.env.bak"
  else
    echo "${var_name}=${value}" >> "$ROOT_DIR/.env"
  fi
  log_ok "${var_name}=${value} written to local .env"
}

sync_env_var "METALLB_IP_RANGE"     "${SERVER_IP}/32"
sync_env_var "SERVER_PRIVATE_IP"    ""

# ── Step 6: Verify cluster reachable from local machine ──────────────────────
log_step "Verifying cluster reachability (needs port 6443 open in security group)"

if ! kubectl cluster-info &>/dev/null; then
  log_error "kubectl cannot reach the cluster at https://${SERVER_IP}:6443"
  echo ""
  echo "  Most likely cause: port 6443 is blocked in your cloud firewall."
  echo ""
  echo "  AWS fix:"
  echo "    EC2 → Security Groups → Inbound Rules → Add:"
  echo "      Type: Custom TCP | Port: 6443 | Source: My IP  (or 0.0.0.0/0)"
  echo ""
  echo "  After opening the port, re-run: bash bootstrap.sh"
  exit 1
fi

log_ok "Cluster reachable"
kubectl cluster-info 2>&1 | grep -E "running|Kubernetes" | head -2

log_section "Remote Setup Complete"
echo "  Kubeconfig  : $HOME/.kube/config"
echo "  Server      : ${SSH_USER}@${SERVER_IP}"
echo ""
echo "  bootstrap.sh will now continue with Flux setup automatically."
