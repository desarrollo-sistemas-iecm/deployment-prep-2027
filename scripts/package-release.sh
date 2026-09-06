#!/usr/bin/env bash
# Empaqueta la imagen ya construida (build-local.sh) para entrega a un
# difusor externo: docker save + SHA256SUMS + manifiesto de release firmado.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE_TAG="${IMAGE_TAG:-prep-2027:local}"
APP_VERSION="${APP_VERSION:-0.0.1-local}"
RELEASE_SIGNING_SECRET="${RELEASE_SIGNING_SECRET:?define RELEASE_SIGNING_SECRET (secreto de PRUEBA para firmar el manifiesto de release; distinto de CORTES_MANIFEST_HMAC_SECRET)}"

RELEASE_NAME="prep-2027_${APP_VERSION}_linux-amd64"
RELEASE_DIR="release/${RELEASE_NAME}"

if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "No existe la imagen ${IMAGE_TAG}; corre scripts/build-local.sh primero." >&2
  exit 1
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR/apache" "$RELEASE_DIR/scripts" "$RELEASE_DIR/docs"

echo "Exportando imagen con docker save (puede tardar varios minutos)..."
docker save "$IMAGE_TAG" -o "${RELEASE_DIR}/${RELEASE_NAME}.tar"

IMAGE_ID="$(docker image inspect "$IMAGE_TAG" --format '{{.Id}}')"
IMAGE_DIGEST="$(docker image inspect "$IMAGE_TAG" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo 'sin-push-no-hay-digest')"
TAR_SHA256="$(shasum -a 256 "${RELEASE_DIR}/${RELEASE_NAME}.tar" | awk '{print $1}')"
echo "${TAR_SHA256}  ${RELEASE_NAME}.tar" > "${RELEASE_DIR}/SHA256SUMS"

cp compose.external.yaml .env.example "$RELEASE_DIR"/
cp apache/prep.conf.example "$RELEASE_DIR/apache/"
cp scripts/install-release.sh scripts/rollback-release.sh scripts/smoke-test.sh "$RELEASE_DIR/scripts/"
cp docs/OPERACION-DIFUSOR-EXTERNO.md "$RELEASE_DIR/docs/" 2>/dev/null || true

NODE_VERSION_LOCAL="$(node --version)"
GIT_COMMIT_BACKEND="${GIT_COMMIT_BACKEND:-$(git -C ../services-prep-2027 rev-parse --short HEAD 2>/dev/null || echo unknown)}"
GIT_COMMIT_FRONTEND="${GIT_COMMIT_FRONTEND:-$(git -C ../publicador-prep-2027 rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

cat > "${RELEASE_DIR}/manifest-release.json" <<JSON
{
  "releaseName": "${RELEASE_NAME}",
  "appVersion": "${APP_VERSION}",
  "imageTag": "${IMAGE_TAG}",
  "imageId": "${IMAGE_ID}",
  "imageDigest": "${IMAGE_DIGEST}",
  "tarFile": "${RELEASE_NAME}.tar",
  "tarSha256": "${TAR_SHA256}",
  "nodeVersion": "${NODE_VERSION_LOCAL}",
  "gitCommitBackend": "${GIT_COMMIT_BACKEND}",
  "gitCommitFrontend": "${GIT_COMMIT_FRONTEND}",
  "buildDate": "${BUILD_DATE}"
}
JSON

MANIFEST_SIGNATURE="$(node -e "
const crypto = require('crypto');
const fs = require('fs');
const manifest = fs.readFileSync(process.argv[1], 'utf-8');
process.stdout.write(crypto.createHmac('sha256', process.argv[2]).update(manifest).digest('hex'));
" "${RELEASE_DIR}/manifest-release.json" "$RELEASE_SIGNING_SECRET")"
echo "$MANIFEST_SIGNATURE" > "${RELEASE_DIR}/manifest-release.sig"

cat <<EOF

Release generado en: ${RELEASE_DIR}/
  - ${RELEASE_NAME}.tar   (docker save de ${IMAGE_TAG})
  - SHA256SUMS
  - manifest-release.json
  - manifest-release.sig  (HMAC-SHA256 de prueba con RELEASE_SIGNING_SECRET;
                            secreto DISTINTO de CORTES_MANIFEST_HMAC_SECRET)
  - compose.external.yaml, .env.example, apache/, scripts/, docs/

Instrucciones de instalación: ver docs/OPERACION-DIFUSOR-EXTERNO.md
EOF
