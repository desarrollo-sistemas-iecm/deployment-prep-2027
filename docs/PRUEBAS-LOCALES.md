# Pruebas locales ejecutadas

Todo lo listado aquí se ejecutó de verdad en este entorno (evidencia real,
comandos y resultados reales) salvo lo marcado explícitamente como no
ejecutable (Azure, Apache real).

## Entorno de prueba

- macOS, Apple Silicon (arm64) — build de `linux/amd64` vía Docker Desktop
  Buildx (emulación transparente; `docker buildx ls` confirma soporte para
  `linux/amd64`).
- Docker 29.6.1, Buildx 0.35.0.
- Node v24.15.0, npm 11.12.1, pnpm 11.17.0.

## 1–3. Lint, tests y build de cada proyecto (fuera de Docker)

```bash
cd services-prep-2027 && pnpm run lint && pnpm run test && pnpm run build
```
- lint: sin errores (prettier auto-fix vía hook del repo).
- test: **7 suites, 29 tests — todos OK** (incluye los specs nuevos de
  `activation.service.spec.ts` y las ampliaciones de `health.service.spec.ts`).
  Se observó un test preexistente (`health.service.spec.ts`, caso
  "should not hang and report timeout...") intermitentemente flaky bajo carga
  del sistema (usa un timeout real de 3s en carrera con `setImmediate`) — pasa
  8/8 en aislamiento (`pnpm run test -- health.service.spec.ts`) y no fue
  modificado por este trabajo; se documenta como flakiness preexistente, no
  una regresión introducida aquí.
- build: `nest build` sin errores.

```bash
cd publicador-prep-2027 && npm run build:prod
grep -o 'api_prep:"[^"]*"' dist/publicador-prep-2027/main*.js
grep -o 'useMockApi:!\?[01]' dist/publicador-prep-2027/main*.js
npx ng test --browsers=ChromeHeadless --watch=false
```
- Build exitoso (solo warnings de budget preexistentes, no relacionados).
- `api_prep:"/api"` confirmado en el bundle real.
- `useMockApi:!0` (`true`) confirmado — **a propósito**, ver
  `IMPLEMENTACION-DOCKER.md` (el backend aún no implementa `/avance`,
  `/grafica`, etc.).
- Tests: **TOTAL: 17 SUCCESS** (Chrome Headless).

## 4. Build Docker multietapa (`linux/amd64`)

```bash
cd deployment-prep-2027
export GIT_COMMIT_BACKEND=a7e9fdc GIT_COMMIT_FRONTEND=d1649f4 APP_VERSION=0.0.1-local
./scripts/build-local.sh
```

**No pasó a la primera.** Se documenta la secuencia real de fallos y fixes
porque cada uno es una decisión técnica real, no solo ruido:

1. **Timeout/memoria del harness** en el primer intento (corrido en
   background junto a otras tool calls) — reintentado en foreground.
2. **Red lenta bajo emulación QEMU**: `pnpm install`/`npm ci` tardaban
   10–160s por paquete y terminaban en `ECONNRESET` tras ~10 minutos. Fix:
   cache mounts de BuildKit (`--mount=type=cache`) para el store de
   npm/pnpm, `--network-concurrency=4`, más reintentos/timeouts.
3. **`[ERR_PNPM_IGNORED_BUILDS]`**: pnpm ≥10 no ejecuta scripts de instalación
   de dependencias nativas por defecto. Verificado localmente (fuera de
   Docker) que la config correcta vive en **`pnpm-workspace.yaml`** con
   **ambas** claves `onlyBuiltDependencies` + `allowBuilds` (ni `.npmrc` ni
   `package.json["pnpm"]` funcionan en pnpm 11 — este último ni siquiera se
   lee, según el propio warning de pnpm). Lista final:
   `better-sqlite3`, `sqlite3`, `@scarf/scarf`, `@parcel/watcher`,
   `unrs-resolver` (los dos últimos, transitivos de eslint/jest, solo hacen
   falta en la etapa `backend-build`, no en `runtime` que instala `--prod`).
4. **`GLIBC_2.38' not found`** al correr los tests dentro del build: el
   binario prebuilt de `sqlite3@6.0.1` requiere una glibc más nueva que la de
   Debian 12 "bookworm" (2.36). Fix: cambiar las 3 etapas a
   `node:24.15.0-trixie-slim` (Debian 13, glibc 2.41 — confirmado con
   `ldd --version` dentro de la imagen).

Con esos 4 fixes, el build terminó exitosamente:
```
Test Suites: 7 passed, 7 total
Tests:       29 passed, 29 total
...
naming to docker.io/library/prep-2027:local done
Listo: prep-2027:local
```
`docker image inspect prep-2027:local --format '{{.Os}}/{{.Architecture}}'`
→ `linux/amd64`. Tamaño: **246MB**.

