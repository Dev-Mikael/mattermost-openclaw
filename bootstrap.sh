#!/usr/bin/env bash
# bootstrap.sh — Master Automation Script
# =========================================
# ONE command to deploy Mattermost + KubeClaw (OpenClaw) end-to-end via GitOps.
#
# Usage:
#   1. cp .env.example .env && nano .env
#   2. (kubeadm) place your .pem key in the repo folder or point SSH_KEY_PATH to it
#   3. bash bootstrap.sh
# =========================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}  $*${NC}\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │       Mattermost + KubeClaw GitOps Bootstrap v3              │"
echo "  │  kubeadm / kind  +  FluxCD  +  Sealed Secrets + OpenClaw    │"
echo "  └──────────────────────────────────────────────────────────────┘"
echo -e "${NC}"

if [[ ! -f ".env" ]]; then
  log_error ".env not found!"
  echo "  1. cp .env.example .env"
  echo "  2. nano .env"
  echo "  3. bash bootstrap.sh"
  exit 1
fi

source ".env"
log_ok ".env loaded (DOMAIN=${DOMAIN}, CLUSTER_TYPE=${CLUSTER_TYPE})"

chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null || true

# ── Step 1: Tools ─────────────────────────────────────────────
log_section "Step 1/6 — Install Required Tools"
bash scripts/01-install-tools.sh

# ── Step 2: Cluster ───────────────────────────────────────────
log_section "Step 2/6 — Kubernetes Cluster"

case "${CLUSTER_TYPE:-kubeadm}" in
  kind)
    log_info "CLUSTER_TYPE=kind → creating local kind cluster"
    if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
      log_error "Docker is not running. Start Docker Desktop first."
      exit 1
    fi
    bash scripts/02a-create-cluster-kind.sh
    source ".env"
    ;;
  kubeadm)
    if kubectl cluster-info > /dev/null 2>&1; then
      log_ok "Existing kubeadm cluster detected — skipping remote provisioning"
      if [[ -z "${METALLB_IP_RANGE:-}" ]]; then
        log_error "METALLB_IP_RANGE is empty. Set it in .env."
        exit 1
      fi
    else
      log_info "Provisioning ${SERVER_IP} via SSH..."
      bash scripts/02b-remote-setup.sh
      source ".env"
    fi
    ;;
  *)
    log_error "Unknown CLUSTER_TYPE='${CLUSTER_TYPE}'. Use 'kind' or 'kubeadm'."
    exit 1
    ;;
esac

# ── Step 3: Bootstrap Flux ────────────────────────────────────
log_section "Step 3/6 — Bootstrap FluxCD"
bash scripts/03-bootstrap-flux.sh

# ── Step 4: Seal Mattermost Secrets ──────────────────────────
log_section "Step 4/6 — Seal Secrets & Deploy Mattermost"
bash scripts/04-wait-and-seal.sh

# ── Step 5: Verify Mattermost ─────────────────────────────────
log_section "Step 5/6 — Verify Mattermost Deployment"
bash scripts/05-verify.sh

# ── Step 6: KubeClaw Bot Integration ─────────────────────────
log_section "Step 6/6 — Deploy KubeClaw + Wire Mattermost Bot"
bash scripts/06-setup-kubeclaw.sh

# ── Done ──────────────────────────────────────────────────────
source ".env"

log_section "Bootstrap Complete!"
echo ""
if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  echo -e "${BOLD}  Local (kind):${NC}"
  echo "    Add to /etc/hosts:  ${INGRESS_IP}  ${DOMAIN}"
  echo "    Add to /etc/hosts:  ${INGRESS_IP}  openclaw.${DOMAIN}"
  echo "    Mattermost : http://${DOMAIN}"
else
  echo -e "${BOLD}  On-Prem (kubeadm):${NC}"
  echo "    DNS A record:  ${DOMAIN}          → ${SERVER_IP}"
  echo "    DNS A record:  openclaw.${DOMAIN} → ${SERVER_IP}"
  echo "    Mattermost:    https://${DOMAIN}"
  echo "    OpenClaw UI:   (URL printed above by Step 6)"
fi
echo ""
echo "  Bot management:  bash scripts/07-manage-bot.sh"
echo ""
echo -e "${GREEN}${BOLD}  Mattermost + OpenClaw bot are live! 🦞${NC}"
echo ""
