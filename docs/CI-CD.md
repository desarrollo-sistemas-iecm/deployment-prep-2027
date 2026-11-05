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
   └─ deploy-rhel (matriz prep-rhel-1, prep-rhel-2; runners self-hosted)
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
| `CORTES_MANIFEST_HMAC_SECRET` | ≥16 caracteres — preferentemente referencia a Key Vault |
| `CORS_ORIGINS` | `https://prep2027-ext-dev.iecm.mx` |
| `SWAGGER_TITLE` / `SWAGGER_PATH` | `PREP API` / `docs` |

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

## 4. Servidores RHEL (runners self-hosted)

El runner solo abre conexiones **salientes** a GitHub; no se expone SSH a internet.

En cada servidor (como root o con sudo):

```bash
dnf install -y git
useradd -m -s /bin/bash github-runner
usermod -aG docker github-runner

mkdir -p /opt/prep/{data,logs}
chown -R 1000:1000 /opt/prep/data /opt/prep/logs
semanage fcontext -a -t container_file_t '/opt/prep/(data|logs)(/.*)?'
restorecon -Rv /opt/prep

# Secretos de la aplicación (ver .env.example)
install -m 640 -o root -g github-runner /dev/null /opt/prep/.env
vi /opt/prep/.env   # JWT_SECRET, CORTES_MANIFEST_HMAC_SECRET, CORS_ORIGINS, PREP_PORT (opcional)
```

Registrar el runner (repo `deployment-prep-2027` → Settings → Actions → Runners → New self-hosted
runner → Linux x64, copiar el token):

```bash
su - github-runner
mkdir actions-runner && cd actions-runner
# descargar y extraer el paquete que indica la página de GitHub
./config.sh --url https://github.com/desarrollo-sistemas-iecm/deployment-prep-2027 \
  --token <TOKEN> --name prep-rhel-1 --labels prep-rhel-1 --unattended
exit
cd /home/github-runner/actions-runner
./bin/installdependencies.sh
./svc.sh install github-runner && ./svc.sh start
```

En el segundo servidor usar `prep-rhel-2` como `--name` y `--labels`.

Environment de GitHub: crear `dev-rhel` (sin secretos; existe para historial y, en producción,
aprobaciones).

Apache sigue como proxy TLS hacia `127.0.0.1:${PREP_PORT:-3000}` (`apache/prep.conf.example`).

## 5. Opcional — paquete `.tar` firmado para difusores externos

Si existe el secret `RELEASE_SIGNING_SECRET` en el repo, cada run también genera el paquete de
`scripts/package-release.sh` y lo sube como artifact (30 días).

## 6. Al pasar a producción

- Crear environments `prod-*` con **required reviewers** (aprobación manual) y promover el digest ya
  probado en dev, sin reconstruir.
- Mover secretos de App Settings a Key Vault con identidad administrada.
- Reemplazar el perfil de publicación por OIDC (federated credentials) si Entra lo permite.
