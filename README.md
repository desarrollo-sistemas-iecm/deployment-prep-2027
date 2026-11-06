# deployment-prep-2027

Empaquetado y operación en Docker de **PREP 2027** (IECM): una sola imagen que
combina el backend `services-prep-2027` (NestJS) y el frontend
`publicador-prep-2027` (Angular). Esta carpeta no contiene código de
aplicación — solo el Dockerfile, los scripts y la documentación para
construir, correr, empaquetar y operar esa imagen.

## Requisitos

- Docker Engine + Docker Compose plugin (con soporte `buildx` para
  `linux/amd64`, incluso en Apple Silicon vía emulación QEMU).
- Los repos hermanos `../services-prep-2027` y `../publicador-prep-2027`
  presentes junto a esta carpeta (el build usa `PREP/` como contexto).
- `sqlite3` CLI en PATH, solo para `scripts/create-test-cut.sh`.

## Uso rápido (local)

```bash
cp .env.example .env               # editar JWT_SECRET / CORTES_MANIFEST_HMAC_SECRET
./scripts/build-local.sh           # docker buildx build --platform linux/amd64
./scripts/start-local.sh           # docker compose up -d --build
./scripts/smoke-test.sh            # curl a /, /health/live, /health/ready, /version, /docs
./scripts/stop-local.sh
```

## Simular un corte (subida de resultados)

```bash
./scripts/create-test-cut.sh /tmp/corte.db3
export $(grep -v '^#' .env | xargs)
./scripts/send-test-cut.sh --file /tmp/corte.db3 --cut-id corte-demo-1 --version 1.0
```

## Empaquetar y operar en un servidor de difusor externo

```bash
RELEASE_SIGNING_SECRET=otro-secreto-de-prueba ./scripts/package-release.sh
# genera release/prep-2027_<version>_linux-amd64/
```

Instalación, rollback y verificación de integridad en el servidor destino:
ver [`docs/OPERACION-DIFUSOR-EXTERNO.md`](docs/OPERACION-DIFUSOR-EXTERNO.md).

## Estructura

```
Dockerfile                    # imagen única, 3 etapas (frontend, backend, runtime)
compose.local.yaml            # build + ejecución local
compose.external.yaml         # ejecución de una imagen ya empaquetada (difusor externo)
apache/prep.conf.example      # proxy inverso opcional (TLS)
nginx/prep.conf.example       # proxy inverso Nginx (TLS, límite de subida para cortes)
scripts/                      # build, start/stop, empaquetado, instalación, rollback, smoke test
docs/                         # documentación detallada (ver abajo)
runtime/                      # placeholders de datos/logs/keys/releases (gitignored salvo .gitkeep)
release/                      # salida de package-release.sh (gitignored)
.github/workflows/release.yml  # CI/CD: build, smoke test, GHCR, App Service y RHEL
```

## Documentación

- [`docs/IMPLEMENTACION-DOCKER.md`](docs/IMPLEMENTACION-DOCKER.md) — arquitectura de la imagen, decisiones
  técnicas tomadas y cómo activar el workflow de CI.
- [`docs/API-CORTES-SQLITE.md`](docs/API-CORTES-SQLITE.md) — contrato real de `POST /api/v1/cortes`
  (autenticación, firma HMAC del manifest, validación y activación).
- [`docs/OPERACION-DIFUSOR-EXTERNO.md`](docs/OPERACION-DIFUSOR-EXTERNO.md) — instalación, rollback y
  verificación en un servidor de difusor externo.
- [`docs/CI-CD.md`](docs/CI-CD.md) — pipeline de GitHub Actions (GHCR, App Service, runners RHEL) y su configuración.
- [`docs/GITHUB-APP-CI.md`](docs/GITHUB-APP-CI.md) — creación y mantenimiento de la GitHub App que usa el pipeline.
- [`docs/PRODUCCION-CHECKLIST.md`](docs/PRODUCCION-CHECKLIST.md) — checklist completo para recibir y poner en marcha
  los ambientes de producción (solicitudes a Infraestructura, configuración, validación, lecciones de dev).
- [`docs/AZURE-READINESS.md`](docs/AZURE-READINESS.md) — qué ya cumple la imagen para Azure App Service y qué
  falta cuando existan recursos de Azure.
- [`docs/PRUEBAS-LOCALES.md`](docs/PRUEBAS-LOCALES.md) — evidencia real de las pruebas ejecutadas (build,
  arranque, cortes, rollback, persistencia).

## Limitaciones conocidas

- El endpoint de cortes asume una sola instancia del contenedor (SQLite de un solo escritor) — no apto para
  escalado horizontal sin rediseñar la persistencia. En App Service: 1 instancia, sin autoescalado.
- SQLite sobre `/home` de App Service (SMB) validado con cortes reales en dev; falta la prueba de reinicio
  con corte activo (ver `docs/PRODUCCION-CHECKLIST.md` §7).

Para las convenciones de trabajo con Claude Code en este repositorio, ver [`CLAUDE.md`](CLAUDE.md).
