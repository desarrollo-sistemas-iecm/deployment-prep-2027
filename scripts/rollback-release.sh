#!/usr/bin/env bash
# Revierte solo la IMAGEN a una versión anterior ya cargada localmente — los
# datos en /app/data (bind mount / volumen) no se tocan, así que el corte
# activo sigue siendo el mismo tras el rollback.
set -euo pipefail
cd "$(dirname "$0")/.."

PREVIOUS_IMAGE="${1:?uso: rollback-release.sh <imagen:tag-anterior>}"

echo "Verificando que la imagen anterior exista localmente..."
docker image inspect "$PREVIOUS_IMAGE" >/dev/null

echo "Deteniendo el servicio actual (los volúmenes de datos no se eliminan)..."
PREP_IMAGE="$PREVIOUS_IMAGE" docker compose -f compose.external.yaml down

echo "Levantando con la imagen anterior: ${PREVIOUS_IMAGE}"
PREP_IMAGE="$PREVIOUS_IMAGE" docker compose --env-file .env -f compose.external.yaml up -d

docker compose -f compose.external.yaml ps
