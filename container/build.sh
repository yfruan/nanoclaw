#!/bin/bash
# Build the NanoClaw agent container image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="nanoclaw-agent"
BASE_IMAGE_NAME="nanoclaw-base"
TAG="${1:-latest}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-container}"
NO_CACHE="${NO_CACHE:-false}"

# Build base image first
echo "Building base image..."
if [ "$NO_CACHE" = "true" ]; then
  ${CONTAINER_RUNTIME} build --no-cache -f Dockerfile.base -t "${BASE_IMAGE_NAME}:${TAG}" .
else
  ${CONTAINER_RUNTIME} build -f Dockerfile.base -t "${BASE_IMAGE_NAME}:${TAG}" .
fi

# Build main image
echo ""
echo "Building NanoClaw agent container image..."
echo "Image: ${IMAGE_NAME}:${TAG}"

${CONTAINER_RUNTIME} build -t "${IMAGE_NAME}:${TAG}" .

echo ""
echo "Build complete!"
echo "Base image: ${BASE_IMAGE_NAME}:${TAG}"
echo "Agent image: ${IMAGE_NAME}:${TAG}"
echo ""
echo "Test with:"
echo "  echo '{\"prompt\":\"What is 2+2?\",\"groupFolder\":\"test\",\"chatJid\":\"test@g.us\",\"isMain\":false}' | ${CONTAINER_RUNTIME} run -i ${IMAGE_NAME}:${TAG}"
