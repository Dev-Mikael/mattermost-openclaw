# Deployment Fix Guide
## Mattermost + OpenClaw on AWS EC2 — All Issues Resolved

---

## What Changed and Why

> **OpenAI API Key Change:** `ANTHROPIC_API_KEY` has been renamed to `OPENAI_API_KEY`
> throughout the codebase. Before running anything, update your `.env`:
> ```bash
> # Remove this line:
> ANTHROPIC_API_KEY=sk-ant-...
>
> # Add this line (get your key from platform.openai.com/api-keys):
> OPENAI_API_KEY=sk-proj-...
> ```
> Then re-run `scripts/06-setup-kubeclaw.sh` so Phase 8 re-seals the secret
> with your actual OpenAI key. Do not push `sealed-kubeclaw-secret.yaml` until
> you have done this — the existing blob still encrypts the old Anthropic value.

| File | Action | Reason |
|------|--------|--------|
| `apps/kubeclaw/envoy-proxy-config.yaml` | **DELETED** | Required `gateway.envoyproxy.io/v1alpha1` CRD which is not installed. Every Flux reconcile threw "no matches for kind EnvoyProxy" → HelmRelease rollback → crash loop |
| `apps/kubeclaw/hpa-chromium.yaml` | **DELETED** | Chromium is disabled (resource risk on t3.medium). HPA targeting a non-existent Deployment causes noisy warnings |
| `apps/kubeclaw/helmrelease.yaml` | **DELETED** | Replaced by `openclawinstance.yaml`. The direct Helm chart tried to create Kubernetes Gateway API resources that conflict with the /32 MetalLB pool |
| `apps/kubeclaw/openclawinstance.yaml` | **NEW** | Declarative OpenClaw instance managed by the openclaw-operator. No Gateway API involvement — uses nginx Ingress only |
| `apps/kubeclaw/litellm.yaml` | **NEW** | Standalone LiteLLM proxy. Gets OPENAI_API_KEY and GEMINI_API_KEY from kubeclaw-secret via envFrom |
| `apps/kubeclaw/kustomization.yaml` | **UPDATED** | Removed old files, added new files |
| `apps/kubeclaw/ingress.yaml` | **UPDATED** | Expanded comments; backend service name matches operator-created Service |
| `apps/kubeclaw/secrets/kustomization.yaml` | **UPDATED** | Removed empty `sealed-kubeclaw-litellm-env.yaml` reference |
| `infrastructure/openclaw-operator/` | **NEW DIRECTORY** | Installs the openclaw-operator (HelmRelease + namespace) |
| `infrastructure/kustomization.yaml` | **UPDATED** | Added `openclaw-operator/` |
| `clusters/production/infrastructure.yaml` | **UPDATED** | Added openclaw-operator-controller-manager health check |

---

## Root Cause Summary

### 1. The /32 Subnet + Crash Loop (Primary Issue)

Your AWS EC2 has two IPs:
- **Public IP** `52.202.179.6` — this is a cloud NAT address, NOT on any network interface
- **Private IP** `172.31.19.108` — this is on `eth0`

MetalLB's pool was set to `172.31.19.108/32` — exactly **one** IP. nginx-ingress grabbed it.
When the kubeclaw Helm chart also created a `LoadBalancer` Service for its Gateway API, MetalLB had nothing left to assign → stayed `<pending>`.

Your NodePort fix was a security risk: it punched holes directly through the node firewall,
bypassing nginx and your NetworkPolicies.

**Real fix**: The kubeclaw chart's Gateway API path was completely unnecessary because nginx
Ingress already handles external access. Removing the Gateway API resources and switching to
the openclaw-operator (which never creates Gateway API resources) eliminates the conflict entirely.

### 2. Why Pods Were Crashing

