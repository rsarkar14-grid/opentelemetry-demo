#!/usr/bin/env bash
# start-kind.sh — Bring up the AEGIS stack with a kind cluster + opentelemetry-demo
#
# Usage:
#   ./start-kind.sh              # full startup
#   ./start-kind.sh --skip-demo  # skip opentelemetry-demo Helm deployment
#
# Teardown:
#   docker compose down
#   kind delete cluster --name kind-aegis

set -euo pipefail

CLUSTER_NAME="kind-aegis"
CONTEXT="kind-${CLUSTER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Path to the AEGIS backend repo (docker compose stack + postgres). Override with AEGIS_REPO=...
AEGIS_REPO="${AEGIS_REPO:-$(cd "${SCRIPT_DIR}/../.." && pwd)/sre-aegis-backend}"
SKIP_DEMO="${1:-}"

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
for cmd in kind kubectl helm docker curl python3; do
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

# ── Step 2: Normalise kubeconfig server URL ───────────────────────────────────
# When kind-config.yaml has extraPortMappings with hostPort: 6443, kind may
# write server: https://0.0.0.0:6443 into the kubeconfig. The API server cert
# has SANs for 127.0.0.1 but not 0.0.0.0, so kubectl commands fail with TLS
# errors. Rewrite to 127.0.0.1 (which IS in the SANs) for host-side kubectl.
log "Step 2 — Normalising kubeconfig server URL..."
KUBE_CLUSTER_NAME="kind-${CLUSTER_NAME}"
CURRENT_SERVER=$(kubectl config view --raw \
  -o jsonpath="{.clusters[?(@.name==\"${KUBE_CLUSTER_NAME}\")].cluster.server}" 2>/dev/null || true)
if echo "${CURRENT_SERVER}" | grep -q "0.0.0.0"; then
  kubectl config set-cluster "${KUBE_CLUSTER_NAME}" --server="https://127.0.0.1:6443"
  ok "Rewrote server URL from 0.0.0.0:6443 → 127.0.0.1:6443"
else
  ok "Server URL already correct (${CURRENT_SERVER})"
fi

# Generate a separate kubeconfig for Docker containers (must use the control-plane
# Docker hostname, not localhost, since localhost inside a container is the container itself).
KUBECONFIG_DOCKER="${HOME}/.kube/${CLUSTER_NAME}-docker.kubeconfig"
kind get kubeconfig --name "${CLUSTER_NAME}" \
  | sed 's|https://127.0.0.1:6443|https://kind-aegis-control-plane:6443|g' \
  | sed 's|https://0.0.0.0:6443|https://kind-aegis-control-plane:6443|g' \
  > "${KUBECONFIG_DOCKER}"
ok "Docker kubeconfig written to ${KUBECONFIG_DOCKER}"

# ── Step 3: Start AEGIS Docker Compose stack ──────────────────────────────────
log "Step 3 — Starting AEGIS Docker Compose stack..."
[[ -f "${AEGIS_REPO}/docker-compose.yml" ]] || die "AEGIS repo not found at ${AEGIS_REPO} — set AEGIS_REPO=/path/to/sre-aegis-backend"
cd "${AEGIS_REPO}"
docker compose up -d
ok "Stack started"

# ── Step 4: Register cluster in PostgreSQL ───────────────────────────────────
log "Step 4 — Registering kind cluster in k8s_clusters table..."

