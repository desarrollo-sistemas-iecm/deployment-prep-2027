#!/usr/bin/env bash
# Instala un release ya empaquetado en un servidor de difusor externo:
# docker load + tag estable + arranque vía compose.external.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."

TAR_FILE="${1:?uso: install-release.sh <archivo.tar> [tag-destino]}"
IMAGE_TAG="${2:-prep-2027:installed}"

echo "Verificando SHA256SUMS si está presente junto al .tar..."
TAR_DIR="$(cd "$(dirname "$TAR_FILE")" && pwd)"
if [ -f "${TAR_DIR}/SHA256SUMS" ]; then
  (cd "$TAR_DIR" && shasum -a 256 -c SHA256SUMS) || {
    echo "El checksum del .tar no coincide con SHA256SUMS. Abortando." >&2
    exit 1
  }
else
  echo "Aviso: no se encontró SHA256SUMS junto al .tar; se omite verificación de integridad." >&2
fi

echo "Cargando ${TAR_FILE}..."
LOAD_OUTPUT="$(docker load --input "$TAR_FILE")"
echo "$LOAD_OUTPUT"

LOADED_REF="$(echo "$LOAD_OUTPUT" | sed -n 's/^Loaded image: //p' | tail -1)"
if [ -z "$LOADED_REF" ]; then
  echo "No se pudo determinar la referencia de la imagen cargada." >&2
  exit 1
fi

docker tag "$LOADED_REF" "$IMAGE_TAG"
echo ""
echo "Imagen disponible como: ${IMAGE_TAG} (referencia original: ${LOADED_REF})"
echo "Siguiente paso:"
echo "  PREP_IMAGE=${IMAGE_TAG} docker compose --env-file .env -f compose.external.yaml up -d"