## 5. Arranque vía Compose + smoke test

```bash
cp .env.example .env
./scripts/start-local.sh
./scripts/smoke-test.sh
```

**Primer arranque real, crash inmediato**: `Cannot find module 'multer'`.
Bug preexistente real en `services-prep-2027`: `cortes.controller.ts` importa
`multer` directamente (`import { diskStorage } from 'multer'`) pero el
paquete nunca se declaró en `dependencies` (solo `@types/multer` como
devDependency) — solo "funcionaba" en desarrollo porque `multer` llega como
transitiva de `@nestjs/platform-express` y la instalación local no es tan
estricta como la de un contenedor limpio. **Fix**: se agregó
`"multer": "^2.2.0"` a `dependencies` en `services-prep-2027/package.json`
(la versión ya estaba resuelta en el lockfile, `pnpm install` solo promovió
la entrada, sin re-resolver nada más).

**Segundo arranque, nuevo crash**: `SqliteError: unable to open database
file` en el DataSource `resultados` (`readonly: true`, y better-sqlite3 no
puede crear un archivo en modo readonly). Esto es exactamente el escenario
que pide la tarea ("el contenedor debe iniciar aunque no exista SQLite") y
no estaba resuelto. **Fix**: `ensureResultadosDatabaseExists()` en
`main.ts`, que crea un archivo SQLite vacío válido (verificado con
`better-sqlite3` localmente: abrir en modo escritura, cerrar, reabrir en
`readonly` — funciona) antes de que `NestFactory.create()` disparé la
conexión. Además, `control.db3` tenía `migrationsRun: false`, así que sobre
un volumen nuevo las tablas `corte_releases`/`bitacora` no existirían nunca
— se cambió a `migrationsRun: true` (solo para `control`, dataset interno de
la app; `resultados` sigue sin migraciones, es un dataset externo).

**Tercer arranque, exitoso**:
```
[Nest] LOG [NestApplication] Nest application successfully started
```
`docker ps` → `Up 6 seconds (healthy)`.

```
./scripts/smoke-test.sh
OK   [200] index.html del frontend
OK   [200] health/live
OK   [200] health/ready
OK   [200] version
OK   [200] swagger docs
Resultado: 5 OK, 0 FAIL
```

**Bug adicional encontrado y corregido**: `compose.local.yaml` redeclaraba
`APP_VERSION`/`GIT_COMMIT_BACKEND`/`GIT_COMMIT_FRONTEND`/`BUILD_DATE` en
`environment:`, lo que sobreescribía en runtime los valores ya horneados en
la imagen (Dockerfile `ENV`) con los defaults de `.env` (`unknown`). Se
quitaron esas líneas de `environment:` — esos valores solo deben fijarse una
vez, en el build. Verificado:
```
GET /api/v1/version
{"appVersion":"0.0.1-local","gitCommitBackend":"a7e9fdc",
 "gitCommitFrontend":"d1649f4","buildDate":"2026-09-06T02:13:30Z",
 "imageDigest":"unknown"}
```

## 6. Corte de prueba (caso feliz, activación inmediata)

```bash
./scripts/create-test-cut.sh /tmp/corte-1.db3
./scripts/send-test-cut.sh --file /tmp/corte-1.db3 --cut-id corte-demo-1 --version 1.0
```
Resultado real:
```
<- 202 Accepted  {"status":"uploaded"}
estado[1/20]: activated
{"cutId":"corte-demo-1","version":"1.0","status":"activated","failureReason":null}
```
`GET /cortes/activo` → refleja `corte-demo-1`. `GET /health/ready` →
`{"status":"ready","cutId":"corte-demo-1","version":"1.0","activatedAt":"..."}`.
En disco (`docker exec ... ls /app/data`): `database.db3` reemplazado,
`data/archive/` con el placeholder anterior archivado, `data/staging/`
vacío (limpiado tras activar).

## 7. Casos negativos

| Escenario | Comando | Resultado real |
|---|---|---|
| Token inválido | `--invalid-token` | `401` `"Token inválido o expirado"` |
| Hash incorrecto | `--bad-hash` | `422` `"El sha256 del manifest no coincide con el archivo recibido"` |
| Firma inválida | `--bad-signature` | `401` `"La firma del manifest no es válida"` |
| SQLite corrupta | `--corrupt-db` | `202` al subir, luego `status:"failed"`, `failureReason:"PRAGMA integrity_check falló"` |
| Idempotencia (mismo cutId + mismo archivo) | reenvío exacto | `200` `"El corte ya había sido recibido"` |
| **Nota**: mismo cutId + archivo "distinto" generado con `create-test-cut.sh` dos veces → **mismo hash** (esquema determinista, sin datos) → correctamente tratado como idempotente (200), no como conflicto. Se corrigió la prueba insertando filas distintas con `sqlite3` en cada archivo para obtener hashes distintos de verdad. |
| Conflicto real (mismo cutId, archivos con hash distinto) | `corte-a.db3` vs `corte-b.db3` | `409` `"El cutId corte-conflicto ya existe con un archivo distinto"` |
| Versión anterior a la activa | `--version 0.5` contra una activa en `1.0` | `202` al subir, luego `status:"failed"`, `failureReason:"La versión 0.5 no es posterior a la versión activa 1.0"` |

