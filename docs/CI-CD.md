# CI/CD — PREP 2027 (ambiente dev, operado como producción)

Workflow: [`.github/workflows/release.yml`](../.github/workflows/release.yml).

```
push a main (services-prep-2027 | publicador-prep-2027 | deployment-prep-2027)
   │   services/publicador: notify-deployment.yml -> repository_dispatch "source-updated"
   ▼
release.yml (deployment-prep-2027)
   build ─ checkout de los 3 repos (main) ─ pruebas del frontend ─ docker build
           (lint + test + build del backend dentro del Dockerfile) ─ smoke test
           ─ push a ghcr.io/desarrollo-sistemas-iecm/prep-2027 (tag <backend>-<frontend>-<deployment> y :dev)
   ├─ deploy-app-service ─ azure/webapps-deploy por digest ─ espera /version ─ smoke test
   └─ deploy-rhel (matriz [prep-rhel-1]; runner self-hosted en prep2027-int-dev)
           ─ compose pull/up por digest ─ healthcheck ─ smoke test ─ rollback automático si falla
```

Los tres destinos reciben **el mismo digest**. Los secretos de la aplicación viven en cada destino
(App Settings en Azure, `/opt/prep/.env` en RHEL), no en GitHub: el pipeline solo cambia la imagen.
`concurrency: release-dev` garantiza un despliegue a la vez.

## 1. GitHub App (checkout entre repos + repository_dispatch)

`GITHUB_TOKEN` no puede leer otros repos privados ni disparar workflows en otro repo; se usa una
GitHub App de la organización (no un PAT personal). Guía detallada: [`GITHUB-APP-CI.md`](GITHUB-APP-CI.md).

1. Organización → Settings → Developer settings → GitHub Apps → **New GitHub App**
   - Nombre: `prep-2027-ci` · Webhook: desactivado
   - Repository permissions: **Contents: Read and write**, **Metadata: Read-only**
2. Generar una private key (`.pem`).
3. **Install App** en la organización, solo en: `services-prep-2027`, `publicador-prep-2027`,
   `deployment-prep-2027`.
4. En la organización (Settings → Secrets and variables → Actions), visibles para esos 3 repos:
   - Variable `CI_APP_ID` = App ID
   - Secret `CI_APP_PRIVATE_KEY` = contenido del `.pem`

## 2. GHCR (registro de la imagen)

- El primer run crea el paquete `prep-2027` en la organización, ligado a `deployment-prep-2027`
  (label `org.opencontainers.image.source`). Verificar en Packages que quede **privado**.
- Para que App Service haga pull se necesita una credencial de solo lectura: **PAT classic** con scope
  único `read:packages`, idealmente de una cuenta de servicio de la organización (GHCR no acepta
  tokens fine-grained para pull).
- Los RHEL no necesitan credencial propia: el job usa el `GITHUB_TOKEN` del run (`packages: read`) y
  hace `docker logout` al terminar.

## 3. Azure App Service (`app-prep2027-docker-dev`)

### Configuración única en el portal

| Dónde | Valor |
|---|---|
| Centro de implementación → Registro | Origen: Registro privado · Servidor: `https://ghcr.io` · Usuario: cuenta del PAT · Contraseña: PAT `read:packages` |
| Configuración → General | **Always On**: activado · **Credenciales de publicación de autenticación básica de SCM**: activado (lo requiere el perfil de publicación) |
| Supervisión → Comprobación de estado | Ruta `/api/v1/health/ready` (responde 200 también antes del primer corte) |
| Plan → Escalar horizontalmente | **1 instancia, sin escalado automático** (SQLite de un solo escritor) |

### App Settings (variables de entorno)

| Variable | Valor |
|---|---|
| `WEBSITES_PORT` | `3000` |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | `true` (monta `/home` persistente) |
| `NODE_ENV` | `production` |
| `API_PREFIX` | `api/v1` |
| `DB_STORAGE` | `/home/prep/data/database.db3` |
| `CONTROL_DB_STORAGE` | `/home/prep/data/control.db3` |
| `DB_LOGGING` | `false` |
| `JWT_SECRET` | ≥16 caracteres, distinto al de RHEL — preferentemente referencia a Key Vault |
| `JWT_EXPIRES_IN` | `1h` (obligatoria: sin ella el contenedor no arranca) |
| `CORTES_MANIFEST_HMAC_SECRET` | ≥16 caracteres — preferentemente referencia a Key Vault |
| `CORS_ORIGINS` | `https://prep2027-ext-dev.iecm.mx` |
| `SWAGGER_TITLE` / `SWAGGER_PATH` | `PREP API` / `docs` |
| `SWAGGER_VERSION` | `dev` (obligatoria; solo es la etiqueta de Swagger, la versión real la da `/api/v1/version`) |

No declarar `APP_VERSION`, `GIT_COMMIT_*`, `BUILD_DATE` ni `IMAGE_DIGEST`: vienen grabadas en la imagen.

