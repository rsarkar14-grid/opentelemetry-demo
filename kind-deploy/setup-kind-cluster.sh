#!/usr/bin/env bash
# setup-kind-cluster.sh — Provision ONLY the kind cluster + workloads, with no
# AEGIS-side registration. Use this to manually test the frontend "onboard app +
# cluster" flow: this script creates the cluster and writes out the credentials
# you paste into the onboarding modal, instead of registering them in the DB.
#
# What it does:
#   1. Creates the kind cluster
#   2. Generates the Docker-network kubeconfig (control-plane hostname)
#   3. Saves ca_cert / client_cert / client_key from the raw kubeconfig to files
#   4. Deploys the OTel DaemonSet
#   5. Deploys opentelemetry-demo
#
# What it deliberately does NOT do (the frontend does these):
#   - Insert into k8s_clusters
#   - POST /apps/register
#   - Start the AEGIS docker compose stack (assumed already running)
#
# Usage:
#   ./setup-kind-cluster.sh              # full setup
#   ./setup-kind-cluster.sh --skip-demo  # skip opentelemetry-demo Helm deployment
#
# Teardown:
#   kind delete cluster --name kind-aegis

set -euo pipefail

CLUSTER_NAME="kind-aegis"
CONTEXT="kind-${CLUSTER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_DEMO="${1:-}"

# Where the cluster credential files are written (outside the repo by default so
# the private key is never accidentally committed). Override with CREDS_DIR=...
CREDS_DIR="${CREDS_DIR:-${HOME}/.kube/${CLUSTER_NAME}-creds}"

# The API server URL to enter in the onboarding form. AEGIS services (BFF,
# k8s-mcp) reach the cluster over the `kind` Docker network using the
# control-plane container hostname — NOT localhost.
DOCKER_API_SERVER="https://${CLUSTER_NAME}-control-plane:6443"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}▶  $*${NC}"; }
ok()   { echo -e "${GREEN}✓  $*${NC}"; }
warn() { echo -e "${YELLOW}⚠  $*${NC}"; }
die()  { echo -e "${RED}✗  $*${NC}"; exit 1; }

# shellcheck source=aegis-telemetry-key.sh
source "${SCRIPT_DIR}/aegis-telemetry-key.sh"

# ── Prerequisites ─────────────────────────────────────────────────────────────
log "Checking prerequisites..."
for cmd in kind kubectl helm python3; do
  command -v "$cmd" &>/dev/null || die "'$cmd' not found in PATH"
done
ok "All prerequisites found"

# ── Step 1: Create kind cluster ───────────────────────────────────────────────
log "Step 1 — Creating kind cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
else
  kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
  ok "Cluster '${CLUSTER_NAME}' created"
fi

# ── Step 2: Normalise kubeconfig server URL (host-side kubectl) ───────────────
# kind may write server: https://0.0.0.0:6443; the API server cert has a SAN for
# 127.0.0.1 but not 0.0.0.0, so rewrite it for host-side kubectl to work.
log "Step 2 — Normalising host kubeconfig server URL..."
KUBE_CLUSTER_NAME="kind-${CLUSTER_NAME}"
CURRENT_SERVER=$(kubectl config view --raw \
  -o jsonpath="{.clusters[?(@.name==\"${KUBE_CLUSTER_NAME}\")].cluster.server}" 2>/dev/null || true)
if echo "${CURRENT_SERVER}" | grep -q "0.0.0.0"; then
  kubectl config set-cluster "${KUBE_CLUSTER_NAME}" --server="https://127.0.0.1:6443"
  ok "Rewrote server URL from 0.0.0.0:6443 → 127.0.0.1:6443"
else
  ok "Server URL already correct (${CURRENT_SERVER})"
fi

# ── Step 2b: Docker-network kubeconfig ────────────────────────────────────────
# Separate kubeconfig for containers: localhost inside a container is the
# container itself, so use the control-plane Docker hostname instead.
KUBECONFIG_DOCKER="${HOME}/.kube/${CLUSTER_NAME}-docker.kubeconfig"
kind get kubeconfig --name "${CLUSTER_NAME}" \
  | sed "s|https://127.0.0.1:6443|${DOCKER_API_SERVER}|g" \
  | sed "s|https://0.0.0.0:6443|${DOCKER_API_SERVER}|g" \
  > "${KUBECONFIG_DOCKER}"
ok "Docker kubeconfig written to ${KUBECONFIG_DOCKER}"

# ── Step 3: Extract cluster credentials to separate files ─────────────────────
# These are what you paste into the frontend onboarding modal.
log "Step 3 — Extracting ca_cert / client_cert / client_key to ${CREDS_DIR}..."
mkdir -p "${CREDS_DIR}"
KUBE_RAW_JSON=$(kubectl --kubeconfig="${KUBECONFIG_DOCKER}" config view --raw -o json)

extract_pem() {
  # $1 = Python path into the kubeconfig dict yielding base64 PEM data.
  echo "$KUBE_RAW_JSON" | python3 -c "
import sys, json, base64
kc = json.load(sys.stdin)
print(base64.b64decode($1).decode(), end='')
"
}