Nota operativa real encontrada: `CORTES_UPLOAD_RATE_LIMIT=5`/60s se agotó a
mitad de esta batería de pruebas (`429 Too Many Requests`) — confirma que el
rate limiting funciona; hubo que espaciar los envíos.

## 8. Activación programada (futuro)

```bash
./scripts/send-test-cut.sh --file /tmp/corte-c.db3 --cut-id corte-programado --version 3.0 --activation-at +25s --no-poll
curl .../corte-programado/estado   # -> "validated" (confirmado, aún no activo)
sleep 25
curl .../corte-programado/estado   # -> "activated" (confirmado)
```

## 9. Persistencia y recuperación tras reinicio

```bash
docker compose -f compose.local.yaml restart
```
`docker ps` → `Up 8 seconds (healthy)`. `GET /cortes/activo` y
`GET /health/ready` siguen reflejando `corte-programado` v3.0 tras el
reinicio — persistencia confirmada sobre el volumen nombrado
`deployment-prep-2027_prep-data`. (La recuperación de una activación
*pendiente* tras reinicio, caso más estricto, está cubierta por el test
unitario `activation.service.spec.ts` — "should activate immediately, on
module init...".)

## 10. `docker save` / `docker load`

```bash
RELEASE_SIGNING_SECRET=... ./scripts/package-release.sh
./scripts/install-release.sh release/.../prep-2027_0.0.1-local_linux-amd64.tar prep-2027:installed
```
- `package-release.sh` generó el `.tar` (246MB), `SHA256SUMS`,
  `manifest-release.json` y `manifest-release.sig`. Firma verificada
  manualmente con HMAC-SHA256 y `RELEASE_SIGNING_SECRET` → **"firma OK"**.
- `install-release.sh` verificó `SHA256SUMS` (`OK`) antes de `docker load`,
  cargó la imagen y la re-etiquetó como `prep-2027:installed`.
- Arrancada vía `compose.external.yaml` en el puerto 3001 (bind mounts en
  `/tmp/prep-external-*`): `smoke-test.sh` → **5 OK, 0 FAIL**.
- `docker exec prep-2027 id` → `uid=1000(node) gid=1000(node)` — confirmado
  no-root.

**Gotcha operativo real encontrado y documentado**: correr
`compose.local.yaml` y `compose.external.yaml` desde el mismo directorio
sin `-p <nombre>` hace que Docker Compose derive el mismo nombre de
proyecto para ambos y "recree" el contenedor del otro stack (pasó en esta
prueba: el contenedor local fue reemplazado momentáneamente). Los datos en
el volumen nombrado no se perdieron (no se usó `down -v`), pero el
contenedor sí. En operación real esto no aplica (el difusor externo nunca
corre `compose.local.yaml` en el mismo host), pero para probar ambos stacks
en la misma máquina de desarrollo hay que usar `docker compose -p <nombre>`.

## 11. Rollback de imagen

```bash
docker tag prep-2027:local prep-2027:0.0.1-anterior
docker compose -p prep-external --env-file ... -f compose.external.yaml down
PREP_IMAGE=prep-2027:0.0.1-anterior docker compose -p prep-external ... up -d
```
`smoke-test.sh` contra el puerto 3001 tras el "rollback" → **5 OK, 0 FAIL**.
El bind mount de datos no se tocó en ningún momento del cambio de imagen.

## 12. Validación de sintaxis (sin ejecución real)

```bash
docker compose -f compose.local.yaml --env-file .env config    # OK (probado con secretos de prueba)
docker compose -f compose.external.yaml --env-file .env config # OK (probado con secretos de prueba)
ruby -ryaml -e "YAML.load_file('.github/workflows/build-and-package.yml')"  # OK
```
- `apache/prep.conf.example`: no se validó con `apachectl -t` real (no hay
  Apache instalado en este entorno) — revisión manual contra sintaxis
  Apache 2.4 estándar únicamente.
- El workflow de GitHub Actions se validó solo como YAML sintácticamente
  válido (Ruby), no con `actionlint` (no instalado) ni ejecución real en un
  runner (no hay repositorio git donde alojarlo en este entorno).