Staging (`staging/`), base activa y `archive/` quedan bajo el directorio de `DB_STORAGE`, así que la
activación atómica (`rename`) ocurre dentro del mismo filesystem.

### Pendientes de validar en el primer despliegue

- **SQLite sobre `/home` (Azure Storage, SMB)**: enviar un corte real con `scripts/send-test-cut.sh`
  contra `https://prep2027-ext-dev.iecm.mx` y verificar activación, archivo y reinicio.
- Que el usuario `node` (uid 1000) pueda escribir en `/home/prep/data`.
- **Integración de red virtual** (`snet-prep2027-appservice-dev`): si tiene "Route All" activo, el
  firewall del IECM debe permitir salida a `ghcr.io` y `pkg-containers.githubusercontent.com`, o el
  pull de la imagen fallará.
- **Restricciones de acceso**: el smoke test corre desde runners de GitHub; si el sitio se restringe por
  IP, ese paso fallará.

### En GitHub (`deployment-prep-2027` → Settings → Environments → `dev-app-service`)

- Secret `AZURE_WEBAPP_PUBLISH_PROFILE` = contenido de "Descargar perfil de publicación"
- Variable `AZURE_WEBAPP_NAME` = `app-prep2027-docker-dev`
- Variable `APP_SERVICE_URL` = `https://prep2027-ext-dev.iecm.mx` (sin `/` final)

## 4. Servidor RHEL (runner self-hosted)

Servidor actual: `prep2027-int-dev.iecm.mx` (RHEL 9). El runner solo abre conexiones **salientes** a
GitHub; no se expone SSH ni el puerto 3000 a internet.

### Preparación (Infraestructura, una sola vez)

- Cuenta de servicio `prep-int-dev_us` con **uid 1000** (coincide con el usuario `node` del
  contenedor, así que no hace falta `chown`) y miembro del grupo `docker`.
- `/opt/prep/{data,logs,keys}` propiedad de la cuenta, con contexto SELinux `container_file_t`.
- Docker Engine + Compose plugin y `git`; salida a `github.com`, `api.github.com`,
  `*.actions.githubusercontent.com`, `ghcr.io` y `pkg-containers.githubusercontent.com`.
- Nginx como proxy TLS (80/443) hacia `127.0.0.1:3000`; firewalld solo con 22/80/443.

### Como la cuenta de servicio (sin sudo)

```bash
# Secretos de la aplicación (ver .env.example)
install -m 600 /dev/null /opt/prep/.env
vi /opt/prep/.env   # JWT_SECRET, CORTES_MANIFEST_HMAC_SECRET, CORS_ORIGINS, PREP_PORT=3000

# Runner: repo deployment-prep-2027 → Settings → Actions → Runners → New self-hosted runner → Linux x64
mkdir ~/actions-runner && cd ~/actions-runner
# descargar y extraer el paquete que indica la página de GitHub
./config.sh --url https://github.com/desarrollo-sistemas-iecm/deployment-prep-2027 \
  --token <TOKEN> --name prep2027-int-dev --labels prep-rhel-1,prep-int-dev --unattended
```

### Servicio

Con sudo: `sudo ./svc.sh install prep-int-dev_us && sudo ./svc.sh start`.

Sin sudo: servicio systemd de usuario (`~/.config/systemd/user/github-runner.service` con
`ExecStart=%h/actions-runner/run.sh`, `Restart=always`, `KillMode=process`), habilitado con
`systemctl --user enable --now github-runner`. Requiere `loginctl enable-linger` (en
`prep2027-int-dev` la propia cuenta pudo ejecutarlo sin sudo); sin linger el runner se detiene al
cerrar la sesión. Verificar con `loginctl show-user prep-int-dev_us -p Linger` → `Linger=yes`.

Verificar en GitHub → Settings → Actions → Runners: `prep2027-int-dev` en **Idle**.

### Agregar otro servidor

Registrar su runner con una etiqueta nueva (p. ej. `prep-rhel-2`) y agregarla a
`jobs.deploy-rhel.strategy.matrix.server` en `release.yml`. Una etiqueta en la matriz sin runner
registrado deja el job en espera indefinida.

Environment de GitHub: crear `dev-rhel` (sin secretos; existe para historial y, en producción,
aprobaciones).

## 5. Opcional — paquete `.tar` firmado para difusores externos

Si existe el secret `RELEASE_SIGNING_SECRET` en el repo, cada run también genera el paquete de
`scripts/package-release.sh` y lo sube como artifact (30 días).

## 6. Al pasar a producción

- Crear environments `prod-*` con **required reviewers** (aprobación manual) y promover el digest ya
  probado en dev, sin reconstruir.
- Mover secretos de App Settings a Key Vault con identidad administrada.
- Reemplazar el perfil de publicación por OIDC (federated credentials) si Entra lo permite.
