#!/usr/bin/env bash
# create-cluster.sh — create the GKE cluster that deploy-gke.sh deploys to.
#
# Usage:
#   ./gke-deploy/create-cluster.sh
#   DRY_RUN=1 ./gke-deploy/create-cluster.sh    # print the gcloud command only
#
# Optional environment:
#   OPERATOR_CIDR=<ip>/32          workstation allowed to reach the control plane
#                                  (default: this machine's public IPv4)
#   USE_SPOT=1                     Spot VMs: cheaper, but nodes can be reclaimed at any time
#   NODE_SERVICE_ACCOUNT=<email>   node service account (default: Compute Engine default)
#
# This only creates the cluster. Applying aegis-rbac.yaml needs roles/container.admin
# and is a separate step (see README.md).
set -euo pipefail

PROJECT="gd-gcp-presales-india-auto-sre"
ZONE="us-central1-a"
CLUSTER="demo-cluster"
NETWORK="aegis-vpc"
SUBNET="demo-subnet"
PODS_RANGE="demo-pods"
SERVICES_RANGE="demo-svcs"
NODE_COUNT=3
MACHINE_TYPE="e2-standard-4"
# AEGIS pod range and node subnet: how AEGIS reaches this control plane.
AEGIS_NETWORKS="10.1.0.0/16,10.0.0.0/20"
REGION="${ZONE%-*}"

if gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1; then
  echo "Cluster $CLUSTER already exists in $PROJECT ($ZONE); nothing to do."
  exit 0
fi

echo "==> Checking subnet $SUBNET secondary ranges"
ranges="$(gcloud compute networks subnets describe "$SUBNET" --region "$REGION" --project "$PROJECT" \
  --format='value(secondaryIpRanges[].rangeName)')"
for r in "$PODS_RANGE" "$SERVICES_RANGE"; do
  [[ ";$ranges;" == *";$r;"* ]] || { echo "Subnet $SUBNET has no secondary range '$r' (found: ${ranges:-none})" >&2; exit 1; }
done

OPERATOR_CIDR="${OPERATOR_CIDR:-}"
if [[ -z "$OPERATOR_CIDR" ]]; then
  operator_ip="$(curl -s -4 --max-time 10 https://ifconfig.me || true)"
  [[ "$operator_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "Could not detect your public IP; set OPERATOR_CIDR=<ip>/32" >&2; exit 1; }
  OPERATOR_CIDR="$operator_ip/32"
fi
echo "==> Control plane will accept: $AEGIS_NETWORKS and $OPERATOR_CIDR"

args=(
  container clusters create "$CLUSTER"
  --project "$PROJECT"
  --zone "$ZONE"
  --release-channel regular
  --network "$NETWORK"
  --subnetwork "$SUBNET"
  --enable-ip-alias
  --cluster-secondary-range-name "$PODS_RANGE"
  --services-secondary-range-name "$SERVICES_RANGE"
  --enable-master-authorized-networks
  --master-authorized-networks "$AEGIS_NETWORKS,$OPERATOR_CIDR"
  --workload-pool "$PROJECT.svc.id.goog"
  --num-nodes "$NODE_COUNT"
  --machine-type "$MACHINE_TYPE"
  --image-type COS_CONTAINERD
  --disk-type pd-balanced
  --disk-size 100
  --scopes cloud-platform
)
[[ -n "${USE_SPOT:-}" ]] && args+=(--spot)
[[ -n "${NODE_SERVICE_ACCOUNT:-}" ]] && args+=(--service-account "$NODE_SERVICE_ACCOUNT")

if [[ -n "${DRY_RUN:-}" ]]; then
  printf 'gcloud'; printf ' %q' "${args[@]}"; printf '\n'
  exit 0
fi

echo "==> Creating $CLUSTER ($NODE_COUNT x $MACHINE_TYPE in $ZONE)"
gcloud "${args[@]}"

echo "==> Fetching cluster credentials"
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"

echo
echo "Private control-plane endpoint (used by onboard-demo-cluster.sh):"
gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" \
  --format='value(privateClusterConfig.privateEndpoint)'
echo
echo "Next:"
echo "  1. Someone with roles/container.admin applies gke-deploy/aegis-rbac.yaml"
echo "  2. AEGIS_API_KEY=<tenant key> ./gke-deploy/deploy-gke.sh"
