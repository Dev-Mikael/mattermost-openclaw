#!/usr/bin/env bash
# scripts/06-setup-kubeclaw.sh
# ─────────────────────────────────────────────────────────────────────────────
# Fully automated KubeClaw + Mattermost bot integration.
# Called by bootstrap.sh as Step 6. Safe to re-run.
#
#   PHASE 1   Validate env vars
#   PHASE 2   Render bot config into helmrelease.yaml (replaces @@PLACEHOLDER@@s)
#   PHASE 3   Commit kubeclaw app structure + push
#   PHASE 4   Wait for Mattermost pod
#   PHASE 5   Create Mattermost system admin user (kubectl exec)
#   PHASE 6   Create openclaw-bot account + access token (REST API)
#   PHASE 7   Add bot to Mattermost channels (REST API)
#   PHASE 8   Seal all secrets + push
#   PHASE 9   Wait for KubeClaw Gateway pod
#   PHASE 10  Install Mattermost plugin + restart Gateway (kubectl exec)
#   PHASE 11  Verify + print access summary
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "06 — KubeClaw + Mattermost Bot Integration"

require_tool kubectl
require_tool kubeseal
require_tool git
require_tool curl
require_tool python3

# Declare PID variables up front so trap references are never unbound,
# even if a phase exits before the corresponding port-forward is started.
MM_PF_PID=""
SS_PF_PID=""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Validate env vars
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 1/11 — Validating configuration"

MISSING=()
for var in \
  MM_ADMIN_USERNAME MM_ADMIN_PASSWORD \
  OPENCLAW_GATEWAY_TOKEN OPENAI_API_KEY GEMINI_API_KEY LITELLM_MASTER_KEY; do
  [[ -z "${!var:-}" ]] && MISSING+=("$var")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  log_error "Missing required variables in .env: ${MISSING[*]}"
  exit 1
fi

if [[ "${LITELLM_MASTER_KEY}" != sk-* ]]; then
  log_error "LITELLM_MASTER_KEY must start with 'sk-'"
  log_error "Generate: openssl rand -hex 24 | sed 's/^/sk-/'"
  exit 1
fi

# Defaults
MM_ADMIN_EMAIL="${MM_ADMIN_EMAIL:-${LETSENCRYPT_EMAIL}}"
MM_BOT_DM_POLICY="${MM_BOT_DM_POLICY:-pairing}"
MM_BOT_CHANNELS="${MM_BOT_CHANNELS:-town-square}"

log_ok "Config valid — DM policy: ${MM_BOT_DM_POLICY}, channels: ${MM_BOT_CHANNELS}"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Render bot config into helmrelease.yaml
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 2/11 — Rendering bot config into openclawinstance.yaml"

# Determine allowFrom value based on DM policy
if [[ "${MM_BOT_DM_POLICY}" == "open" ]]; then
  ALLOW_FROM='["*"]'
else
  # pairing mode — allowFrom is unused but kept as empty for schema compliance
  ALLOW_FROM='[]'
fi

INSTANCE_FILE="$ROOT_DIR/apps/kubeclaw/openclawinstance.yaml"

# Replace @@PLACEHOLDER@@ tokens in openclawinstance.yaml with actual values.
TMP_INST="$(mktemp)"
sed \
  -e "s|@@MM_BOT_DM_POLICY@@|${MM_BOT_DM_POLICY}|g" \
  -e "s|@@MM_BOT_ALLOW_FROM@@|${ALLOW_FROM}|g" \
  "$INSTANCE_FILE" > "$TMP_INST"
mv "$TMP_INST" "$INSTANCE_FILE"

log_ok "openclawinstance.yaml rendered (dmPolicy=${MM_BOT_DM_POLICY}, allowFrom=${ALLOW_FROM})"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Commit kubeclaw structure + push
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 3/11 — Committing kubeclaw structure to git"

cd "$ROOT_DIR"

