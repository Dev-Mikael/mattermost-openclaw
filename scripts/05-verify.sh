#!/usr/bin/env bash
# scripts/05-verify.sh
# Verifies the full stack and diagnoses the three most common failures:
#   1. Ingress LoadBalancer IP not assigned (MetalLB issue)
#   2. Domain not resolving (DNS A record missing)
#   3. Port 80/443 blocked (cloud security group / firewall)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
load_env "$ROOT_DIR/.env"

log_section "05 — Deployment Verification"

log_step "Flux Kustomizations"
flux get kustomizations -A

log_step "Flux HelmReleases"
flux get helmreleases -A

log_step "Pods — mattermost namespace"
kubectl get pods -n mattermost -o wide 2>/dev/null || echo "  (namespace not yet created)"

log_step "Mattermost CR status"
kubectl get mattermost -n mattermost 2>/dev/null || echo "  (Mattermost CR not yet created)"

log_step "Ingress resources"
kubectl get ingress -A 2>/dev/null

log_step "Sealed Secrets"
kubectl get sealedsecrets -n mattermost 2>/dev/null

log_step "TLS Certificates"
kubectl get certificates -A 2>/dev/null || echo "  (no certificates yet)"

# ── Ingress IP check ─────────────────────────────────────────────────────────
# On cloud VMs (AWS/GCP/DO) MetalLB L2 mode cannot claim the public IP because
# it is not on any network interface — it is a cloud NAT. Instead nginx uses
# externalIPs with the PRIVATE IP, which kube-proxy routes via iptables DNAT.
# The LoadBalancer EXTERNAL-IP may show as <pending> or the private IP — both
# are fine as long as nginx responds on the public IP's ports 80/443.
log_step "Checking nginx service assignment"

INGRESS_LB_IP=$(kubectl get svc \
  -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

INGRESS_EXTERNAL_IPS=$(kubectl get svc \
  -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null || true)

SERVER_PRIVATE_IP="${SERVER_PRIVATE_IP:-${SERVER_IP}}"

if [[ -n "$INGRESS_LB_IP" && "$INGRESS_LB_IP" != "null" ]]; then
  log_ok "nginx EXTERNAL-IP (MetalLB): ${INGRESS_LB_IP}"
elif [[ -n "$INGRESS_EXTERNAL_IPS" ]]; then
  log_ok "nginx externalIPs: ${INGRESS_EXTERNAL_IPS} (expected for cloud VMs — MetalLB pending is normal)"
else
  log_warn "nginx has neither LoadBalancer IP nor externalIPs assigned yet"
  echo "  This is usually a timing issue — MetalLB or Flux may still be reconciling."
  echo "  Wait 2 min then re-run: bash scripts/05-verify.sh"
  echo ""
  echo "  To diagnose:"
  echo "    kubectl get svc -n ingress-nginx ingress-nginx-controller"
  echo "    kubectl logs -n metallb-system -l component=controller --tail=30"
fi

# The meaningful connectivity test: can we actually reach nginx on the server?
if [[ "${CLUSTER_TYPE}" != "kind" ]]; then
  log_step "Testing nginx reachability on ${SERVER_IP}:80"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}/" --max-time 8 2>/dev/null || echo "timeout")
  if [[ "$HTTP_CODE" == "timeout" ]]; then
    log_warn "No response from http://${SERVER_IP}/ — nginx may not be reachable yet"
    echo ""
    echo "  Checklist:"
    echo "    [ ] Security group: port 80 open inbound (0.0.0.0/0)"
    echo "    [ ] nginx pod Running: kubectl get pods -n ingress-nginx"
    echo "    [ ] externalIPs set to private IP: ${SERVER_PRIVATE_IP}"
    echo "        kubectl get svc -n ingress-nginx ingress-nginx-controller -o yaml | grep externalIPs"
  elif [[ "$HTTP_CODE" == "404" || "$HTTP_CODE" == "200" || "$HTTP_CODE" == "308" || "$HTTP_CODE" == "301" ]]; then
    log_ok "nginx is reachable — HTTP ${HTTP_CODE} (nginx default backend or redirect)"
  else
    log_info "nginx responded with HTTP ${HTTP_CODE}"
  fi
fi

CERT_STATUS=""

