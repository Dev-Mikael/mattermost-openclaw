#!/usr/bin/env bash
# scripts/04-wait-and-seal.sh
# Waits for infrastructure, seals secrets, pushes apps layer
# FIX: Uses curl via port-forward to fetch cert (avoids kubeseal --controller-url
#      which is not supported in older kubeseal versions)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "04 — Seal Secrets"
require_tool kubectl
require_tool kubeseal
require_tool git

# 1. Wait for infrastructure Kustomization
log_step "Waiting for 'infrastructure' Kustomization to be Ready (up to 15 min)"
flux reconcile kustomization infrastructure --with-source --timeout=5m 2>/dev/null || true

for i in $(seq 1 45); do
  STATUS=$(kubectl get kustomization infrastructure \
    -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$STATUS" == "True" ]]; then
    log_ok "Infrastructure Kustomization is Ready"
    break
  fi
  log_info "Waiting... attempt $i/45 (status: ${STATUS:-Pending})"
  sleep 20
done

[[ "$STATUS" != "True" ]] && {
  log_error "Infrastructure did not become Ready. Check: flux get kustomizations"
  exit 1
}

# 2. Wait for Sealed Secrets controller
log_step "Waiting for Sealed Secrets controller pod"
wait_for_pods "flux-system" "app.kubernetes.io/name=sealed-secrets" 180

# 3. Fetch Sealed Secrets cert via port-forward + curl
# FIX: Older kubeseal versions don't support --controller-url flag.
#      We use a background port-forward and curl instead.
log_step "Fetching Sealed Secrets certificate via port-forward"
CERT_FILE="/tmp/sealed-secrets.pem"
rm -f "$CERT_FILE"

# Start port-forward in background
kubectl port-forward -n flux-system svc/sealed-secrets 8080:8080 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT

# Wait for port-forward to be ready
# Wait for port-forward to be ready — longer wait for real servers
sleep 8

# Fetch cert with timeout — retries up to 5 times
for attempt in 1 2 3 4 5; do
  curl -s --max-time 10 --retry 3 http://localhost:8080/v1/cert.pem > "$CERT_FILE" 2>/dev/null
  if grep -q "BEGIN CERTIFICATE" "$CERT_FILE" 2>/dev/null; then
    break
  fi
  log_info "Cert fetch attempt $attempt failed, retrying in 5s..."
  sleep 5
done

# Verify cert is valid
if ! grep -q "BEGIN CERTIFICATE" "$CERT_FILE" 2>/dev/null; then
  log_error "Failed to fetch valid certificate. Is the sealed-secrets pod running?"
  log_error "Run: kubectl get pods -n flux-system | grep sealed"
  exit 1
fi
log_ok "Certificate fetched ($(wc -c < "$CERT_FILE") bytes)"

# 4. Create and seal all secrets
TMPDIR=$(mktemp -d)
trap 'kill $PF_PID 2>/dev/null || true; rm -rf "$TMPDIR"' EXIT

log_step "Sealing secrets"
SECRETS_DIR="$ROOT_DIR/apps/mattermost/secrets"
mkdir -p "$SECRETS_DIR"

# Secret 1: DB connection string for Mattermost pod
kubectl create secret generic mattermost-db-credentials \
  --namespace=mattermost \
  --from-literal=DB_CONNECTION_STRING="postgres://mmuser:${DB_PASSWORD}@mattermost-db-postgresql.mattermost.svc.cluster.local:5432/mattermost?sslmode=disable" \
  --dry-run=client -o yaml | \
kubeseal --format yaml --cert "$CERT_FILE" \
  > "$SECRETS_DIR/sealed-db-credentials.yaml"
log_ok "sealed-db-credentials.yaml created"

# Secret 2: PostgreSQL admin password (for StatefulSet)
kubectl create secret generic mattermost-db-postgresql \
  --namespace=mattermost \
  --from-literal=postgres-password="${DB_PASSWORD}" \
  --from-literal=password="${DB_PASSWORD}" \
  --dry-run=client -o yaml | \
kubeseal --format yaml --cert "$CERT_FILE" \
  > "$SECRETS_DIR/sealed-postgres-auth.yaml"
log_ok "sealed-postgres-auth.yaml created"

# Secret 3: MinIO credentials
kubectl create secret generic mattermost-minio-credentials \
  --namespace=mattermost \
  --from-literal=accesskey="${MINIO_ACCESS_KEY}" \
  --from-literal=secretkey="${MINIO_SECRET_KEY}" \
  --dry-run=client -o yaml | \
kubeseal --format yaml --cert "$CERT_FILE" \
  > "$SECRETS_DIR/sealed-minio-credentials.yaml"
log_ok "sealed-minio-credentials.yaml created"

# Stop port-forward
kill $PF_PID 2>/dev/null || true

# 5. Commit apps layer
log_step "Committing apps layer and sealed secrets"
cd "$ROOT_DIR"

git add \
  apps/mattermost/postgresql.yaml \
  apps/mattermost/minio.yaml \
  apps/mattermost/mattermost.yaml \
  apps/mattermost/kustomization.yaml \
  apps/mattermost/secrets/ \
  clusters/production/apps.yaml \
  clusters/production/cert-manager-config.yaml \
  clusters/production/metallb-config.yaml

# Set git identity if not already configured
git config user.email 2>/dev/null || git config user.email "${LETSENCRYPT_EMAIL:-deploy@noreply.local}"
git config user.name  2>/dev/null || git config user.name  "${GITHUB_USER:-flux-bootstrap}"

git diff --cached --quiet && {
  log_info "Nothing new to commit"
} || {
  git commit -m "feat: add apps layer with PostgreSQL, MinIO, Mattermost + sealed secrets"
  # Use authenticated URL for push only — reset immediately after
  git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git" 2>/dev/null || true
  git push origin "${GITHUB_BRANCH}"
  git remote set-url origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" 2>/dev/null || true
  log_ok "Apps layer committed and pushed"
}

# 6. Reconcile
log_step "Triggering Flux reconciliation"
flux reconcile source git flux-system 2>/dev/null || true
flux reconcile kustomization apps --with-source 2>/dev/null || true

log_section "04 Complete"
echo "  Next: bash scripts/05-verify.sh"
echo "  Or watch live: kubectl get pods -n mattermost --watch"