# Extract CA cert, client cert, and client key from the kubeconfig
KUBE_RAW=$(kind get kubeconfig --name "${CLUSTER_NAME}")
CA_CERT=$(echo "$KUBE_RAW" | python3 -c "
import sys, yaml, base64
kc = yaml.safe_load(sys.stdin)
ca_b64 = kc['clusters'][0]['cluster']['certificate-authority-data']
print(base64.b64decode(ca_b64).decode())
")
CLIENT_CERT=$(echo "$KUBE_RAW" | python3 -c "
import sys, yaml, base64
kc = yaml.safe_load(sys.stdin)
cert_b64 = kc['users'][0]['user']['client-certificate-data']
print(base64.b64decode(cert_b64).decode())
")
CLIENT_KEY=$(echo "$KUBE_RAW" | python3 -c "
import sys, yaml, base64
kc = yaml.safe_load(sys.stdin)
key_b64 = kc['users'][0]['user']['client-key-data']
print(base64.b64decode(key_b64).decode())
")

# Wait for PostgreSQL to be ready (docker compose up should have started it)
for i in $(seq 1 15); do
  if docker exec aegis-postgres pg_isready -U aegis &>/dev/null; then
    break
  fi
  if [[ $i -eq 15 ]]; then
    die "PostgreSQL not ready after 30s"
  fi
  sleep 2
done

# Upsert the cluster record — idempotent, safe to re-run
docker exec -i aegis-postgres psql -U aegis -d aegis <<EOSQL
INSERT INTO k8s_clusters (
    tenant_id, cluster_name, api_server_url,
    ca_cert_pem, auth_type, client_cert_pem, client_key_pem
) VALUES (
    'acme-corp',
    '${CLUSTER_NAME}',
    'https://${CLUSTER_NAME}-control-plane:6443',
    '${CA_CERT}',
    'client_cert',
    '${CLIENT_CERT}',
    '${CLIENT_KEY}'
)
ON CONFLICT (tenant_id, cluster_name) DO UPDATE SET
    api_server_url  = EXCLUDED.api_server_url,
    ca_cert_pem     = EXCLUDED.ca_cert_pem,
    client_cert_pem = EXCLUDED.client_cert_pem,
    client_key_pem  = EXCLUDED.client_key_pem,
    updated_at      = NOW();
EOSQL
ok "Cluster '${CLUSTER_NAME}' registered in k8s_clusters (tenant=acme-corp)"

# ── Step 5: Wait for IAM service ─────────────────────────────────────────────
log "Step 5 — Waiting for IAM service..."
for i in $(seq 1 30); do
  STATUS=$(curl -sf http://localhost:8008/health 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null \
    || true)
  if [[ "$STATUS" == "ok" ]]; then
    ok "IAM service is healthy"
    break
  fi
  if [[ $i -eq 30 ]]; then
    die "IAM service not healthy after 60s. Debug: curl http://localhost:8008/health"
  fi
  printf "  waiting for IAM service... (%d/30)\r" "$i"
  sleep 2
done

# ── Step 6: Wait for k8s-mcp to reach the cluster ────────────────────────────
log "Step 6 — Waiting for k8s-mcp to reach the kind cluster..."
for i in $(seq 1 30); do
  STATUS=$(curl -sf http://localhost:8001/ready 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null \
    || true)
  if [[ "$STATUS" == "ready" ]]; then
    ok "k8s-mcp is ready"
    break
  fi
  if [[ $i -eq 30 ]]; then
    die "k8s-mcp not ready after 60s. Debug: curl http://localhost:8001/ready"
  fi
  printf "  waiting for k8s-mcp... (%d/30)\r" "$i"
  sleep 2
done

# ── Step 7: Deploy OTel DaemonSet ─────────────────────────────────────────────
log "Step 7 — Deploying OTel DaemonSet (kubeletstats + filelog + k8s events)..."
# The DaemonSet and the demo collector push to AEGIS with an `agent`-scoped key.
apply_aegis_telemetry_credentials
kubectl --context "${CONTEXT}" apply --validate=false -f "${SCRIPT_DIR}/otel-daemonset.yaml"
kubectl --context "${CONTEXT}" -n otel-system rollout status daemonset/otel-agent --timeout=120s
ok "OTel DaemonSet ready"

# ── Step 8: Deploy opentelemetry-demo ─────────────────────────────────────────
if [[ "$SKIP_DEMO" == "--skip-demo" ]]; then
  warn "Skipping opentelemetry-demo deployment (--skip-demo)"
else
  log "Step 8 — Deploying opentelemetry-demo via Helm..."

  # Namespace (idempotent)
  kubectl --context "${CONTEXT}" create namespace otel-demo --dry-run=client -o yaml \
    | kubectl --context "${CONTEXT}" apply --validate=false -f -
  # aegis-credentials (agent-scoped key) was applied with the DaemonSet step.

  # Helm repo
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
  helm repo update open-telemetry

  # Verify the collector values key in the chart matches values-aegis.yaml
  COLLECTOR_KEY=$(helm show values open-telemetry/opentelemetry-demo 2>/dev/null \
    | grep -E "^opentelemetry-collector:" | head -1 || true)
  if [[ -z "$COLLECTOR_KEY" ]]; then
    warn "Could not find 'opentelemetry-collector:' as a top-level key in chart values."
    warn "Check the correct key with:"
    warn "  helm show values open-telemetry/opentelemetry-demo | grep -E '^[a-z]' | sort"
    warn "Then update the top-level key in kind-deploy/values-aegis.yaml if needed."
    read -r -p "  Press Enter to continue anyway, or Ctrl+C to abort: "
  fi

  # Reset NodePort services to ClusterIP so helm upgrade has no field-manager conflict.
  # The NodePort patches are re-applied in Step 10 after the upgrade completes.
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

  # ── Step 9: Register opentelemetry-demo app via IAM service ────────────────
  log "Step 9 — Registering opentelemetry-demo app via IAM service..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:8008/apps/register \
    -H "Content-Type: application/json" \
    -H "X-Tenant-ID: acme-corp" \
    -H "X-Caller-Role: admin" \
    -d '{
      "name": "opentelemetry-demo",
      "display_name": "OpenTelemetry Demo",
      "object_type": "otel_app",
      "k8s_namespace": "otel-demo",
      "k8s_cluster_name": "kind-aegis",
      "description": "OpenTelemetry astronomy shop demo application running in the kind cluster."
    }' 2>/dev/null || echo "000")

  if [[ "$HTTP_CODE" == "200" ]]; then
    ok "opentelemetry-demo app registered (OpenFGA store + registered_apps)"
  elif [[ "$HTTP_CODE" == "409" ]]; then
    ok "opentelemetry-demo app already registered (409 — idempotent)"
  else
    warn "App registration returned HTTP ${HTTP_CODE} (non-fatal — can be registered later via POST /apps/register)"
  fi

  # ── Step 10: Expose frontend and Jaeger via NodePort ────────────────────────
  # The current load-generator is a headless k6 Deployment and intentionally
  # has no Service or web UI.
  log "Step 10 — Patching services to NodePort..."

  patch_nodeport() {
    local svc=$1 port=$2 nodeport=$3
    if kubectl --context "${CONTEXT}" -n otel-demo get svc "$svc" &>/dev/null; then
      # Strategic merge patch — targets the specific port by port number,
      # safe for multi-port services like jaeger.
      kubectl --context "${CONTEXT}" -n otel-demo patch svc "$svc" \
        --type='strategic' \
        -p="{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":${port},\"nodePort\":${nodeport}}]}}" \
        2>/dev/null \
        && ok "  ${svc}:${port} → localhost:${nodeport}" \
        || warn "  Could not patch ${svc} (nodePort ${nodeport} may already be set)"
    else
      warn "  Service '${svc}' not found — run 'kubectl -n otel-demo get svc' to list available services"
    fi
  }

  # Actual service names as deployed by the chart (no otel-demo- prefix)
  patch_nodeport "frontend-proxy" 8080  30080
  patch_nodeport "jaeger"         16686 30686
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  AEGIS + kind cluster is up${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if [[ "$SKIP_DEMO" != "--skip-demo" ]]; then
echo "  Demo frontend     http://localhost:30080          (generates live telemetry)"
echo "  Feature flags     http://localhost:30080/feature  (flagd-ui, toggle demo flags)"
echo "  Load generator    headless k6 Deployment (runs automatically; no Service/UI)"
echo "  Jaeger UI         http://localhost:30686          (in-cluster traces)"
echo ""
fi
echo "  Grafana (apps)    http://localhost:3000    (external app telemetry)"
echo "  Grafana (AEGIS)   http://localhost:3001    (AEGIS platform telemetry)"
echo "  Prometheus        http://localhost:9090"
echo "  AEGIS API         http://localhost:8000/health"
echo "  IAM Service       http://localhost:8008/health"
echo "  k8s-mcp           http://localhost:8001/ready"
echo "  k8s-mcp clusters  http://localhost:8001/clusters"
echo ""
echo "  kubectl context:  ${CONTEXT}"
echo ""
echo "  Teardown:  docker compose down && kind delete cluster --name ${CLUSTER_NAME}"
echo ""