# ── Domain DNS and port checks (kubeadm only) ────────────────────────────────
if [[ "${CLUSTER_TYPE}" != "kind" ]]; then
  log_step "Checking DNS resolution for ${DOMAIN}"
  RESOLVED_IP=$(dig +short "${DOMAIN}" A 2>/dev/null | tail -1 || true)
  if [[ -z "$RESOLVED_IP" ]]; then
    log_warn "DNS: ${DOMAIN} does not resolve to any IP yet."
    echo ""
    echo "  Action required — add a DNS A record at your registrar/DNS provider:"
    echo "    Name  : ${DOMAIN}  (or @ if this is the apex/root domain)"
    echo "    Type  : A"
    echo "    Value : ${SERVER_IP}"
    echo "    TTL   : 300  (5 minutes — use low TTL while testing)"
  elif [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
    log_warn "DNS: ${DOMAIN} resolves to ${RESOLVED_IP} but SERVER_IP is ${SERVER_IP}"
    echo "  Update the A record to point to ${SERVER_IP}"
  else
    log_ok "DNS: ${DOMAIN} -> ${SERVER_IP}"
  fi

  log_step "Checking ports 80 and 443 reachability on ${SERVER_IP}"
  check_port() {
    local port="$1"
    if timeout 5 bash -c ">/dev/tcp/${SERVER_IP}/${port}" 2>/dev/null; then
      log_ok "Port ${port} open"
    else
      log_warn "Port ${port} is NOT reachable from your machine"
      echo ""
      echo "  This is the most common reason the domain does not load on AWS."
      echo "  Fix: EC2 console -> Security Groups -> Inbound Rules -> Add rules:"
      echo "    HTTP   port 80  source 0.0.0.0/0"
      echo "    HTTPS  port 443 source 0.0.0.0/0"
      echo ""
      echo "  Also allow in the OS firewall on the server:"
      echo "    sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw reload"
    fi
  }
  check_port 80
  check_port 443

  log_step "TLS certificate status"
  CERT_STATUS=$(kubectl get certificate mattermost-tls -n mattermost \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$CERT_STATUS" == "True" ]]; then
    log_ok "TLS certificate issued and ready"
  elif [[ -z "$CERT_STATUS" ]]; then
    log_info "TLS certificate not yet created. cert-manager will issue it automatically once:"
    echo "    1. Mattermost Ingress is deployed"
    echo "    2. DNS A record points ${DOMAIN} -> ${SERVER_IP}"
    echo "    3. Ports 80/443 are open (Let's Encrypt HTTP-01 challenge)"
  else
    log_warn "TLS certificate not ready (status: ${CERT_STATUS})"
    echo "  Debug commands:"
    echo "    kubectl describe certificate mattermost-tls -n mattermost"
    echo "    kubectl describe certificaterequest -n mattermost"
    echo "    kubectl describe challenge -n mattermost 2>/dev/null"
  fi
fi

# ── Final summary ─────────────────────────────────────────────────────────────
log_section "Access Summary"
echo ""
if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  echo "  Cluster Type  : kind (local dev)"
  echo "  Ingress IP    : ${INGRESS_IP:-pending}"
  echo ""
  echo "  Add to /etc/hosts:"
  echo "    ${INGRESS_IP:-<pending>}  ${DOMAIN}"
  echo "  Then open: http://${DOMAIN}  (HTTP only on kind — no real TLS)"
else
  echo "  Cluster Type  : kubeadm (on-prem / cloud)"
  echo "  Server IP     : ${SERVER_IP}"
  echo "  Ingress IP    : ${INGRESS_IP:-pending}"
  echo "  URL           : https://${DOMAIN}"
  echo ""
  echo "  Checklist:"
  echo "    [ ] DNS A record  : ${DOMAIN} -> ${SERVER_IP}"
  echo "    [ ] Security group: ports 80, 443, 6443 open inbound"
  echo "    [ ] MetalLB IP    : ${INGRESS_IP:-not yet assigned}"
  echo "    [ ] TLS cert      : ${CERT_STATUS:-pending}"
fi
echo ""
echo "  Live watch commands:"
echo "    kubectl get pods -n mattermost --watch"
echo "    flux get all -A"
echo "    kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller -f"
echo ""
