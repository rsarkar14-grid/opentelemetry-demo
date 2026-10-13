#!/usr/bin/env bash
# deploy-gke.sh — deploy opentelemetry-demo to the GKE demo cluster and stream
# all telemetry to AEGIS.
#
# Usage:
#   AEGIS_API_KEY=<tenant key> ./gke-deploy/deploy-gke.sh
set -euo pipefail

PROJECT="gd-gcp-presales-india-auto-sre"
ZONE="us-central1-a"
CLUSTER="demo-cluster"
NAMESPACE="otel-demo"
CHART_VERSION="0.41.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${AEGIS_API_KEY:?Set AEGIS_API_KEY to the AEGIS tenant API key}"

echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"

echo "==> Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> AEGIS API key secret"
kubectl create secret generic aegis-credentials -n "$NAMESPACE" \
  --from-literal=api-key="$AEGIS_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Helm repo"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null

echo "==> Deploying opentelemetry-demo (chart $CHART_VERSION)"
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --values "$SCRIPT_DIR/values-aegis-gke.yaml" \
  --wait --timeout 15m

echo "==> Kubernetes events collector"
kubectl apply -f "$SCRIPT_DIR/otel-events-gke.yaml"

echo "==> Waiting for pods"
kubectl wait --for=condition=ready pod --all -n "$NAMESPACE" --timeout=10m || true

echo
echo "Pods:"
kubectl get pods -n "$NAMESPACE"
echo
echo "Verify telemetry is leaving the cluster:"
echo "  kubectl logs -n $NAMESPACE deploy/otel-events --tail=20"
echo "  kubectl logs -n $NAMESPACE daemonset/otel-collector --tail=20 | grep -i aegis"
echo
echo "Verify it ARRIVED in AEGIS (run against the aegis-cluster context):"
echo "  kubectl exec -n aegis-dev deploy/api-gateway -c api-gateway -- \\"
echo "    python -c \"import httpx;print(httpx.get('http://loki:3100/loki/api/v1/labels').text)\""