extract_pem "kc['clusters'][0]['cluster']['certificate-authority-data']" > "${CREDS_DIR}/ca_cert.pem"
extract_pem "kc['users'][0]['user']['client-certificate-data']"          > "${CREDS_DIR}/client_cert.pem"
extract_pem "kc['users'][0]['user']['client-key-data']"                  > "${CREDS_DIR}/client_key.pem"

chmod 600 "${CREDS_DIR}/ca_cert.pem" "${CREDS_DIR}/client_cert.pem" "${CREDS_DIR}/client_key.pem"

# Sanity check: each file must be a non-empty PEM block.
for f in ca_cert client_cert client_key; do
  head -1 "${CREDS_DIR}/${f}.pem" | grep -q "BEGIN" \
    || die "${CREDS_DIR}/${f}.pem does not look like a PEM file"
done
ok "Wrote ca_cert.pem, client_cert.pem, client_key.pem (mode 600)"

# ── Step 4: Deploy OTel DaemonSet ─────────────────────────────────────────────
log "Step 4 — Deploying OTel DaemonSet (kubeletstats + filelog + k8s events)..."
# The DaemonSet and the demo collector push to AEGIS with an `agent`-scoped key.
apply_aegis_telemetry_credentials
kubectl --context "${CONTEXT}" apply --validate=false -f "${SCRIPT_DIR}/otel-daemonset.yaml"
kubectl --context "${CONTEXT}" -n otel-system rollout status daemonset/otel-agent --timeout=120s
ok "OTel DaemonSet ready"

# ── Step 5: Deploy opentelemetry-demo ─────────────────────────────────────────
if [[ "$SKIP_DEMO" == "--skip-demo" ]]; then
  warn "Skipping opentelemetry-demo deployment (--skip-demo)"
else
  log "Step 5 — Deploying opentelemetry-demo via Helm..."

  # Namespace (idempotent)
  kubectl --context "${CONTEXT}" create namespace otel-demo --dry-run=client -o yaml \
    | kubectl --context "${CONTEXT}" apply --validate=false -f -
  # aegis-credentials (agent-scoped key) was applied with the DaemonSet step.

  # Helm repo
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
  helm repo update open-telemetry

  # Reset NodePort services to ClusterIP so helm upgrade has no field-manager conflict.
  for svc in frontend-proxy jaeger; do
    if kubectl --context "${CONTEXT}" -n otel-demo get svc "$svc" &>/dev/null; then
      kubectl --context "${CONTEXT}" -n otel-demo patch svc "$svc" \
        --type='strategic' -p='{"spec":{"type":"ClusterIP"}}' 2>/dev/null || true
    fi
  done

  helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
    --kube-context "${CONTEXT}" \
    --namespace otel-demo \
    --values "${SCRIPT_DIR}/values-aegis.yaml"
  ok "opentelemetry-demo deployed"

  # Expose frontend and Jaeger via NodePort. The current load-generator is a
  # headless k6 Deployment and intentionally has no Service or web UI.
  log "Patching services to NodePort..."
  patch_nodeport() {
    local svc=$1 port=$2 nodeport=$3
    if kubectl --context "${CONTEXT}" -n otel-demo get svc "$svc" &>/dev/null; then
      kubectl --context "${CONTEXT}" -n otel-demo patch svc "$svc" \
        --type='strategic' \
        -p="{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":${port},\"nodePort\":${nodeport}}]}}" \
        2>/dev/null \
        && ok "  ${svc}:${port} → localhost:${nodeport}" \
        || warn "  Could not patch ${svc} (nodePort ${nodeport} may already be set)"
    else
      warn "  Service '${svc}' not found"
    fi
  }
  patch_nodeport "frontend-proxy" 8080  30080
  patch_nodeport "jaeger"         16686 30686
fi

# ── Summary — values to paste into the frontend onboarding modal ──────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  kind cluster '${CLUSTER_NAME}' is up — NOT registered in AEGIS${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Use these values in the frontend 'Onboard application' form:"
echo ""
echo -e "    Cluster name      ${BLUE}${CLUSTER_NAME}${NC}"
echo -e "    API server URL    ${BLUE}${DOCKER_API_SERVER}${NC}   (Docker hostname, NOT localhost)"
echo -e "    Auth type         ${BLUE}client_cert${NC}"
echo -e "    k8s namespace     ${BLUE}otel-demo${NC}   (for the opentelemetry-demo app)"
echo ""
echo "    CA certificate    ${CREDS_DIR}/ca_cert.pem"
echo "    Client cert       ${CREDS_DIR}/client_cert.pem"
echo "    Client key        ${CREDS_DIR}/client_key.pem"
echo ""
echo "  Copy a file's contents to the clipboard (macOS):"
echo "    pbcopy < ${CREDS_DIR}/ca_cert.pem"
echo ""
if [[ "$SKIP_DEMO" != "--skip-demo" ]]; then
echo "  Demo frontend     http://localhost:30080          (generates live telemetry)"
echo "  Feature flags     http://localhost:30080/feature  (flagd-ui, toggle demo flags)"
echo "  Load generator    headless k6 Deployment (runs automatically; no Service/UI)"
echo "  Jaeger UI         http://localhost:30686          (in-cluster traces)"
echo ""
fi
echo "  kubectl context:  ${CONTEXT}"
echo "  Docker kubeconfig: ${KUBECONFIG_DOCKER}"
echo ""
echo "  Teardown:  kind delete cluster --name ${CLUSTER_NAME}"
echo ""
