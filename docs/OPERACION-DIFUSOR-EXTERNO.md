# Operación para difusores externos (servidor Linux local)

No requiere PHP, PM2, Node.js ni Angular instalados en el servidor anfitrión
— solo Docker Engine + Docker Compose plugin, y opcionalmente Apache si se
quiere TLS y no exponer el puerto del contenedor directamente.

## Rutas recomendadas en el servidor

```
/opt/prep/data     # SQLite vivo + control + staging + archive (persistente)
/opt/prep/logs
/opt/prep/keys      # reservado (no usado por el contrato HMAC actual)
```

## 1. Instalar una versión nueva

```bash
# Copiar al servidor: prep-2027_<version>_linux-amd64.tar, SHA256SUMS,
# manifest-release.json, manifest-release.sig, compose.external.yaml,
# .env.example, apache/, scripts/

sudo mkdir -p /opt/prep/{data,logs,keys}
cp .env.example .env   # editar JWT_SECRET, CORTES_MANIFEST_HMAC_SECRET, CORS_ORIGINS

./scripts/install-release.sh prep-2027_1.2.0_linux-amd64.tar prep-2027:1.2.0
# verifica SHA256SUMS antes de cargar, y hace docker load + docker tag

PREP_IMAGE=prep-2027:1.2.0 docker compose --env-file .env -f compose.external.yaml up -d
docker compose -f compose.external.yaml ps
./scripts/smoke-test.sh   # BASE_URL=http://127.0.0.1:3000 por defecto
```

## 2. Conservar la versión anterior

`install-release.sh` etiqueta la imagen nueva sin borrar la anterior. Antes
de instalar, anota qué tag/imagen está corriendo:

```bash
docker compose -f compose.external.yaml images
```

Docker conserva ambas imágenes localmente hasta que se borren explícitamente
(`docker image rm`) — no se auto-eliminan al instalar una nueva.

## 3. Validar `/health`

```bash
curl http://127.0.0.1:3000/api/v1/health/live
curl http://127.0.0.1:3000/api/v1/health/ready
curl http://127.0.0.1:3000/api/v1/version
```

## 4. Rollback de imagen (sin afectar la SQLite vigente)

```bash
./scripts/rollback-release.sh prep-2027:1.1.0
```

Los volúmenes/bind mounts de `/opt/prep/data` no se tocan — el corte activo
antes del rollback sigue siendo el mismo después, porque la activación de
cortes vive en los datos, no en la imagen.

## 5. Reiniciar conservando datos

```bash
docker compose -f compose.external.yaml restart
```

Al reiniciar, `ActivationService.onModuleInit` relee `corte_releases` con
estado `validated` y reprograma/ejecuta cualquier activación pendiente —
no se pierde una activación programada por un reinicio.

## 6. Consultar versión y corte activo

```bash
curl http://127.0.0.1:3000/api/v1/version
curl http://127.0.0.1:3000/api/v1/cortes/activo
```

## 7. Apache como proxy inverso (opcional, recomendado en producción)

Ver `apache/prep.conf.example`. Termina TLS en Apache, reenvía a
`127.0.0.1:3000` (el contenedor solo publica en loopback, nunca
directamente a internet). Recordar el ajuste de `trust proxy` documentado
al final de ese archivo.

## 8. Verificar que la imagen cargada corresponde al artefacto aprobado

```bash
sha256sum -c SHA256SUMS
docker image inspect prep-2027:1.2.0 --format '{{.Id}}'
# comparar con "imageId" en manifest-release.json
node -e "
const crypto = require('crypto'), fs = require('fs');
const manifest = fs.readFileSync('manifest-release.json', 'utf-8');
const expected = fs.readFileSync('manifest-release.sig', 'utf-8').trim();
const actual = crypto.createHmac('sha256', process.env.RELEASE_SIGNING_SECRET).update(manifest).digest('hex');
console.log(actual === expected ? 'firma OK' : 'FIRMA NO COINCIDE');
"
```