Two causes working together:
1. `envoy-proxy-config.yaml` tried to create an `EnvoyProxy` CRD resource (requires Envoy Gateway to be installed — it's not). Flux applied it, got "no matches for kind", triggered HelmRelease remediation/rollback, tore down and re-created the kubeclaw deployment every ~10 minutes.
2. The old HelmRelease had `postRenderers` patching a `Gateway` resource that didn't exist when Gateway API was disabled — another reconcile error.

### 3. LiteLLM Secret Wiring

LiteLLM gets its secrets via `envFrom: secretRef: kubeclaw-secret` in the Deployment.
The Sealed Secrets controller decrypts `sealed-kubeclaw-secret.yaml` → real `kubeclaw-secret`.
LiteLLM reads `OPENAI_API_KEY` and `GEMINI_API_KEY` from the environment using
its `os.environ/KEY_NAME` syntax in the proxy config. No secrets are stored in ConfigMaps.

### 4. ACME Cert Challenge Pod

cert-manager creates a temporary pod to solve the Let's Encrypt HTTP-01 challenge.
It stays until the challenge succeeds OR times out. It never succeeds if:
- DNS A record for `openclaw.modumichael.me` doesn't point to `52.202.179.6`
- Port 80 is blocked in your AWS Security Group

### 5. openclaw-operator

The `openclaw-operator` manages `OpenClawInstance` custom resources. Instead of manually
managing a Helm release with 200+ lines of values and fragile postRenderers, you declare
what you want via the CRD and the operator reconciles it. Your boss's direction to "leverage
the configuration" means encoding your kubeclaw config in the `OpenClawInstance` spec.

---

## Step-by-Step Deployment

### Prerequisites

- Cluster is running (`kubectl cluster-info` works)
- Flux is bootstrapped (`flux get all -A` shows resources)
- Your `.env` has all required variables

### Step 1 — Commit and Push

```bash
cd your-repo

# Stage all changes
git add \
  infrastructure/openclaw-operator/ \
  infrastructure/kustomization.yaml \
  clusters/production/infrastructure.yaml \
  apps/kubeclaw/kustomization.yaml \
  apps/kubeclaw/openclawinstance.yaml \
  apps/kubeclaw/litellm.yaml \
  apps/kubeclaw/ingress.yaml \
  apps/kubeclaw/secrets/kustomization.yaml

# Remove deleted files from git
git rm apps/kubeclaw/helmrelease.yaml
git rm apps/kubeclaw/envoy-proxy-config.yaml
git rm apps/kubeclaw/hpa-chromium.yaml

git commit -m "fix: replace kubeclaw HelmRelease with openclaw-operator + OpenClawInstance; remove Gateway API conflict"
git push origin main
```

### Step 2 — Force Flux to Reconcile

```bash
# Pull the new commit
flux reconcile source git flux-system

# Reconcile infrastructure first (installs openclaw-operator + CRD)
flux reconcile kustomization infrastructure --with-source --timeout=15m

# Watch the operator come up
kubectl get pods -n openclaw-operator-system -w
# Expected: openclaw-operator-controller-manager-xxxxx   1/1   Running

# Once infrastructure is Ready, reconcile apps
flux reconcile kustomization apps --with-source --timeout=15m
```

### Step 3 — Watch the kubeclaw namespace

```bash
kubectl get pods -n kubeclaw -w
```

Expected sequence:
```
NAME                    READY   STATUS              RESTARTS
litellm-xxxx            0/1     ContainerCreating   0
litellm-xxxx            1/1     Running             0
kubeclaw-0              0/1     ContainerCreating   0
kubeclaw-0              1/1     Running             0
```

If you see `kubeclaw-0` cycling through `Running → CrashLoopBackOff`, see Troubleshooting below.

---

## Validation Checklist

Run through this in order. Each section builds on the previous one.

### ✅ 1. Sealed Secret Decrypted

```bash
kubectl get secret kubeclaw-secret -n kubeclaw
```
Expected output shows the secret exists (AGE will be a few seconds old):
```
NAME              TYPE     DATA   AGE
kubeclaw-secret   Opaque   5      10s
```

Verify all 5 keys are present:
```bash
kubectl get secret kubeclaw-secret -n kubeclaw -o json | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(list(d['data'].keys()))"
```
Expected:
```
['OPENAI_API_KEY', 'GEMINI_API_KEY', 'LITELLM_MASTER_KEY', 'MATTERMOST_BOT_TOKEN', 'OPENCLAW_GATEWAY_TOKEN']
```

If the secret doesn't exist, Sealed Secrets hasn't decrypted it yet:
```bash
kubectl get sealedsecret kubeclaw-secret -n kubeclaw
kubectl describe sealedsecret kubeclaw-secret -n kubeclaw
# Look for "Sealed" in events — if it says "ErrUnsealFailed" the cert is wrong
# Re-run scripts/06-setup-kubeclaw.sh to re-seal with the current cert
```

### ✅ 2. LiteLLM Running and Has Secrets

```bash
# Check pod is Running
kubectl get pods -n kubeclaw -l app.kubernetes.io/name=litellm

# Check it picked up API keys (should NOT log "missing key" or "invalid key")
kubectl logs -n kubeclaw deploy/litellm | grep -i "model\|key\|error\|warn" | head -20

# Test the health endpoint
kubectl exec -n kubeclaw deploy/litellm -- \
  curl -s -o /dev/null -w "%{http_code}" http://localhost:4000/health/readiness
```
Expected: `200`

Test that LiteLLM can actually route to Anthropic (replace TOKEN with your LITELLM_MASTER_KEY):
```bash
LITELLM_KEY=$(kubectl get secret kubeclaw-secret -n kubeclaw \
  -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)

kubectl exec -n kubeclaw deploy/litellm -- \
  curl -s -X POST http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"say hi"}],"max_tokens":10}'
```
Expected: JSON response with `choices[0].message.content` containing a greeting.

### ✅ 3. OpenClawInstance Created and OpenClaw Pod Running

```bash
# Check operator reconciled the instance
kubectl get openclawinstances -n kubeclaw
# Expected: kubeclaw   Running   3m

# Check pod
kubectl get pods -n kubeclaw -l app.kubernetes.io/name=kubeclaw

# Check operator created the Service
kubectl get svc -n kubeclaw
# Must include a Service named "kubeclaw" on port 18789
```

If OpenClawInstance shows `Pending` or `Failed`:
```bash
kubectl describe openclawinstance kubeclaw -n kubeclaw
# Look at Events section for detailed error from the operator
```

### ✅ 4. OpenClaw Pod Environment Variables

Verify the pod received its secrets:
```bash
kubectl exec -n kubeclaw kubeclaw-0 -- env | grep -E "OPENAI|GEMINI|LITELLM|MATTERMOST|OPENCLAW"
```
Expected: 5 lines, one per key. Values will be the actual secrets.

If any are missing, the envFrom isn't working — check that `kubeclaw-secret` exists (step 1).

### ✅ 5. nginx Ingress Routing

```bash
kubectl get ingress -n kubeclaw
# Must show ADDRESS = your server's private IP (172.31.19.108)

# From your local machine, test that nginx routes the hostname
curl -v -H "Host: openclaw.modumichael.me" http://52.202.179.6/ 2>&1 | grep "< HTTP"
```
Expected: `< HTTP/1.1 200 OK` or `< HTTP/1.1 302 Found` (OpenClaw login redirect)

### ✅ 6. TLS Certificate

```bash
kubectl get certificate kubeclaw-tls -n kubeclaw
```
Expected:
```
NAME           READY   SECRET         AGE
kubeclaw-tls   True    kubeclaw-tls   5m
```

If READY is `False`:
```bash
kubectl describe certificate kubeclaw-tls -n kubeclaw
kubectl describe certificaterequest -n kubeclaw
kubectl describe challenge -n kubeclaw
```

**If the challenge pod is stuck:**
1. Verify DNS resolves: `dig openclaw.modumichael.me A` → should return `52.202.179.6`
2. Verify port 80 is open: `nc -zv 52.202.179.6 80`
3. Delete the challenge to force a retry:
   ```bash
   kubectl delete challenge -n kubeclaw --all
   ```

### ✅ 7. Domain Works in Browser

After TLS is `READY: True`, get your gateway token:
```bash
kubectl -n kubeclaw get secret kubeclaw-secret \
  -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d
```
Open: `https://openclaw.modumichael.me/#token=<token>`

---

## Using Lens (Since You Just Downloaded It)

Lens gives you a GUI for everything above. Here's what to use it for:

| Task | Lens Path |
|------|-----------|
| See why pods crash | Workloads → Pods → click pod → scroll to **Events** |
| Watch pod restarts | Workloads → Pods → watch the **Restarts** column |
| Port forward without CLI | Right-click any pod → **Port Forward** → enter 18789 |
| View Flux HelmRelease status | Custom Resources → `HelmRelease` |
| View OpenClawInstance status | Custom Resources → `OpenClawInstance` |
| View ACME challenges | Custom Resources → `Challenge` |
| Check certificate status | Custom Resources → `Certificate` |
| Read pod logs | Workloads → Pods → click pod → **Logs** tab |
| Check resource usage | Nodes → click node → CPU/Memory graphs |

**For Sealed Secrets in Lens:** Custom Resources → `SealedSecret` — you can see if it's been decrypted successfully (it shows a green tick when the controller has processed it).

---

## Networking Architecture (Updated)

```
Internet
    │
    ▼ (NAT: 52.202.179.6 → 172.31.19.108)
EC2 eth0 (172.31.19.108)
    │
    ▼ kube-proxy DNAT (externalIPs)
nginx-ingress-controller (ingress-nginx namespace)
    │           │
    │           ├─── modumichael.me ──────► mattermost.mattermost:8065
    │           │
    │           └─── openclaw.modumichael.me ► kubeclaw.kubeclaw:18789
    │                                                     │
    │                                          (OpenClaw Gateway pod)
    │                                                     │
    │                                          kubeclaw-litellm:4000
    │                                          (LiteLLM proxy)
    │                                           ├─ api.openai.com
    │                                           └─ generativelanguage.googleapis.com
```

MetalLB pool `172.31.19.108/32` → nginx-ingress only (one LoadBalancer IP, one consumer).
No Gateway API, no Envoy, no NodePort exposure.

---

## Troubleshooting

### "OpenClawInstance" CRD not found after reconcile

The operator takes a few minutes to install its CRDs. If apps reconcile before infra finishes:
```bash
kubectl get crd openclawinstances.openclaw.rocks
# If missing, force infra reconcile first:
flux reconcile kustomization infrastructure --with-source --timeout=15m
# Then re-trigger apps:
flux reconcile kustomization apps --with-source
```

### kubeclaw-0 pod in CrashLoopBackOff

```bash
kubectl describe pod -n kubeclaw kubeclaw-0   # look at Events
kubectl logs -n kubeclaw kubeclaw-0 --previous  # logs from last crash
```

Common cause: kubeclaw-secret not yet decrypted. If the pod starts before the Sealed Secrets
controller has processed the SealedSecret, the envFrom reference fails. The operator should
retry — just wait 2–3 minutes. If it persists:
```bash
kubectl rollout restart statefulset/kubeclaw -n kubeclaw
```

### LiteLLM returns 401 or "Invalid API Key"

The API key reached litellm but was rejected by the upstream provider.
1. Decode the key from the secret: `kubectl get secret kubeclaw-secret -n kubeclaw -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d`
2. Verify it's valid at https://platform.openai.com/api-keys
3. If you need to rotate it: update `.env`, re-run `scripts/06-setup-kubeclaw.sh` (Phase 8), push the new SealedSecret.

### Mattermost bot not responding to slash commands

The callback URL (`http://kubeclaw.kubeclaw.svc.cluster.local:18789/...`) must be reachable
from the Mattermost pod. Verify the NetworkPolicy allows it:
```bash
kubectl get networkpolicy allow-mattermost-slash-callbacks -n kubeclaw
```
If missing, `apps/kubeclaw/networkpolicy-mattermost.yaml` wasn't applied. Force reconcile:
```bash
flux reconcile kustomization apps --with-source
```

Test the callback route from inside the Mattermost pod:
```bash
MM_POD=$(kubectl get pod -n mattermost -l app=mattermost -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n mattermost $MM_POD -- \
  curl -s -o /dev/null -w "%{http_code}" \
  http://kubeclaw.kubeclaw.svc.cluster.local:18789/api/channels/mattermost/command
```
Expected: `405` (Method Not Allowed for GET) — that means the route is reachable.

### openclaw.modumichael.me gives TLS error

If you see "NET::ERR_CERT_AUTHORITY_INVALID", it means the cert is still being issued.
Check: `kubectl get certificate kubeclaw-tls -n kubeclaw` — wait for `READY: True`.

If you see a connection refused or timeout, nginx isn't routing it:
```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=30
```

---

## Day-2 Operations

| Task | Command |
|------|---------|
| Check all Flux status | `flux get all -A` |
| Force full sync | `flux reconcile source git flux-system && flux reconcile kustomization apps --with-source` |
| Rotate a secret | Re-run `scripts/06-setup-kubeclaw.sh` Phase 8, push new SealedSecret |
| OpenClaw logs | `kubectl logs -n kubeclaw kubeclaw-0 -f` |
| LiteLLM logs | `kubectl logs -n kubeclaw deploy/litellm -f` |
| Approve bot pairings | `bash scripts/07-manage-bot.sh` |
| Add bot to channel | `bash scripts/07-manage-bot.sh` → option 4 |
| Scale litellm (if needed) | `kubectl scale deploy/litellm -n kubeclaw --replicas=2` |
| Enable Chromium later | Edit `openclawinstance.yaml` → `chromium.enabled: true`, commit & push |

---

## Important: openclaw-operator controller-manager Name

The health check in `clusters/production/infrastructure.yaml` expects the Deployment to be
named `openclaw-operator-controller-manager`. Verify this after first install:

```bash
kubectl get deploy -n openclaw-operator-system
```

If the name differs (e.g. `openclaw-operator`), update the healthCheck name accordingly
in `clusters/production/infrastructure.yaml` and re-commit.
