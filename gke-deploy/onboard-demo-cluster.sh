#!/usr/bin/env bash
# onboard-demo-cluster.sh — register demo-cluster + the opentelemetry-demo app
# with AEGIS, using the EXISTING onboarding API (no AEGIS code changes).
#
# Prerequisites:
#   1. aayyagari@ has applied gke-deploy/aegis-rbac.yaml
#   2. The ServiceAccount token is in Secret Manager as demo-cluster-aegis-token
#      (or export AEGIS_SA_TOKEN=... directly)
#   3. export AEGIS_API_KEY=<tenant API key for acme-corp>
#
# Usage:
#   AEGIS_API_KEY=... ./gke-deploy/onboard-demo-cluster.sh
set -euo pipefail

PROJECT="gd-gcp-presales-india-auto-sre"
ZONE="us-central1-a"
CLUSTER="demo-cluster"
APP_NAME="opentelemetry-demo"      # MUST equal the collector's service.namespace
OBJECT_TYPE="otel_demo"
K8S_NAMESPACE="otel-demo"
# Onboarding is a server-to-server call, so it goes straight to the GKE ingress —
# it does NOT need the ngrok tunnel running. Override with AEGIS_URL=... if you
# prefer the tunnel (e.g. https://postcard-unvisited-supernova.ngrok-free.dev).
AEGIS_URL="${AEGIS_URL:-https://aegis.griddynamics.net}"

: "${AEGIS_API_KEY:?Set AEGIS_API_KEY}"

# ── API server: the PRIVATE endpoint, not the public one ─────────────────────
# Verified from inside an AEGIS pod:
#   https://10.4.0.2/version      -> 401 Unauthorized  (reachable)
#   https://34.58.171.103/version -> ConnectTimeout    (NOT reachable)
# AEGIS pods egress to public IPs via node NAT, and that address is not in the
# cluster's authorized networks. The private endpoint works because the AEGIS
# pod CIDR 10.1.0.0/16 is authorized and GKE does not masquerade pod IPs to
# RFC1918 destinations. TLS also validates against the GKE CA on this IP.
API_SERVER="https://$(gcloud container clusters describe "$CLUSTER" \
  --zone "$ZONE" --project "$PROJECT" \
  --format='value(privateClusterConfig.privateEndpoint)')"

CA_PEM="$(gcloud container clusters describe "$CLUSTER" \
  --zone "$ZONE" --project "$PROJECT" \
  --format='value(masterAuth.clusterCaCertificate)' | base64 -d)"

SA_TOKEN="${AEGIS_SA_TOKEN:-$(gcloud secrets versions access latest \
  --secret=demo-cluster-aegis-token --project="$PROJECT")}"

echo "==> API server : $API_SERVER"
echo "==> CA         : ${#CA_PEM} bytes"
echo "==> Token      : ${#SA_TOKEN} chars"

BODY=$(API_SERVER="$API_SERVER" CA_PEM="$CA_PEM" SA_TOKEN="$SA_TOKEN" \
  APP_NAME="$APP_NAME" OBJECT_TYPE="$OBJECT_TYPE" \
  K8S_NAMESPACE="$K8S_NAMESPACE" CLUSTER="$CLUSTER" python3 - <<'PY'
import json, os
print(json.dumps({
    "name":             os.environ["APP_NAME"],
    "display_name":     "OpenTelemetry Demo",
    "object_type":      os.environ["OBJECT_TYPE"],
    "description":      "Astronomy webshop demo workload on demo-cluster",
    "k8s_namespace":    os.environ["K8S_NAMESPACE"],
    "k8s_cluster_name": os.environ["CLUSTER"],
    "api_server_url":   os.environ["API_SERVER"],
    "ca_cert_pem":      os.environ["CA_PEM"],
    "auth_type":        "token",
    "bearer_token":     os.environ["SA_TOKEN"],
}))
PY
)

echo "==> Registering with AEGIS"
curl -sS -w '\nHTTP=%{http_code}\n' -X POST "$AEGIS_URL/v1/iam/apps/register" \
  -H "Content-Type: application/json" \
  -H "X-AEGIS-API-KEY: $AEGIS_API_KEY" \
  -H "ngrok-skip-browser-warning: true" \
  --data "$BODY"

echo
echo "==> Verify"
echo "  curl -s $AEGIS_URL/v1/iam/apps -H 'X-AEGIS-API-KEY: \$AEGIS_API_KEY' | jq '.apps[].name'"
echo "  # then trigger a Jira-style ticket and watch rca_results"
