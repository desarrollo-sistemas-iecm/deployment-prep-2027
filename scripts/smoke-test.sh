#!/usr/bin/env bash
# Smoke test HTTP básico contra una instancia ya corriendo (local o externa).
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:3000}"
API_PREFIX="${API_PREFIX:-api/v1}"

pass=0
fail=0
tmp_body="$(mktemp)"
trap 'rm -f "$tmp_body"' EXIT

check() {
  local desc="$1" method="$2" path="$3" expected="$4"
  local status
  status="$(curl -s -o "$tmp_body" -w '%{http_code}' -X "$method" "${BASE_URL}${path}")"
  if [ "$status" = "$expected" ]; then
    echo "OK   [$status] $desc"
    pass=$((pass + 1))
  else
    echo "FAIL [$status, esperado $expected] $desc"
    sed 's/^/       /' "$tmp_body"
    fail=$((fail + 1))
  fi
}

echo "Smoke test contra ${BASE_URL}"
echo "---"
check "index.html del frontend"    GET "/" 200
check "health/live"                GET "/${API_PREFIX}/health/live" 200
check "health/ready"                GET "/${API_PREFIX}/health/ready" 200
check "version"                     GET "/${API_PREFIX}/version" 200
check "swagger docs"                GET "/docs" 200
echo "---"
echo "Resultado: $pass OK, $fail FAIL"

[ "$fail" -eq 0 ]
