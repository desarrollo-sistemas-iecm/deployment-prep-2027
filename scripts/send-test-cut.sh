#!/usr/bin/env bash
# Wrapper delgado: delega toda la lógica a send-test-cut.mjs (Node, sin deps).
set -euo pipefail
cd "$(dirname "$0")"
exec node send-test-cut.mjs "$@"
