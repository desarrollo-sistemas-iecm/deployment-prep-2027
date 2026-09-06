# Preparación para Azure App Service (sin recursos todavía)

No se creó ningún recurso de Azure ni se solicitaron credenciales. Esta
imagen ya cumple los requisitos genéricos para correr en App Service para
contenedores Linux:

- `linux/amd64` explícito.
- Puerto configurable vía `PORT` (default `3000`), escucha en `0.0.0.0`.
- Logs por `stdout`/`stderr` (Nest Logger por defecto, sin transporte a
  archivo).
- Arranca sin privilegios (`USER node`).
- Toda la configuración vía variables de entorno (Joi valida al arrancar).
- Datos fuera de la imagen (`/app/data`, `/app/logs`).
- `HEALTHCHECK` sin dependencias externas (usa `fetch` nativo de Node).
- Cierre ordenado (`SIGTERM` → `app.enableShutdownHooks()`).
- No depende de Apache dentro del contenedor.
- No asume una URL/dominio fijo (`CORS_ORIGINS` es configurable).

## Lo que falta cuando existan recursos de Azure

1. **Azure Container Registry (ACR)** — destino del `docker push`. Hoy la
   imagen solo se prueba local (`docker buildx --load`) y se empaqueta como
   `.tar` para difusores externos.
2. **Identidad administrada** para que App Service extraiga la imagen de ACR
   sin credenciales estáticas.
3. **OpenID Connect (OIDC) entre GitHub Actions y Azure** — el job
   `publish-to-acr` en `.github/workflows/build-and-package.yml` está
   deshabilitado (`if: false`) exactamente a la espera de esto; no se generó
   ningún secreto de Azure.
4. **App Service para contenedor Linux** apuntando a la imagen en ACR por
   **digest** (no por tag mutable), con `WEBSITES_PORT=3000`.
5. **Variables de configuración** (App Settings) — mapear 1:1 las variables
   ya validadas por `src/config/env.validation.ts`
   (`JWT_SECRET`, `CORTES_MANIFEST_HMAC_SECRET`, etc.) preferentemente desde
   **Azure Key Vault** referenciado desde App Settings, no como texto plano.
6. **Almacenamiento persistente** para `/app/data` — App Service para
   contenedores Linux soporta montar Azure Files; validar que
   `better-sqlite3`/`sqlite3` funcionen correctamente con locking sobre ese
   tipo de almacenamiento (SMB) antes de confiar en él para
   `database.db3`/`control.db3` — **este punto necesita una prueba
   específica que no se hizo aquí** (no hay recursos Azure disponibles).
7. **Slot de preproducción** (staging slot) para probar un corte/versión
   antes del swap a producción.
8. **Health check** de App Service apuntando a
   `GET /api/v1/health/ready` (no solo `/live`) para no enrutar tráfico a una
   instancia sin corte activo tras un deploy.
9. **Promoción por digest** — el pipeline debería fijar el digest exacto
   probado (no un tag como `latest`) al promover a producción, coherente con
   `manifest-release.json`/`imageDigest` ya generado por
   `package-release.sh`.
10. **Rollback** — App Service permite reapuntar el slot a un digest
    anterior sin rebuild; los datos en Azure Files no se ven afectados por
    ese rollback, igual que en `scripts/rollback-release.sh` para difusores
    externos.
11. **Pruebas específicas de SQLite sobre almacenamiento de Azure** —
    concurrencia, locking, latencia de `fs.renameSync` (la activación
    atómica asume que `data/staging`, `data/database.db3` y `data/archive`
    están en el **mismo filesystem**; si Azure Files monta con
    comportamiento distinto al POSIX local, esto debe validarse antes de
    operar el PREP interno sobre App Service).

Ninguno de estos puntos se implementó ni se simuló — quedan explícitamente
pendientes por no existir recursos de Azure en esta fase.
