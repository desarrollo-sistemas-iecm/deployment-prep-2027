# syntax=docker/dockerfile:1
#
# Imagen única para PREP 2027: publicador-prep-2027 (Angular, compilado y
# servido como estático) + services-prep-2027 (NestJS, sirve la API bajo
# API_PREFIX y el frontend compilado desde /app/public).
#
# Contexto de build: la raíz `PREP/` (necesita ambos proyectos hermanos).
#   docker buildx build --platform linux/amd64 \
#     -f deployment-prep-2027/Dockerfile \
#     -t prep-2027:local \
#     --build-arg APP_VERSION=0.0.1 \
#     --build-arg GIT_COMMIT_BACKEND=$(git -C services-prep-2027 rev-parse --short HEAD) \
#     --build-arg GIT_COMMIT_FRONTEND=$(git -C publicador-prep-2027 rev-parse --short HEAD) \
#     --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
#     --load .
#
# Node 24 (LTS activa desde oct-2025) fijada a un patch explícito, sobre
# Debian slim (no Alpine/musl) porque el backend usa módulos nativos
# (better-sqlite3, sqlite3) — Debian evita problemas de compatibilidad ABI
# con binarios prebuilt para glibc.
#
# trixie (Debian 13, glibc 2.41), no bookworm (Debian 12, glibc 2.36): el
# binario prebuilt de sqlite3@6.0.1 requiere glibc >=2.38 en tiempo de
# ejecución ("GLIBC_2.38' not found") — verificado con un build real fallido
# sobre bookworm-slim antes de cambiar a trixie-slim.
ARG NODE_VERSION=24.15.0

# ---------------------------------------------------------------------------
# Etapa 1: build del frontend Angular (publicador-prep-2027)
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-trixie-slim AS frontend-build
WORKDIR /workspace/publicador-prep-2027

COPY publicador-prep-2027/package.json publicador-prep-2027/package-lock.json ./
# Cache de npm entre builds/reintentos + timeouts más laxos: bajo emulación
# QEMU (build en Apple Silicon para linux/amd64) cada conexión TLS es lenta y
# los defaults de npm cortan por timeout antes de terminar una instalación
# de ~250 paquetes.
RUN --mount=type=cache,target=/root/.npm \
    npm config set fetch-retries 5 \
    && npm config set fetch-retry-mintimeout 20000 \
    && npm config set fetch-retry-maxtimeout 120000 \
    && npm ci

COPY publicador-prep-2027/ ./
# Sin lint configurado en este proyecto (confirmado: no hay script `lint` ni
# target `lint` en angular.json) — se omite a propósito, no por descuido.
RUN npm run build:prod

# Salida real y plana de `ng build` con --output-path=dist/publicador-prep-2027
# (el builder `browser` de Angular 21 no genera subcarpeta `browser/`).

# ---------------------------------------------------------------------------
# Etapa 2: build del backend NestJS (services-prep-2027)
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-trixie-slim AS backend-build
WORKDIR /workspace/services-prep-2027
RUN corepack enable && corepack prepare pnpm@11.17.0 --activate

