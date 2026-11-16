#!/usr/bin/env bash
# build-push-images.sh — build services from this repo's source and push them
# to a registry the GKE cluster can pull from.
#
# Usage:
#   IMAGE_REPO=us-central1-docker.pkg.dev/<project>/<repository>/demo \
#   IMAGE_TAG=$(git rev-parse --short HEAD) \
#     ./gke-deploy/build-push-images.sh frontend [service ...]
#
# Images are pushed as <IMAGE_REPO>:<IMAGE_TAG>-<service>. Deploy them with the
# same IMAGE_REPO / IMAGE_TAG and SOURCE_SERVICES="<service> ..." (deploy-gke.sh).
# The registry repository must already exist and docker must be authenticated:
#   gcloud auth configure-docker us-central1-docker.pkg.dev
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${IMAGE_REPO:?Set IMAGE_REPO, e.g. us-central1-docker.pkg.dev/<project>/<repository>/demo}"
: "${IMAGE_TAG:?Set IMAGE_TAG, e.g. \$(git rev-parse --short HEAD)}"
[[ $# -gt 0 ]] || { echo "usage: $0 <service> [service ...]" >&2; exit 1; }

cd "$REPO_ROOT"

# GKE nodes are amd64; force it when building on Apple Silicon.
export DOCKER_DEFAULT_PLATFORM=linux/amd64

IMAGE_NAME="$IMAGE_REPO" DEMO_VERSION="$IMAGE_TAG" \
  docker compose --env-file .env build --push "$@"
