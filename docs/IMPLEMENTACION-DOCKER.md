# Implementación Docker — PREP 2027

## Arquitectura

Una sola imagen `linux/amd64` (3 etapas, ver `../Dockerfile`):

```
frontend-build (node:24.15.0-trixie-slim, npm ci)   -> dist/publicador-prep-2027/*  (Angular, plano)
backend-build  (node:24.15.0-trixie-slim, pnpm)     -> lint + test + nest build     -> dist/*.js
runtime        (node:24.15.0-trixie-slim, pnpm --prod)
  /app/dist    <- backend-build
  /app/public  <- frontend-build   (servido vía app.useStaticAssets, ya en bootstrap.config.ts)
  /app/node_modules <- solo dependencias de producción
  USER node (no root), HEALTHCHECK, EXPOSE 3000
```

Contexto de build: la raíz `PREP/` (el Dockerfile necesita ambos proyectos
hermanos). El ignore file es `Dockerfile.dockerignore` (convención de
BuildKit: `<Dockerfile>.dockerignore` junto al Dockerfile, no
`.dockerignore` en la raíz del contexto).

## Decisiones tomadas

1. **Contrato de cortes: HMAC-SHA256 real, no RSA-PSS.** `services-prep-2027`
   ya tenía `POST /api/v1/cortes` implementado y testeado con HMAC-SHA256
   (secreto compartido). Se decidió (confirmado con el usuario) mantenerlo
   así en vez de reescribir `manifest-verification.service.ts` a firma
   asimétrica — ver `API-CORTES-SQLITE.md`.
2. **Activación atómica: implementada desde cero.** Era un TODO explícito en
   el código (`cortes.service.ts`). Se agregó
   `src/modules/cortes/services/activation.service.ts`: swap atómico de
   `database.db3`, archivo de las últimas 2 versiones, rollback si falla la
   reapertura del DataSource, y recuperación de activaciones programadas
   pendientes al reiniciar (`onModuleInit`).
3. **Health/version.** Se agregaron `GET /api/v1/health/live`,
   `GET /api/v1/health/ready` (refleja `waiting_for_first_cut` o
   `ready` con el corte activo) y `GET /api/v1/version` (metadata de build,
   sin secretos). El `/health` original se conserva sin cambios.
4. **`app.listen(port, '0.0.0.0')` explícito + `app.enableShutdownHooks()`**
   en `main.ts` para cierre ordenado ante `SIGTERM`.
5. **Bug de frontend corregido al mínimo.** Los 13 archivos que importan
   `environment` en `publicador-prep-2027/src/app` apuntan siempre a
   `environment.development.ts` (nunca a `environment.ts`, pese a
   `fileReplacements` en `angular.json`) — por eso el build de "producción"
   servía datos mock igual que desarrollo. Se corrigió `api_prep` a `/api`
   (ruta relativa) en ese archivo. **`useMockApi` se dejó en `true` a
   propósito**: `services-prep-2027` hoy solo implementa `/cortes`,
   `/health` y `/version` — ninguno de los endpoints que la UI necesita
   (`/avance`, `/grafica`, `/combos/*`, `/estadistica`, `/mapas`,
   `/distribucion`, `/resumenvotacion`) existe todavía. Apagar el mock
   dejaría la interfaz en blanco. Corregir los 13 imports rotos (para que
   `fileReplacements` funcione de verdad) queda fuera de alcance de esta
   tarea.
6. **Node 24.15.0 sobre Debian slim** (no Alpine): `better-sqlite3` y
   `sqlite3` son módulos nativos; Debian evita problemas de compatibilidad
   con binarios prebuilt para glibc que sí aparecerían con musl (Alpine).
   Node 24 es la LTS activa en la fecha de esta implementación.
   **`trixie` (Debian 13, glibc 2.41), no `bookworm` (Debian 12, glibc
   2.36)**: se probó primero sobre bookworm y el binario prebuilt de
   `sqlite3@6.0.1` falló en runtime con `GLIBC_2.38' not found` — verificado
   con un build real, no una suposición.
7. **Tres bugs reales de `services-prep-2027` encontrados y corregidos
   durante las pruebas de arranque del contenedor** (no hipotéticos —
   el contenedor no arrancaba sin ellos):
   - `multer` se usa directamente en `cortes.controller.ts` pero nunca se
     declaró en `dependencies` (solo `@types/multer` como devDependency).
     "Funcionaba" en desarrollo por ser una transitiva de
     `@nestjs/platform-express`; una instalación estricta (pnpm en un
     contenedor limpio) no la expone. Se agregó `"multer": "^2.2.0"` a
     `dependencies` (versión ya resuelta en el lockfile).
   - El DataSource `resultados` es `readonly: true` y better-sqlite3 no
     puede crear un archivo en modo readonly — sin `DB_STORAGE` preexistente
     el contenedor no arrancaba nunca, justo el escenario que pide la
     sección 6.6/6.7 del pedido original. Se agregó
     `ensureResultadosDatabaseExists()` en `main.ts` (crea un archivo SQLite
     vacío válido con `better-sqlite3` antes de `NestFactory.create()`,
     comportamiento verificado localmente: abrir en escritura, cerrar,
     reabrir en readonly funciona).
   - `control.db3` tenía `migrationsRun: false`; sobre un volumen nuevo, las
     tablas `corte_releases`/`bitacora` nunca se crean. Se cambió a
     `migrationsRun: true` **solo** para el DataSource `control` (interno de
     esta app) — `resultados` sigue sin migraciones, sigue siendo un dataset
     externo.