COPY services-prep-2027/package.json services-prep-2027/pnpm-lock.yaml ./
# pnpm >=10 no ejecuta scripts de instalación de dependencias por defecto
# (supply-chain hardening) — better-sqlite3/sqlite3 SÍ necesitan el suyo para
# obtener/compilar el binding nativo. Se aprueban explícitamente aquí (no en
# services-prep-2027/package.json, para no tocar ese repo) en vez de usar
# --dangerously-allow-all-builds, que aprobaría cualquier dependencia.
# La config vive en pnpm-workspace.yaml (no en .npmrc ni en package.json:
# "pnpm" — pnpm 11 ya no lee ese campo, ver "pnpm install" warning) y
# requiere AMBAS claves, onlyBuiltDependencies y allowBuilds (verificado
# localmente con pnpm 11.17.0; con una sola de las dos, sigue bloqueando).
# Lista completa verificada con `pnpm install --frozen-lockfile` (full,
# con devDependencies) contra el pnpm-lock.yaml real de este repo:
# better-sqlite3/sqlite3 (bindings nativos usados por la app), @scarf/scarf
# (telemetría inofensiva de varias libs), @parcel/watcher y unrs-resolver
# (nativos, transitivos de eslint/jest — solo hacen falta en esta etapa,
# no en runtime que instala --prod).
RUN printf 'onlyBuiltDependencies:\n  - better-sqlite3\n  - sqlite3\n  - "@scarf/scarf"\n  - "@parcel/watcher"\n  - unrs-resolver\nallowBuilds:\n  better-sqlite3: true\n  sqlite3: true\n  "@scarf/scarf": true\n  "@parcel/watcher": true\n  unrs-resolver: true\n' > pnpm-workspace.yaml
# Mismo ajuste que en frontend-build: cache de store entre reintentos +
# concurrencia de red baja + timeouts laxos para tolerar la emulación QEMU.
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile \
      --network-concurrency=4 \
      --fetch-retries=5 \
      --fetch-retry-mintimeout=20000 \
      --fetch-retry-maxtimeout=120000 \
      --fetch-timeout=120000

COPY services-prep-2027/ ./
RUN pnpm run lint && pnpm run test && pnpm run build

# ---------------------------------------------------------------------------
# Etapa 3: runtime — solo dependencias de producción + artefactos compilados
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-trixie-slim AS runtime
RUN corepack enable && corepack prepare pnpm@11.17.0 --activate

ARG APP_VERSION=unknown
ARG GIT_COMMIT_BACKEND=unknown
ARG GIT_COMMIT_FRONTEND=unknown
ARG BUILD_DATE=unknown
ARG IMAGE_DIGEST=unknown

LABEL org.opencontainers.image.title="prep-2027" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_COMMIT_BACKEND}" \
      org.opencontainers.image.source="services-prep-2027,publicador-prep-2027" \
      io.iecm.prep.git-commit-backend="${GIT_COMMIT_BACKEND}" \
      io.iecm.prep.git-commit-frontend="${GIT_COMMIT_FRONTEND}"

ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=${APP_VERSION} \
    GIT_COMMIT_BACKEND=${GIT_COMMIT_BACKEND} \
    GIT_COMMIT_FRONTEND=${GIT_COMMIT_FRONTEND} \
    BUILD_DATE=${BUILD_DATE} \
    IMAGE_DIGEST=${IMAGE_DIGEST}

WORKDIR /app

COPY services-prep-2027/package.json services-prep-2027/pnpm-lock.yaml ./
RUN printf 'onlyBuiltDependencies:\n  - better-sqlite3\n  - sqlite3\n  - "@scarf/scarf"\nallowBuilds:\n  better-sqlite3: true\n  sqlite3: true\n  "@scarf/scarf": true\n' > pnpm-workspace.yaml
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --prod --frozen-lockfile \
      --network-concurrency=4 \
      --fetch-retries=5 \
      --fetch-retry-mintimeout=20000 \
      --fetch-retry-maxtimeout=120000 \
      --fetch-timeout=120000

COPY --from=backend-build /workspace/services-prep-2027/dist ./dist
COPY --from=frontend-build /workspace/publicador-prep-2027/dist/publicador-prep-2027 ./public

# /app/data, /app/logs y /app/data/staging son los únicos directorios en los
# que la aplicación escribe en runtime (multer, SQLite de control/resultados,
# archivo de cortes anteriores) — se montan como volúmenes en compose.
RUN mkdir -p /app/data/staging /app/data/archive /app/logs \
    && chown -R node:node /app

USER node
EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 3000) + '/' + (process.env.API_PREFIX || 'api/v1') + '/health/live').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "dist/main.js"]
