#!/usr/bin/env bash
# deploy-gke.sh — deploy opentelemetry-demo to the GKE demo cluster and stream
# all telemetry to AEGIS.
#
# Usage:
#   AEGIS_API_KEY=<tenant key> ./gke-deploy/deploy-gke.sh
#
# To run services built from this repo's source instead of the chart's images,
# push them with build-push-images.sh and pass the same values here:
#   IMAGE_REPO=<registry>/<path>/demo IMAGE_TAG=<tag> SOURCE_SERVICES="frontend" \
#   AEGIS_API_KEY=... ./gke-deploy/deploy-gke.sh
set -euo pipefail

PROJECT="gd-gcp-presales-india-auto-sre"
ZONE="us-central1-a"
CLUSTER="demo-cluster"
NAMESPACE="otel-demo"
CHART_VERSION="0.41.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${AEGIS_API_KEY:?Set AEGIS_API_KEY to the AEGIS tenant API key}"

IMAGE_ARGS=()
if [[ -n "${IMAGE_REPO:-}" ]]; then
  : "${IMAGE_TAG:?Set IMAGE_TAG together with IMAGE_REPO}"
  for svc in ${SOURCE_SERVICES:-frontend}; do
    IMAGE_ARGS+=(
      --set-string "components.${svc}.imageOverride.repository=${IMAGE_REPO}"
      --set-string "components.${svc}.imageOverride.tag=${IMAGE_TAG}-${svc}"
    )
  done
fi

echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"

echo "==> Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> AEGIS API key secret"
kubectl create secret generic aegis-credentials -n "$NAMESPACE" \
  --from-literal=api-key="$AEGIS_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Flag file from src/flagd/demo.flagd.json"
kubectl create configmap flagd-config-main -n "$NAMESPACE" \
  --from-file=demo.flagd.json="$REPO_ROOT/src/flagd/demo.flagd.json" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Helm repo"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null

echo "==> Deploying opentelemetry-demo (chart $CHART_VERSION)"
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --values "$SCRIPT_DIR/values-aegis-gke.yaml" \
  ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} \
  --wait --timeout 15m

# The chart's values schema only allows httpGet probes and the cart serves
# gRPC over HTTP/2, so the probe is applied to the Deployment directly.
echo "==> Cart readiness probe"
kubectl patch deployment cart -n "$NAMESPACE" --type=strategic \
  --patch-file "$SCRIPT_DIR/cart-readiness-patch.yaml"
kubectl rollout status deployment/cart -n "$NAMESPACE" --timeout=5m

# flagd copies the flag file into an emptyDir only when its pod starts.
echo "==> Restarting flagd to load the current flag file"
kubectl rollout restart deployment/flagd -n "$NAMESPACE"
kubectl rollout status deployment/flagd -n "$NAMESPACE" --timeout=5m

echo "==> Kubernetes events collector"
kubectl get clusterrole otel-events >/dev/null 2>&1 || echo \
  "WARNING: ClusterRole otel-events not found or not readable. Ask a roles/container.admin holder to apply gke-deploy/aegis-rbac.yaml, or no events will be sent."
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
