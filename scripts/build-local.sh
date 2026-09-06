#!/usr/bin/env bash
# Construye la imagen local con buildx para linux/amd64, inyectando metadata
# de versión real (commits de ambos repos) como build args.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT_DIR="$(cd .. && pwd)"
IMAGE_TAG="${IMAGE_TAG:-prep-2027:local}"

APP_VERSION="${APP_VERSION:-0.0.1-local}"
GIT_COMMIT_BACKEND="$(git -C "$ROOT_DIR/services-prep-2027" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_COMMIT_FRONTEND="$(git -C "$ROOT_DIR/publicador-prep-2027" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Construyendo ${IMAGE_TAG} (linux/amd64)"
echo "  APP_VERSION=${APP_VERSION}"
echo "  GIT_COMMIT_BACKEND=${GIT_COMMIT_BACKEND}"
echo "  GIT_COMMIT_FRONTEND=${GIT_COMMIT_FRONTEND}"
echo "  BUILD_DATE=${BUILD_DATE}"

docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile \
  -t "${IMAGE_TAG}" \
  --build-arg APP_VERSION="${APP_VERSION}" \
  --build-arg GIT_COMMIT_BACKEND="${GIT_COMMIT_BACKEND}" \
  --build-arg GIT_COMMIT_FRONTEND="${GIT_COMMIT_FRONTEND}" \
  --build-arg BUILD_DATE="${BUILD_DATE}" \
  --load \
  "$ROOT_DIR"

echo "Listo: ${IMAGE_TAG}"
