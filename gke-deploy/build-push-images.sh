#!/usr/bin/env bash
# build-push-images.sh — build services from this repo's source and push them
# to a registry the GKE cluster can pull from.
#
# Usage:
#   IMAGE_REPO=us-central1-docker.pkg.dev/<project>/<repository>/demo \
#   IMAGE_TAG=$(git rev-parse --short HEAD) \
#     ./gke-deploy/build-push-images.sh [service ...]
#
# With no services it builds the list in source-services.txt, which is what
# deploy-gke.sh deploys by default. Images are pushed as
# <IMAGE_REPO>:<IMAGE_TAG>-<service>; deploy them with the same IMAGE_REPO and
# IMAGE_TAG.
# The registry repository must already exist and docker must be authenticated:
#   gcloud auth configure-docker us-central1-docker.pkg.dev
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${IMAGE_REPO:?Set IMAGE_REPO, e.g. us-central1-docker.pkg.dev/<project>/<repository>/demo}"
: "${IMAGE_TAG:?Set IMAGE_TAG, e.g. \$(git rev-parse --short HEAD)}"

if [[ $# -eq 0 ]]; then
  set -- $(cat "$SCRIPT_DIR/source-services.txt")
fi

cd "$REPO_ROOT"

# GKE nodes are amd64; force it when building on Apple Silicon.
export DOCKER_DEFAULT_PLATFORM=linux/amd64

IMAGE_NAME="$IMAGE_REPO" DEMO_VERSION="$IMAGE_TAG" \
  docker compose --env-file .env \
    -f compose.yaml -f compose.full.yaml -f compose.observability.yaml \
    -f compose.extras.yaml -f compose.agent.yaml \
    build --push "$@"
