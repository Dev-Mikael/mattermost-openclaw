#!/usr/bin/env bash
# scripts/07-manage-bot.sh
# ─────────────────────────────────────────────────────────────────────────────
# Runtime management for the openclaw-bot inside Mattermost.
# Run at any time after bootstrap — does not modify git or sealed secrets.
#
# Actions:
#   1  List pending pairings (users waiting for DM approval)
#   2  Approve a specific pairing code
#   3  Approve ALL pending pairings at once
#   4  Add bot to an additional Mattermost channel
#   5  Show full bot status
#   6  Show Gateway logs (tail -50)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

require_tool kubectl
require_tool curl
require_tool python3

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; NC='\033[0m'

# ── Check Gateway pod is running ──────────────────────────────────────────────
GW_POD=$(kubectl get pod -n kubeclaw -l app.kubernetes.io/name=kubeclaw \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$GW_POD" ]]; then
  log_error "KubeClaw Gateway pod not found. Is KubeClaw deployed?"
  log_error "Check: kubectl get pods -n kubeclaw"
  exit 1
fi

GW_READY=$(kubectl get pod -n kubeclaw "$GW_POD" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

if [[ "$GW_READY" != "True" ]]; then
  log_error "Gateway pod '$GW_POD' is not Ready."
  log_error "Check: kubectl describe pod -n kubeclaw $GW_POD"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Mattermost API helpers
# ─────────────────────────────────────────────────────────────────────────────
MM_TOKEN=""
MM_PF_PID=""
TEAM_ID=""

start_mm_api() {
  if [[ -n "$MM_PF_PID" ]]; then return; fi
  log_info "Opening Mattermost API port-forward..."
  kubectl port-forward -n mattermost svc/mattermost 8065:8065 &
  MM_PF_PID=$!
  trap 'stop_mm_api' EXIT
  sleep 5

  MM_ADMIN_EMAIL="${MM_ADMIN_EMAIL:-${LETSENCRYPT_EMAIL}}"
  LOGIN=$(curl -s -i -X POST "http://localhost:8065/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"${MM_ADMIN_USERNAME}\",\"password\":\"${MM_ADMIN_PASSWORD}\"}" 2>/dev/null)
  MM_TOKEN=$(echo "$LOGIN" | grep -i "^token:" | awk '{print $2}' | tr -d '\r\n')
  [[ -z "$MM_TOKEN" ]] && { log_error "Mattermost API auth failed. Check MM_ADMIN_USERNAME/PASSWORD in .env."; exit 1; }

  TEAMS=$(curl -s "http://localhost:8065/api/v4/teams" -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null)
  TEAM_ID=$(echo "$TEAMS" | python3 -c "
import sys, json
try:
    t = json.load(sys.stdin)
    if t: print(t[0]['id'])
except: pass
" 2>/dev/null || true)
  log_ok "Mattermost API connected"
}

stop_mm_api() {
  [[ -n "$MM_PF_PID" ]] && kill "$MM_PF_PID" 2>/dev/null || true
  MM_PF_PID=""
}

# ─────────────────────────────────────────────────────────────────────────────
# Menu
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  OpenClaw Bot Manager${NC}"
echo "  ─────────────────────────────────────────"
echo "  Gateway pod : $GW_POD"
echo ""
echo "  1)  List pending pairings"
echo "  2)  Approve a pairing code"
echo "  3)  Approve ALL pending pairings"
echo "  4)  Add bot to a Mattermost channel"
echo "  5)  Show bot status"
echo "  6)  Tail Gateway logs"
echo "  q)  Quit"
echo ""
read -rp "  Choice: " CHOICE

case "$CHOICE" in

  # ── 1: List pending pairings ───────────────────────────────────────────────
  1)
    log_step "Pending pairings"
    kubectl exec -n kubeclaw statefulset/kubeclaw -- \
      openclaw pairing list mattermost 2>/dev/null || echo "  (none pending or pairing disabled)"
    ;;

  # ── 2: Approve a specific pairing code ────────────────────────────────────
  2)
    log_step "Approve pairing code"
    echo ""
    # Show current list first so user knows which codes are available
    kubectl exec -n kubeclaw statefulset/kubeclaw -- \
      openclaw pairing list mattermost 2>/dev/null || echo "  (none pending)"
    echo ""
    read -rp "  Enter pairing code to approve: " PAIR_CODE
    if [[ -z "$PAIR_CODE" ]]; then
      log_warn "No code entered"
    else
      kubectl exec -n kubeclaw statefulset/kubeclaw -- \
        openclaw pairing approve mattermost "$PAIR_CODE" 2>/dev/null && \
        log_ok "Pairing code '$PAIR_CODE' approved" || \
        log_warn "Could not approve code '$PAIR_CODE' — check the code is correct"
    fi
    ;;

  # ── 3: Approve ALL pending pairings ───────────────────────────────────────
  3)
    log_step "Approving all pending pairings"

    # Retrieve list, extract codes, approve each one
    PAIR_LIST=$(kubectl exec -n kubeclaw statefulset/kubeclaw -- \
      openclaw pairing list mattermost 2>/dev/null || true)

    if [[ -z "$PAIR_LIST" ]] || echo "$PAIR_LIST" | grep -qi "none\|empty\|no pending"; then
      log_info "No pending pairings"
    else
      echo "$PAIR_LIST"
      echo ""
      # Codes appear as uppercase alphanumeric tokens — extract them
      CODES=$(echo "$PAIR_LIST" | grep -oE '\b[A-Z0-9]{6,10}\b' || true)
      if [[ -z "$CODES" ]]; then
        log_warn "Could not parse pairing codes from output. Approve manually with option 2."
      else
        while IFS= read -r CODE; do
          [[ -z "$CODE" ]] && continue
          kubectl exec -n kubeclaw statefulset/kubeclaw -- \
            openclaw pairing approve mattermost "$CODE" 2>/dev/null && \
            log_ok "Approved: $CODE" || \
            log_warn "Failed to approve: $CODE"
        done <<< "$CODES"
      fi
    fi
    ;;

  # ── 4: Add bot to a channel ───────────────────────────────────────────────
  4)
    log_step "Add bot to Mattermost channel"
    read -rp "  Channel name (e.g. town-square): " CHAN_NAME
    [[ -z "$CHAN_NAME" ]] && { log_warn "No channel name entered"; exit 0; }

    start_mm_api

    # Look up bot user_id
    BOTS=$(curl -s "http://localhost:8065/api/v4/bots?include_deleted=false" \
      -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null)
    BOT_USER_ID=$(echo "$BOTS" | python3 -c "
import sys, json
try:
    for b in json.load(sys.stdin):
        if b.get('username') == 'openclaw-bot':
            print(b['user_id']); break
except: pass
" 2>/dev/null || true)

    if [[ -z "$BOT_USER_ID" ]]; then
      log_error "openclaw-bot not found in Mattermost. Run bootstrap.sh first."
      stop_mm_api; exit 1
    fi

    if [[ -z "$TEAM_ID" ]]; then
      log_error "Could not determine team ID."
      stop_mm_api; exit 1
    fi

    # Look up channel
    CHAN_RESP=$(curl -s "http://localhost:8065/api/v4/teams/${TEAM_ID}/channels/name/${CHAN_NAME}" \
      -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null)
    CHAN_ID=$(echo "$CHAN_RESP" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

    if [[ -z "$CHAN_ID" ]]; then
      log_error "Channel '#${CHAN_NAME}' not found."
      stop_mm_api; exit 1
    fi

    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "http://localhost:8065/api/v4/channels/${CHAN_ID}/members" \
      -H "Authorization: Bearer $MM_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"${BOT_USER_ID}\"}" 2>/dev/null)

    if [[ "$HTTP" == "201" || "$HTTP" == "200" ]]; then
      log_ok "Bot added to #${CHAN_NAME}"
    elif [[ "$HTTP" == "400" ]]; then
      log_info "Bot is already in #${CHAN_NAME}"
    else
      log_warn "Unexpected response HTTP $HTTP adding bot to #${CHAN_NAME}"
    fi

    stop_mm_api
    ;;

  # ── 5: Show bot status ────────────────────────────────────────────────────
  5)
    log_step "Bot status"
    echo ""
    kubectl exec -n kubeclaw statefulset/kubeclaw -- openclaw status --all 2>/dev/null || true
    echo ""
    log_step "Plugin list"
    kubectl exec -n kubeclaw statefulset/kubeclaw -- openclaw plugins list 2>/dev/null || true
    echo ""
    log_step "Flux resources"
    kubectl get helmrelease kubeclaw -n kubeclaw 2>/dev/null || true
    kubectl get pods -n kubeclaw 2>/dev/null || true
    ;;

  # ── 6: Tail Gateway logs ─────────────────────────────────────────────────
  6)
    log_step "Gateway logs (Ctrl+C to stop)"
    kubectl logs -n kubeclaw statefulset/kubeclaw -f --tail=50
    ;;

  q|Q)
    echo "  Bye."
    ;;

  *)
    log_warn "Unknown choice: $CHOICE"
    ;;
esac
