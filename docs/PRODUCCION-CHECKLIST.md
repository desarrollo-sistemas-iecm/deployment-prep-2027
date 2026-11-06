# Checklist de puesta en producción — PREP 2027

Lista ordenada de todo lo que hay que pedir, configurar y verificar cuando se entreguen los ambientes
de producción (Azure App Service + servidores RHEL con Docker). Recoge lo aprendido al montar dev
(nov-2026): cada fallo que tuvimos ahí tiene aquí un paso que lo previene (ver
[sección 9](#9-lecciones-de-dev-error--paso-que-lo-previene)).

Documentos relacionados:

- [`CI-CD.md`](CI-CD.md) — cómo funciona el pipeline y su configuración en dev.
- [`GITHUB-APP-CI.md`](GITHUB-APP-CI.md) — GitHub App del pipeline.
- [`REQUERIMIENTOS-SERVIDORES-DESARROLLO.md`](REQUERIMIENTOS-SERVIDORES-DESARROLLO.md) — requisitos de
  servidores (aplican igual a producción, con el hardware de producción).
- [`../nginx/prep.conf.example`](../nginx/prep.conf.example) / [`../apache/prep.conf.example`](../apache/prep.conf.example) — proxy inverso.

Convención: **[Infra]** lo hace Infraestructura, **[Dev]** lo hacemos nosotros, **[Org]** requiere
owner de la organización de GitHub.

---

## 0. Antes de que entreguen nada (pendientes de código)

Resolver en dev y fusionar a `main` antes del primer despliegue a producción:

- [ ] **[Dev] Promoción por digest en `release.yml`**: jobs `deploy-prod-*` que reciban el digest ya
      probado en dev (`workflow_dispatch` con input `image_ref`, o un job posterior a dev) y desplieguen
      **sin reconstruir**. Usan environments `prod-app-service` / `prod-rhel` con aprobación manual.
- [ ] **[Dev] `trust proxy` en `services-prep-2027`** (`app.set('trust proxy', 'loopback')` en el
      bootstrap): detrás de Nginx todas las peticiones llegan desde `127.0.0.1` y el rate limit de
      cortes (`CORTES_UPLOAD_RATE_LIMIT`) se vuelve global para todos los clientes. En App Service el
      valor adecuado es distinto (el front end de Azure no es loopback): validar con `X-Forwarded-For`.
- [ ] **[Dev] Respuesta sin corte activo**: hoy los endpoints de resultados responden 500
      (`no such table: prep_votos`) hasta que llega el primer corte. Responder 503/estado
      "esperando primer corte" para que el frontend lo muestre en lugar de un error.
- [ ] **[Dev] Etiquetas de runner de producción** en la matriz de `deploy-prod-rhel`
      (p. ej. `prep-prod-1`, `prep-prod-2`). Una etiqueta sin runner registrado deja el job en espera
      indefinida.

## 1. Inventario a confirmar con Infraestructura

| Dato | Valor prod | Notas |
|---|---|---|
| Nombre del App Service | | Plan con 1 instancia |
| Dominio público App Service | | Certificado TLS asignado |
| Servidores RHEL (hostname, cantidad) | | Uno por etiqueta de runner |
| Dominio(s) de los RHEL | | |
| Cuenta de servicio en cada RHEL | | Debe tener **uid 1000** |
| ¿Sitio App Service restringido por IP / endpoint privado? | | Afecta el smoke test desde GitHub |
| ¿VNet con "Route All"? | | Requiere salida a GHCR |
| Política de respaldo de `/opt/prep/data` y `/home` | | |

## 2. Servidores RHEL — solicitud a Infraestructura

Por cada servidor:

- [ ] **[Infra]** RHEL 9 con Docker Engine + Compose plugin (repo oficial de Docker) y `git`.
- [ ] **[Infra]** Cuenta de servicio con **uid 1000** (igual al usuario `node` del contenedor; si no, la
      app no puede escribir en los volúmenes) y miembro del grupo `docker`.
- [ ] **[Infra]** `/opt/prep/{data,logs,keys}` propiedad de la cuenta, con contexto SELinux
      `container_file_t` (`semanage fcontext -a -t container_file_t '/opt/prep(/.*)?'` + `restorecon -Rv /opt/prep`).
- [ ] **[Infra]** Linger habilitado para la cuenta: `sudo loginctl enable-linger <cuenta>` (sin esto el
      runner se detiene al cerrar la sesión SSH y no arranca tras un reinicio).
- [ ] **[Infra]** Salida HTTPS (443) a: `github.com`, `api.github.com`, `*.actions.githubusercontent.com`,
      `codeload.github.com`, `ghcr.io`, `pkg-containers.githubusercontent.com`.
- [ ] **[Infra]** Nginx con TLS según [`nginx/prep.conf.example`](../nginx/prep.conf.example). Indispensable:
      `client_max_body_size 110m;` (el default de 1 MB rechaza los cortes con **413**),
      `proxy_request_buffering off;`, `proxy_read_timeout 120s;`, `proxy_send_timeout 120s;`.
- [ ] **[Infra]** firewalld: solo 22 (restringido), 80 y 443 entrantes. 3000 solo en loopback.
      2375/2376 cerrados.
- [ ] **[Infra]** Lectura de `/var/log/nginx/` para la cuenta de servicio (grupo `adm` o ACL), para
      diagnosticar sin depender de Infraestructura.
- [ ] **[Infra]** DNS + certificado TLS del dominio.

Verificación **[Dev]** (como la cuenta de servicio, antes de instalar nada):

```bash
id                                    # uid=1000, grupo docker
docker version && docker compose version
ls -ldZ /opt/prep /opt/prep/*         # dueño = cuenta, container_file_t
loginctl show-user "$USER" -p Linger  # Linger=yes
for u in https://github.com https://api.github.com https://ghcr.io/v2/ https://pkg-containers.githubusercontent.com; do
  printf '%s ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "$u"; done   # cualquier código = alcanzable
```

## 3. Azure App Service — solicitud / configuración

- [ ] **[Infra]** Plan Linux con contenedor, **1 instancia, sin autoescalado** (SQLite de un solo escritor).
- [ ] **[Infra]** Si hay integración de VNet con "Route All": permitir salida a `ghcr.io` y
      `pkg-containers.githubusercontent.com`. Verificar desde SSH del App Service:
      `curl -sI https://ghcr.io/v2/` (405/401 = alcanzable).
- [ ] **[Infra]** Dominio personalizado + certificado.
- [ ] **[Dev/Infra]** Configuración → General: **Always On** activado; **Credenciales de publicación
      básica SCM** activadas (las requiere el perfil de publicación; o usar OIDC, ver sección 4).
- [ ] **[Dev/Infra]** Supervisión → Comprobación de estado: `/api/v1/health/ready`.
- [ ] **[Dev]** Variables de entorno (todas; las marcadas son obligatorias o el contenedor no arranca):

| Variable | Valor | |
|---|---|---|
| `WEBSITES_PORT` | `3000` | obligatoria |
| `WEBSITES_ENABLE_APP_SERVICE_STORAGE` | `true` | obligatoria (persistencia en `/home`) |
| `DOCKER_REGISTRY_SERVER_URL` | `https://ghcr.io` | obligatoria |
| `DOCKER_REGISTRY_SERVER_USERNAME` | cuenta de servicio dueña del PAT | obligatoria |
| `DOCKER_REGISTRY_SERVER_PASSWORD` | el PAT (`ghp_...`), **no** el texto `read:packages` | obligatoria, Key Vault |
| `NODE_ENV` | `production` | |
| `API_PREFIX` | `api/v1` | obligatoria |
| `DB_STORAGE` | `/home/prep/data/database.db3` | obligatoria |
| `CONTROL_DB_STORAGE` | `/home/prep/data/control.db3` | obligatoria |
| `DB_LOGGING` | `false` | en `true` registra cada consulta con sus parámetros |
| `JWT_SECRET` | aleatorio ≥32 bytes, propio de prod | obligatoria, Key Vault |
| `JWT_EXPIRES_IN` | `1h` | obligatoria |
| `CORTES_MANIFEST_HMAC_SECRET` | aleatorio ≥32 bytes, propio de prod | obligatoria, Key Vault |
| `CORS_ORIGINS` | dominio público de prod | obligatoria |
| `SWAGGER_TITLE` / `SWAGGER_PATH` / `SWAGGER_VERSION` | `PREP API` / `docs` / `prod` | obligatorias |

No declarar `APP_VERSION`, `GIT_COMMIT_*`, `BUILD_DATE` ni `IMAGE_DIGEST` (vienen en la imagen).

Por qué las `DOCKER_REGISTRY_SERVER_*` aunque el registro esté en el Centro de implementación: si el
sitio se creó en modo "Contenedores" (sidecar), esas credenciales quedan en el contenedor `main`, pero
`azure/webapps-deploy` cambia el sitio a modo clásico, que solo lee estas variables.

## 4. GitHub

- [ ] **[Org]** PAT classic `read:packages` de una **cuenta de servicio** de la organización (no personal),
      con fecha de expiración anotada en el calendario del equipo. Confirmar que la organización no
      bloquea PATs classic.
- [ ] **[Org]** GitHub App `prep-2027-ci` ya existe (dev); no requiere cambios salvo agregar repos nuevos.
- [ ] **[Dev]** Environments `prod-app-service` y `prod-rhel` con **Required reviewers** y, opcional,
      restricción a la rama `main`.
- [ ] **[Dev]** En `prod-app-service`: secret `AZURE_WEBAPP_PUBLISH_PROFILE` (o credenciales OIDC si Entra
      lo permite), variables `AZURE_WEBAPP_NAME` y `APP_SERVICE_URL` (sin `/` final).
- [ ] **[Dev]** Protección de rama `main` en los 3 repos (PR obligatorio, checks en verde).
- [ ] **[Dev]** Paquete `prep-2027` en GHCR: visibilidad **Private**.

## 5. Secretos de aplicación

- [ ] **[Dev]** Generar con `openssl rand -hex 32`, **distintos a los de dev** y, de preferencia, distintos
      por destino. Nunca nombres, fechas ni valores reutilizados.
- [ ] **[Dev]** Nunca pegarlos en chats, tickets ni capturas. Para revisar sin mostrar valores:
      `docker exec prep-2027 sh -c 'env | grep -E "^CORTES_|^JWT_" | cut -d= -f1'`.
- [ ] **[Dev]** Registrar en el extractor/bot de difusores el `JWT_SECRET` y `CORTES_MANIFEST_HMAC_SECRET`
      **de cada destino** (si difieren, el destino rechaza con 401 o firma inválida).
- [ ] **[Dev]** App Service: referencias a Key Vault con identidad administrada.

## 6. Runner en cada RHEL

Como la cuenta de servicio (detalle en [`CI-CD.md` §4](CI-CD.md#4-servidor-rhel-runner-self-hosted)):

```bash
install -m 600 /dev/null /opt/prep/.env
vi /opt/prep/.env   # JWT_SECRET, CORTES_MANIFEST_HMAC_SECRET, CORS_ORIGINS=https://<dominio>, PREP_PORT=3000

mkdir ~/actions-runner && cd ~/actions-runner
# descargar/extraer según GitHub → Settings → Actions → Runners → New self-hosted runner
./config.sh --url https://github.com/desarrollo-sistemas-iecm/deployment-prep-2027 \
  --token <TOKEN> --name <hostname> --labels prep-prod-1 --unattended
```

- [ ] Servicio: `sudo ./svc.sh install <cuenta> && sudo ./svc.sh start`, o servicio systemd de usuario
      (`systemctl --user enable --now github-runner`) con linger.
- [ ] `loginctl show-user <cuenta> -p Linger` → `Linger=yes`; `systemctl --user is-active github-runner` → `active`.
- [ ] Cerrar SSH, esperar 1 minuto: el runner sigue **Idle** en GitHub.
- [ ] Reiniciar el servidor (ventana acordada): el runner vuelve a **Idle** solo.

## 7. Primer despliegue y validación

- [ ] Promover a producción el digest validado en dev; aprobar en los environments.
- [ ] Jobs en verde: smoke test 5/5 en App Service y en cada RHEL.
- [ ] `GET /api/v1/version` en cada destino devuelve la misma `appVersion` y `imageDigest`.
- [ ] Abrir el dominio público de cada RHEL (pasa por Nginx; el smoke test del job solo prueba `127.0.0.1`).
- [ ] **Corte real** a cada destino desde el extractor: estado `activated`, `health/ready` = `ready`.
      Si un destino responde 413, es el proxy (sección 2).
- [ ] Reiniciar el contenedor/App Service: el corte activo persiste (`health/ready` sigue `ready`).
- [ ] Segundo corte: el anterior queda en `archive/`.
- [ ] Rollback de prueba: redeplegar el digest anterior y confirmar que levanta.
- [ ] Logs sin consultas SQL (`DB_LOGGING=false`) ni secretos.

## 8. Operación continua

- [ ] Respaldo de `/opt/prep/data` (RHEL) y `/home/prep/data` (App Service).
- [ ] Alertas: App Service health check, runner Offline, jobs fallidos (notificaciones de GitHub).
- [ ] Calendario: expiración del PAT de GHCR, rotación de la llave de la GitHub App, renovación de certificados.
- [ ] Rotación de logs en `/opt/prep/logs` y de Nginx.
- [ ] Revisar periódicamente imágenes viejas en GHCR (el job de RHEL ya limpia imágenes locales de más de 7 días).

## 9. Lecciones de dev (error → paso que lo previene)

| Síntoma en dev | Causa | Prevención |
|---|---|---|
| Job RHEL esperando para siempre | Etiqueta `prep-rhel-2` en la matriz sin runner | §0, matriz = runners reales |
| Runner Offline al cerrar SSH | `Linger=no` | §2 / §6 |
| Smoke test CI: `Config validation error: "JWT_EXPIRES_IN" is required` | Variable obligatoria faltante | §3 tabla completa; validar contra `services-prep-2027/src/config/env.validation.ts` |
| App Service "sin respuesta" + `ImagePullUnauthorizedFailure` | Sin `DOCKER_REGISTRY_SERVER_*` (modo sidecar → clásico) | §3 |
| Mismo error tras agregar variables | Password con el texto `read:packages` en lugar del PAT | §3 |
| Corte `failed`: `EXDEV: cross-device link not permitted` | Staging en `/app/data` y DB en `/home` (distinto filesystem) | Corregido en `services` (staging junto a `DB_STORAGE`); mantener `DB_STORAGE` y staging en el mismo volumen |
| Logs con cada consulta SQL | `DB_LOGGING=true` | §3 |
| RHEL rechaza cortes con 413, la app no registra nada | Nginx `client_max_body_size` 1 MB por defecto | §2 |
| Secreto HMAC expuesto en una salida de consola | `env` impreso completo | §5 |
| Endpoints de resultados 500 antes del primer corte | Tablas inexistentes en BD vacía | §0 |
