#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "Falta .env — copia .env.example y edita los secretos (JWT_SECRET, CORTES_MANIFEST_HMAC_SECRET)." >&2
  exit 1
fi

docker compose -f compose.local.yaml --env-file .env up -d --build
docker compose -f compose.local.yaml ps
