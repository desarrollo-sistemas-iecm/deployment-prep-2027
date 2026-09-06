#!/usr/bin/env bash
# Genera un archivo SQLite mínimo pero VÁLIDO (tablas vacías) que pasa la
# validación real de services-prep-2027 (PRAGMA integrity_check + presencia
# de las tablas listadas en RESULTADOS_LEGACY_TABLE_NAMES). No reproduce el
# esquema completo de columnas, solo lo que SqliteFileValidationService
# verifica hoy.
set -euo pipefail

OUTPUT="${1:-/tmp/prep-test-cut.db3}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Se requiere el CLI 'sqlite3' en PATH." >&2
  exit 1
fi

rm -f "$OUTPUT"

TABLES=(
  cain_cat_delegacion cain_cat_dist_dele cain_cat_distrito cat_tipo_casilla
  configura corte dig_actas_prep nourbanas prep_cat_inconsistencias
  prep_inconsistencias prep_votos scd_candidatos_jdel scd_candidatos_jgob
  scd_candidatos_mr scd_casillas scd_cat_participantes scd_cat_tipo_eleccion
  scd_participantes_jdel scd_participantes_jgob scd_participantes_mr
  scd_participantes_rp sedimde_enc_seguimiento
)

{
  for table in "${TABLES[@]}"; do
    echo "CREATE TABLE ${table} (id INTEGER PRIMARY KEY);"
  done
} | sqlite3 "$OUTPUT"

echo "Corte de prueba generado en: $OUTPUT"
sqlite3 "$OUTPUT" "PRAGMA integrity_check;"