git config user.email 2>/dev/null || git config user.email "${LETSENCRYPT_EMAIL:-deploy@noreply.local}"
git config user.name  2>/dev/null || git config user.name  "${GITHUB_USER:-flux-bootstrap}"

# Patch apps/kustomization.yaml to add kubeclaw/ if not already there.
# Done at runtime so kubeclaw/ and the kustomization change land in the same
# git commit — Flux never tries to resolve a reference before the dir exists.
APPS_KUST="$ROOT_DIR/apps/kustomization.yaml"
if ! grep -q "kubeclaw" "$APPS_KUST"; then
  echo "  - kubeclaw/" >> "$APPS_KUST"
  log_ok "Added kubeclaw/ to apps/kustomization.yaml"
fi

git add \
  apps/kustomization.yaml \
  apps/kubeclaw/ \
  apps/mattermost/mattermost.yaml

git diff --cached --quiet && {
  log_info "kubeclaw structure already committed — skipping"
} || {
  git commit -m "feat(kubeclaw): add kubeclaw bot layer (secret sealing pending)"
  git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git" 2>/dev/null || true
  git push origin "${GITHUB_BRANCH}"
  git remote set-url origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" 2>/dev/null || true
  log_ok "kubeclaw structure committed and pushed"
}

# Kick off a source-only reconcile so Flux picks up the new app structure.
# The HelmRelease will enter a Pending / waiting-for-secret state — this is
# expected and correct. We do NOT reconcile the `apps` kustomization here
# because the kubeclaw-secret does not exist yet; reconciling apps would cause
# the HelmRelease to fail immediately and start exponential back-off retries,
# which then compete with Phase 8's proper reconcile and can push the
# kustomization past its 15-minute timeout ("context deadline exceeded").
# Phase 8 triggers `flux reconcile kustomization apps` after the secret lands.
flux reconcile source git flux-system --timeout=2m 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — Wait for Mattermost pod
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 4/11 — Waiting for Mattermost pod"

