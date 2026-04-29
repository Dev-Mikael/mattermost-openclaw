#!/usr/bin/env bash
# scripts/lib/common.sh — shared helper functions

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }
log_section() { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}  $*${NC}\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

require_tool() {
  if ! command -v "$1" &>/dev/null; then
    log_error "Required tool '$1' not found. Run scripts/01-install-tools.sh first."
    exit 1
  fi
}

wait_for_pods() {
  local ns="$1" label="$2" timeout="${3:-300}"
  log_info "Waiting for pods (ns=$ns, selector=$label) ..."
  kubectl wait pods \
    --namespace "$ns" \
    --selector "$label" \
    --for condition=Ready \
    --timeout="${timeout}s"
}

load_env() {
  local envfile="${1:-.env}"
  if [[ ! -f "$envfile" ]]; then
    log_error "Missing $envfile — copy .env.example to .env and fill in values."
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$envfile"

  local missing=()
  for var in GITHUB_USER GITHUB_TOKEN GITHUB_REPO GITHUB_BRANCH \
             CLUSTER_NAME CLUSTER_TYPE SERVER_IP DOMAIN \
             LETSENCRYPT_EMAIL DB_PASSWORD MINIO_ACCESS_KEY MINIO_SECRET_KEY; do
    [[ -z "${!var:-}" ]] && missing+=("$var")
  done

  # SSH vars only required for kubeadm deployments
  if [[ "${CLUSTER_TYPE:-}" == "kubeadm" ]]; then
    for var in SSH_KEY_PATH SSH_USER; do
      [[ -z "${!var:-}" ]] && missing+=("$var")
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required variables in $envfile: ${missing[*]}"
    exit 1
  fi
  log_ok ".env loaded (DOMAIN=$DOMAIN, SERVER_IP=$SERVER_IP, CLUSTER_TYPE=$CLUSTER_TYPE)"
}
