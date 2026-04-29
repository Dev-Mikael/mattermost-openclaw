#!/usr/bin/env bash
# scripts/01-install-tools.sh
# Installs: kubectl, helm, flux CLI, kubeseal, kind
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

log_section "01 — Installing Required Tools"

OS="$(uname -s)"
ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] && ARCH_ALT="amd64" || ARCH_ALT="arm64"

install_on_linux() {
  # kubectl
  if ! command -v kubectl &>/dev/null; then
    log_step "Installing kubectl"
    KUBE_VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -sLo /tmp/kubectl "https://dl.k8s.io/release/${KUBE_VER}/bin/linux/${ARCH_ALT}/kubectl"
    chmod +x /tmp/kubectl && sudo mv /tmp/kubectl /usr/local/bin/kubectl
    log_ok "kubectl installed"
  else log_ok "kubectl already installed"; fi

  # Helm
  if ! command -v helm &>/dev/null; then
    log_step "Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_ok "Helm installed"
  else log_ok "Helm already installed"; fi

  # Flux CLI
  if ! command -v flux &>/dev/null; then
    log_step "Installing Flux CLI"
    curl -s https://fluxcd.io/install.sh | sudo bash
    log_ok "Flux CLI installed"
  else log_ok "Flux CLI already installed"; fi

  # kubeseal
  if ! command -v kubeseal &>/dev/null; then
    log_step "Installing kubeseal"
    KUBESEAL_VER=$(curl -sL https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \
      | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    curl -sLo /tmp/kubeseal.tar.gz \
      "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VER}/kubeseal-${KUBESEAL_VER}-linux-${ARCH_ALT}.tar.gz"
    tar -xzf /tmp/kubeseal.tar.gz -C /tmp kubeseal
    sudo mv /tmp/kubeseal /usr/local/bin/kubeseal
    log_ok "kubeseal installed"
  else log_ok "kubeseal already installed"; fi

  # kind
  if ! command -v kind &>/dev/null; then
    log_step "Installing kind"
    curl -sLo /tmp/kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH_ALT}"
    chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind
    log_ok "kind installed"
  else log_ok "kind already installed"; fi
}

install_on_mac() {
  if ! command -v brew &>/dev/null; then
    log_error "Homebrew not found. Install from https://brew.sh first."
    exit 1
  fi
  log_step "Installing tools via Homebrew"
  brew install kubectl helm fluxcd/tap/flux kubeseal kind
  log_ok "All tools installed"
}

case "$OS" in
  Linux)  install_on_linux ;;
  Darwin) install_on_mac ;;
  *)      log_error "Unsupported OS: $OS"; exit 1 ;;
esac

log_section "Tool Versions"
echo "  kubectl  : $(kubectl version --client --short 2>/dev/null | head -1 || kubectl version --client | head -1)"
echo "  helm     : $(helm version --short)"
echo "  flux     : $(flux version --client)"
echo "  kubeseal : $(kubeseal --version 2>&1 | head -1)"
echo "  kind     : $(kind version 2>/dev/null || echo 'not installed')"
log_ok "All tools ready"