# The mattermost.yaml changes (EnableUserAccessTokens, AllowedUntrustedConnections)
# applied by Flux will cause Mattermost to restart. Wait for it to settle.
for i in $(seq 1 60); do
  READY=$(kubectl get pods -n mattermost -l app=mattermost \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$READY" == "True" ]] && { log_ok "Mattermost pod Ready"; break; }
  log_info "Waiting for Mattermost... attempt $i/60"
  sleep 10
done
[[ "$READY" != "True" ]] && { log_error "Mattermost pod not Ready after 10 min"; exit 1; }
sleep 5  # brief settle time for API to be fully accepting connections

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 — Create Mattermost system admin user
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 5/11 — Creating Mattermost system admin user"

MM_POD=$(kubectl get pod -n mattermost -l app=mattermost \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$MM_POD" ]] && { log_error "Could not find Mattermost pod"; exit 1; }
log_info "Using pod: $MM_POD"

# Mattermost 6+ uses mmctl with --local (talks to server via Unix socket inside pod).
# Mattermost <6 uses the legacy `mattermost user create` CLI.
# We try mmctl first, fall back to the legacy command, then log and continue
# either way — the user may already exist, or Phase 6 will create it via API.

CREATE_OUT=$(kubectl exec -n mattermost "$MM_POD" -- \
  mmctl user create \
    --email      "$MM_ADMIN_EMAIL" \
    --username   "$MM_ADMIN_USERNAME" \
    --password   "$MM_ADMIN_PASSWORD" \
    --system-admin \
    --local 2>&1 || true)

# If mmctl isn't available or returned an unknown-command error, try the legacy CLI
if echo "$CREATE_OUT" | grep -qi "unknown\|not found\|no such\|executable"; then
  log_info "mmctl not available — trying legacy mattermost CLI..."
  CREATE_OUT=$(kubectl exec -n mattermost "$MM_POD" -- \
    mattermost user create \
      --email      "$MM_ADMIN_EMAIL" \
      --username   "$MM_ADMIN_USERNAME" \
      --password   "$MM_ADMIN_PASSWORD" \
      --system_admin 2>&1 || true)
fi

if echo "$CREATE_OUT" | grep -qi "created\|success"; then
  log_ok "Admin user '$MM_ADMIN_USERNAME' created via CLI"
elif echo "$CREATE_OUT" | grep -qi "already\|duplicate\|exists"; then
  log_info "Admin user '$MM_ADMIN_USERNAME' already exists — continuing"
else
  log_info "CLI admin create output: $CREATE_OUT"
  log_info "Will attempt API-based creation in Phase 6 if login fails"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 — Create openclaw-bot account + access token via Mattermost API
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 6/11 — Creating openclaw-bot account and access token"

# Port-forward Mattermost to localhost so we can use the REST API without
# needing DNS propagation or a valid TLS cert (may not be issued yet).
kubectl port-forward -n mattermost svc/mattermost 8065:8065 &
MM_PF_PID=$!
trap 'kill "${MM_PF_PID:-}" 2>/dev/null || true; kill "${SS_PF_PID:-}" 2>/dev/null || true' EXIT
sleep 6

MM_API="http://localhost:8065"

# ── Authenticate ──────────────────────────────────────────────────────────────
log_info "Authenticating with Mattermost API..."
LOGIN_RESP=$(curl -s -i -X POST "$MM_API/api/v4/users/login" \
  -H "Content-Type: application/json" \
  -d "{\"login_id\":\"${MM_ADMIN_USERNAME}\",\"password\":\"${MM_ADMIN_PASSWORD}\"}" 2>/dev/null)

MM_TOKEN=$(echo "$LOGIN_RESP" | grep -i "^token:" | awk '{print $2}' | tr -d '\r\n')

# If login failed, the server may be a fresh install with no users yet.
# In that case, Mattermost allows creating the very first user unauthenticated.
# We create the admin account via API, then login again to get a session token.
if [[ -z "$MM_TOKEN" ]]; then
  log_info "Login failed — trying unauthenticated first-user creation via API..."

  FIRST_USER_RESP=$(curl -s -X POST "$MM_API/api/v4/users" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${MM_ADMIN_EMAIL}\",\"username\":\"${MM_ADMIN_USERNAME}\",\"password\":\"${MM_ADMIN_PASSWORD}\"}" \
    2>/dev/null)

  FIRST_USER_ID=$(echo "$FIRST_USER_RESP" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

  if [[ -n "$FIRST_USER_ID" ]]; then
    log_ok "Initial admin user created via API (id: $FIRST_USER_ID)"
  else
    log_info "First-user API response: $(echo "$FIRST_USER_RESP" | head -c 200)"
  fi

  # Retry login with the newly created account
  LOGIN_RESP=$(curl -s -i -X POST "$MM_API/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"login_id\":\"${MM_ADMIN_USERNAME}\",\"password\":\"${MM_ADMIN_PASSWORD}\"}" 2>/dev/null)

  MM_TOKEN=$(echo "$LOGIN_RESP" | grep -i "^token:" | awk '{print $2}' | tr -d '\r\n')

  # Grant system_admin role if we just created this user
  if [[ -n "$MM_TOKEN" && -n "${FIRST_USER_ID:-}" ]]; then
    curl -s -X PUT "$MM_API/api/v4/users/${FIRST_USER_ID}/roles" \
      -H "Authorization: Bearer $MM_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"roles":"system_user system_admin"}' 2>/dev/null | python3 -c \
      "import sys,json; r=json.load(sys.stdin); print('Admin role granted') if r.get('status')=='OK' else None" 2>/dev/null || true
  fi
fi

[[ -z "$MM_TOKEN" ]] && {
  log_error "Failed to authenticate with Mattermost API."
  log_error "Check MM_ADMIN_USERNAME / MM_ADMIN_PASSWORD in .env."
  log_error "Response tail: $(echo "$LOGIN_RESP" | tail -3)"
  exit 1
}
log_ok "Authenticated with Mattermost API"

# ── Get or create team ────────────────────────────────────────────────────────
log_info "Fetching team list..."
TEAMS_RESP=$(curl -s "$MM_API/api/v4/teams" -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null)
TEAM_ID=$(echo "$TEAMS_RESP" | python3 -c "
import sys, json
try:
    teams = json.load(sys.stdin)
    if teams: print(teams[0]['id'])
except: pass
" 2>/dev/null || true)

if [[ -z "$TEAM_ID" ]]; then
  log_info "No teams found — creating default team via API..."
  CREATE_TEAM_RESP=$(curl -s -X POST "$MM_API/api/v4/teams" \
    -H "Authorization: Bearer $MM_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"main","display_name":"Main","type":"O"}' 2>/dev/null)

  TEAM_ID=$(echo "$CREATE_TEAM_RESP" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

  if [[ -n "$TEAM_ID" ]]; then
    log_ok "Default team 'main' created (id: $TEAM_ID)"

    # Add admin to the new team so subsequent channel lookups succeed
    curl -s -X POST "$MM_API/api/v4/teams/${TEAM_ID}/members" \
      -H "Authorization: Bearer $MM_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"team_id\":\"${TEAM_ID}\",\"user_id\":\"me\"}" 2>/dev/null | python3 -c \
      "import sys,json; r=json.load(sys.stdin); print('Admin joined team') if r.get('team_id') else None" 2>/dev/null || true
  else
    log_warn "Could not create default team — channel join will be skipped"
    log_warn "API response: $(echo "$CREATE_TEAM_RESP" | head -c 200)"
  fi
fi

[[ -z "$TEAM_ID" ]] && log_warn "Team ID still unavailable — channel join will be skipped"
[[ -n "$TEAM_ID" ]] && log_ok "Team ID resolved: $TEAM_ID"

# ── Create bot account ────────────────────────────────────────────────────────
log_info "Creating openclaw-bot account..."
BOT_RESP=$(curl -s -X POST "$MM_API/api/v4/bots" \
  -H "Authorization: Bearer $MM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"openclaw-bot","display_name":"OpenClaw","description":"OpenClaw AI agent — DM me or @mention me in a channel"}' 2>/dev/null)

BOT_USER_ID=$(echo "$BOT_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('user_id',''))" 2>/dev/null || true)

# Fall back to listing existing bots if creation returned a conflict
if [[ -z "$BOT_USER_ID" ]]; then
  log_info "Bot may already exist — looking up..."
  BOTS=$(curl -s "$MM_API/api/v4/bots?include_deleted=false" \
    -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null)
  BOT_USER_ID=$(echo "$BOTS" | python3 -c "
import sys, json
try:
    for b in json.load(sys.stdin):
        if b.get('username') == 'openclaw-bot':
            print(b['user_id']); break
except: pass
" 2>/dev/null || true)
fi

[[ -z "$BOT_USER_ID" ]] && { log_error "Could not create or find openclaw-bot. Response: $BOT_RESP"; exit 1; }
log_ok "openclaw-bot ready (user_id: $BOT_USER_ID)"

# ── Generate access token ─────────────────────────────────────────────────────
log_info "Generating bot access token..."
TOKEN_RESP=$(curl -s -X POST "$MM_API/api/v4/users/${BOT_USER_ID}/tokens" \
  -H "Authorization: Bearer $MM_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"description":"KubeClaw OpenClaw integration token"}' 2>/dev/null)

MATTERMOST_BOT_TOKEN=$(echo "$TOKEN_RESP" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)

[[ -z "$MATTERMOST_BOT_TOKEN" ]] && {
  log_error "Failed to generate bot access token."
  log_error "Response: $TOKEN_RESP"
  log_error "Ensure MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=true in mattermost.yaml."
  exit 1
}
log_ok "Bot access token generated"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — Add bot to Mattermost channels
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 7/11 — Adding bot to channels"

if [[ -n "$TEAM_ID" ]]; then
  # Add bot to team first — channel membership requires team membership
  log_info "Adding bot to team..."
  BOT_TEAM_RESP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$MM_API/api/v4/teams/${TEAM_ID}/members" \
    -H "Authorization: Bearer $MM_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"team_id\":\"${TEAM_ID}\",\"user_id\":\"${BOT_USER_ID}\"}" 2>/dev/null)

  if [[ "$BOT_TEAM_RESP" == "201" || "$BOT_TEAM_RESP" == "200" ]]; then
    log_ok "Bot added to team"
  elif [[ "$BOT_TEAM_RESP" == "400" ]]; then
    log_info "Bot already a team member"
  else
    log_warn "Could not add bot to team (HTTP $BOT_TEAM_RESP) — channel join may fail"
  fi

  # Split MM_BOT_CHANNELS on commas and trim whitespace
  IFS=',' read -ra CHANNEL_NAMES <<< "$MM_BOT_CHANNELS"

  for CHAN_NAME in "${CHANNEL_NAMES[@]}"; do
    CHAN_NAME="$(echo "$CHAN_NAME" | tr -d '[:space:]')"
    [[ -z "$CHAN_NAME" ]] && continue

    # Look up channel by name within the team
    CHAN_RESP=$(curl -s "$MM_API/api/v4/teams/${TEAM_ID}/channels/name/${CHAN_NAME}" \
      -H "Authorization: Bearer $MM_TOKEN" 2>/dev/null)
    CHAN_ID=$(echo "$CHAN_RESP" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

    if [[ -z "$CHAN_ID" ]]; then
      log_warn "Channel '$CHAN_NAME' not found — skipping"
      continue
    fi

    # Add bot as a member of the channel
    JOIN_RESP=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "$MM_API/api/v4/channels/${CHAN_ID}/members" \
      -H "Authorization: Bearer $MM_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"user_id\":\"${BOT_USER_ID}\"}" 2>/dev/null)

    if [[ "$JOIN_RESP" == "201" || "$JOIN_RESP" == "200" ]]; then
      log_ok "Bot added to #${CHAN_NAME}"
    elif [[ "$JOIN_RESP" == "400" ]]; then
      # 400 usually means already a member
      log_info "Bot already in #${CHAN_NAME}"
    else
      log_warn "Could not add bot to #${CHAN_NAME} (HTTP $JOIN_RESP)"
    fi
  done
else
  log_warn "Skipping channel join — team ID not available"
fi

# Stop Mattermost port-forward — no longer needed
kill $MM_PF_PID 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — Seal all secrets + push
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 8/11 — Sealing secrets"

wait_for_pods "flux-system" "app.kubernetes.io/name=sealed-secrets" 180

CERT_FILE="/tmp/sealed-secrets-kubeclaw.pem"
rm -f "$CERT_FILE"

kubectl port-forward -n flux-system svc/sealed-secrets 8080:8080 &
SS_PF_PID=$!
sleep 8

for attempt in 1 2 3 4 5; do
  curl -s --max-time 10 --retry 3 http://localhost:8080/v1/cert.pem > "$CERT_FILE" 2>/dev/null
  grep -q "BEGIN CERTIFICATE" "$CERT_FILE" 2>/dev/null && break
  log_info "Cert fetch attempt $attempt failed, retrying..."
  sleep 5
done

grep -q "BEGIN CERTIFICATE" "$CERT_FILE" 2>/dev/null || {
  log_error "Could not fetch Sealed Secrets certificate."
  exit 1
}
log_ok "Certificate fetched"

SECRETS_DIR="$ROOT_DIR/apps/kubeclaw/secrets"
mkdir -p "$SECRETS_DIR"

kubectl create secret generic kubeclaw-secret \
  --namespace=kubeclaw \
  --from-literal=OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}" \
  --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
  --from-literal=GEMINI_API_KEY="${GEMINI_API_KEY}" \
  --from-literal=LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}" \
  --from-literal=MATTERMOST_BOT_TOKEN="${MATTERMOST_BOT_TOKEN}" \
  --dry-run=client -o yaml | \
kubeseal --format yaml --cert "$CERT_FILE" \
  > "$SECRETS_DIR/sealed-kubeclaw-secret.yaml"
log_ok "sealed-kubeclaw-secret.yaml written"

kill $SS_PF_PID 2>/dev/null || true
trap - EXIT

cd "$ROOT_DIR"
git add apps/kubeclaw/secrets/sealed-kubeclaw-secret.yaml

git diff --cached --quiet && {
  log_info "Sealed secret already committed"
} || {
  git commit -m "feat(kubeclaw): seal kubeclaw-secret with all credentials and bot token"
  git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git" 2>/dev/null || true
  git push origin "${GITHUB_BRANCH}"
  git remote set-url origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" 2>/dev/null || true
  log_ok "Sealed secret committed and pushed"
}

log_info "Triggering Flux reconciliation..."
# Reconcile the source first so Flux pulls the commit with the sealed secret.
flux reconcile source git flux-system --timeout=2m 2>/dev/null || true
# Give the source controller a moment to update the artifact before kustomize runs.
sleep 5
# Now reconcile apps — the sealed secret is present so the HelmRelease can proceed.
# --with-source ensures the kustomize controller re-reads the latest git artifact.
flux reconcile kustomization apps --with-source --timeout=2m 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 9 — Wait for KubeClaw Gateway pod
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 9/11 — Waiting for KubeClaw Gateway pod"

log_info "Waiting for kubeclaw-secret to be decrypted by Sealed Secrets..."
for i in $(seq 1 30); do
  kubectl get secret kubeclaw-secret -n kubeclaw &>/dev/null && { log_ok "kubeclaw-secret exists"; break; }
  log_info "Waiting for decryption... attempt $i/30"
  sleep 10
done

log_info "Waiting for OpenClawInstance to become Ready..."
for i in $(seq 1 60); do
  OCI_STATUS=$(kubectl get openclawinstance kubeclaw -n kubeclaw \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$OCI_STATUS" == "Running" ]] && { log_ok "OpenClawInstance kubeclaw Running"; break; }
  # At the 30-attempt midpoint, nudge Flux in case it is stuck in back-off
  if [[ "$i" -eq 30 ]]; then
    log_info "Midpoint nudge — forcing apps kustomization reconcile..."
    flux reconcile kustomization apps --with-source --timeout=2m 2>/dev/null || true
  fi
  log_info "OpenClawInstance not ready... attempt $i/60 (status: ${OCI_STATUS:-pending})"
  sleep 10
done

log_info "Waiting for KubeClaw Gateway pod to be Ready..."
for i in $(seq 1 60); do
  GW_READY=$(kubectl get pods -n kubeclaw -l app.kubernetes.io/name=kubeclaw \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$GW_READY" == "True" ]] && { log_ok "KubeClaw Gateway pod Ready"; break; }
  log_info "Waiting for Gateway pod... attempt $i/60"
  sleep 10
done

[[ "$GW_READY" != "True" ]] && {
  log_error "KubeClaw Gateway pod not Ready after 10 min."
  log_error "Debug: kubectl describe pod -n kubeclaw -l app.kubernetes.io/name=kubeclaw"
  exit 1
}

sleep 8  # let Gateway process fully initialise before exec

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 10 — Install Mattermost plugin + restart Gateway
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 10/11 — Installing Mattermost plugin and restarting Gateway"

# The @openclaw/mattermost npm package is broken (E404). KubeClaw ships the
# extension at ./extensions/mattermost inside the image — install from there.
log_info "Installing plugin from bundled extensions..."
PLUGIN_OUT=$(kubectl exec -n kubeclaw statefulset/kubeclaw -- \
  openclaw plugins install ./extensions/mattermost 2>&1 || true)

if echo "$PLUGIN_OUT" | grep -qi "installed\|success\|enabled"; then
  log_ok "Mattermost plugin installed"
elif echo "$PLUGIN_OUT" | grep -qi "already"; then
  log_info "Plugin already installed"
else
  log_info "Plugin install output: $PLUGIN_OUT"
fi

log_info "Restarting Gateway to load plugin and connect to Mattermost..."
kubectl exec -n kubeclaw statefulset/kubeclaw -- \
  openclaw gateway restart 2>/dev/null || true

# Wait for Gateway to reconnect (WebSocket to Mattermost takes a few seconds)
sleep 15

PLUGIN_LIST=$(kubectl exec -n kubeclaw statefulset/kubeclaw -- \
  openclaw plugins list 2>/dev/null || true)
if echo "$PLUGIN_LIST" | grep -qi "mattermost"; then
  log_ok "Mattermost plugin confirmed active"
else
  log_warn "Could not confirm plugin in list: $PLUGIN_LIST"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 11 — Verify + summary
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 11/11 — Verifying integration"

log_info "Running openclaw doctor..."
kubectl exec -n kubeclaw statefulset/kubeclaw -- openclaw doctor --yes 2>/dev/null || true

log_info "Checking channel status..."
kubectl exec -n kubeclaw statefulset/kubeclaw -- openclaw status --all 2>/dev/null || true

# TLS cert check
CERT_READY=""
for i in $(seq 1 12); do
  CERT_READY=$(kubectl get certificate kubeclaw-tls -n kubeclaw \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$CERT_READY" == "True" ]] && { log_ok "TLS cert for openclaw.${DOMAIN} ready"; break; }
  log_info "Waiting for TLS cert... attempt $i/12"
  sleep 10
done
[[ "$CERT_READY" != "True" ]] && {
  log_warn "TLS cert not yet issued. Ensure DNS A record 'openclaw.${DOMAIN} → ${SERVER_IP}' exists."
}

# Print gateway token for access summary
GATEWAY_TOKEN=$(kubectl -n kubeclaw get secret kubeclaw-secret \
  -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || echo "<see .env>")

log_section "KubeClaw Bot Integration Complete!"
echo ""
echo "  ── Bot in Mattermost ──────────────────────────────────────"
echo ""
echo "  Bot username    : openclaw-bot"
echo "  Channels joined : ${MM_BOT_CHANNELS}"
echo "  DM policy       : ${MM_BOT_DM_POLICY}"
echo "  Channel mode    : oncall (@mention to trigger)"
echo ""

if [[ "${MM_BOT_DM_POLICY}" == "pairing" ]]; then
  echo "  DM flow:"
  echo "    1. User DMs openclaw-bot → receives pairing code"
  echo "    2. Admin runs: bash scripts/07-manage-bot.sh"
  echo "       Select 'Approve pending pairings' to approve"
  echo ""
else
  echo "  DM flow:"
  echo "    Any Mattermost user can DM openclaw-bot directly (open policy)"
  echo ""
fi

echo "  Channel flow:"
echo "    @openclaw-bot <your message> in any joined channel"
echo ""
echo "  Slash commands:"
echo "    /oc_agent, /oc_sessions, /oc_memory (type /oc_ to see all)"
echo ""
echo "  ── OpenClaw Web UI ────────────────────────────────────────"
echo ""
echo "  URL   : https://openclaw.${DOMAIN}/#token=${GATEWAY_TOKEN}"
echo ""
echo "  ── DNS reminder ───────────────────────────────────────────"
echo ""
echo "  If not already done, add:"
echo "    Host: openclaw   Type: A   Value: ${SERVER_IP}"
echo ""
echo "  ── Bot management ─────────────────────────────────────────"
echo ""
echo "  bash scripts/07-manage-bot.sh"
echo ""