8. **`compose.local.yaml` no debe redeclarar `APP_VERSION` /
   `GIT_COMMIT_BACKEND` / `GIT_COMMIT_FRONTEND` / `BUILD_DATE` en
   `environment:`** — esos valores ya quedan horneados en la imagen
   (Dockerfile `ENV`, desde los build args); redeclararlos los sobreescribe
   en runtime con lo que haya en `.env` (por defecto `unknown`), ocultando
   el valor real del build. Se encontró este bug probando `/api/v1/version`
   con un valor distinto al esperado, y se corrigió quitando esas líneas.
9. **`GET /health*` queda bajo `/api/v1/...`**, no en la raíz, porque
   `setGlobalPrefix('api/v1')` ya se aplicaba a ese controlador antes de este
   cambio — se documenta la ruta real en vez de crear una excepción al
   prefijo global.

## Build y ejecución local

```bash
cd deployment-prep-2027
cp .env.example .env               # editar JWT_SECRET / CORTES_MANIFEST_HMAC_SECRET
./scripts/build-local.sh           # docker buildx build --platform linux/amd64
./scripts/start-local.sh           # docker compose up -d --build
./scripts/smoke-test.sh            # curl a /, /health/live, /health/ready, /version, /docs
```

## Simular un corte

```bash
./scripts/create-test-cut.sh /tmp/corte.db3
# .env debe estar cargado en el shell, o pasa --hmac-secret/--jwt-secret:
export $(grep -v '^#' .env | xargs)
./scripts/send-test-cut.sh --file /tmp/corte.db3 --cut-id corte-demo-1 --version 1.0
```

## Empaquetar para un difusor externo

```bash
RELEASE_SIGNING_SECRET=otro-secreto-de-prueba ./scripts/package-release.sh
# genera release/prep-2027_<version>_linux-amd64/
```
Ver `OPERACION-DIFUSOR-EXTERNO.md` para instalación/rollback en el servidor
del difusor.

## Activar el workflow de GitHub Actions

`.github/workflows/build-and-package.yml` vive dentro de
`deployment-prep-2027/` porque ni esta carpeta ni `PREP/` son un repositorio
git propio. Para que corra de verdad:

1. Mover (o publicar como submódulo/subtree) `deployment-prep-2027/` a la
   raíz de un repositorio git real — o copiar `.github/workflows/` a la raíz
   de `services-prep-2027` o `publicador-prep-2027` si se prefiere que viva
   ahí, ajustando las rutas relativas del `Dockerfile`/contexto.
2. Completar los inputs `backend_repo`/`frontend_repo` al disparar el
   workflow manualmente (no se hardcodeó ningún nombre de organización).
3. Configurar `secrets.CHECKOUT_TOKEN` solo si los repos son privados y el
   token por defecto (`GITHUB_TOKEN`) no alcanza para checkout cruzado.
4. Configurar `secrets.RELEASE_SIGNING_SECRET` (secreto de prueba/test, no
   confundir con `CORTES_MANIFEST_HMAC_SECRET` de producción).
5. Los pasos de Trivy/SBOM están con `if: false` (marketplace actions que
   requieren habilitarse explícitamente) — quitar la condición cuando se
   revisen y aprueben esas actions para el repo.
6. El job `publish-to-acr` está con `if: false` y depende de un GitHub
   Environment `azure-production` con aprobación manual + OIDC — ver
   `AZURE-READINESS.md`.

## Limitaciones conocidas / pendientes reales

- El endpoint de subida de cortes asume **una sola instancia** del
  contenedor (SQLite es de un solo escritor; el lock de activación es en
  memoria). No apto para escalado horizontal sin rediseñar la persistencia.
- `useMockApi` sigue activo en el frontend (ver decisión 5) — la UI del
  publicador no refleja datos reales hasta que se implementen los endpoints
  de resultados en `services-prep-2027`.
- El workflow de GitHub Actions está sintácticamente validado (YAML) pero
  **no se ejecutó** en un runner real — no hay repositorio git donde
  alojarlo en este entorno.
- El escaneo de vulnerabilidades y el SBOM quedan como pasos deshabilitados
  (`if: false`) hasta aprobar esas Marketplace Actions.
- **Gotcha real de Compose**: correr `compose.local.yaml` y
  `compose.external.yaml` desde el mismo directorio sin `-p <nombre>`
  distinto hace que Docker Compose derive el mismo nombre de proyecto para
  ambos y "recree" el contenedor del otro stack al hacer `up`. En operación
  real no aplica (nunca conviven en el mismo host), pero para probar ambos
  en la misma máquina de desarrollo usar `docker compose -p <nombre>`.
