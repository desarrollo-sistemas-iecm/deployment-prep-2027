# Contrato de recepción de cortes SQLite — `POST /api/v1/cortes`

Este documento describe el contrato **real** implementado en
`services-prep-2027/src/modules/cortes/`, no una propuesta. Difiere en dos
puntos del borrador original de la tarea (RSA-PSS asimétrico y `signature`
como parte multipart separada): el equipo ya había implementado y testeado
HMAC-SHA256 con la firma embebida en el manifest, y se decidió mantenerlo tal
cual en vez de reescribir código de seguridad ya probado (ver
`IMPLEMENTACION-DOCKER.md`, sección "Decisiones").

## Endpoint

```
POST /api/v1/cortes
Authorization: Bearer <JWT HS256, firmado con JWT_SECRET, claim "sub">
Content-Type: multipart/form-data
```

Guard: `JwtDifusorGuard` (`src/modules/cortes/guards/jwt-difusor.guard.ts`).
Cualquier JWT válido firmado con `JWT_SECRET` (algoritmo `HS256`, no
expirado) es aceptado — hoy no valida rol/permiso específico (hay un TODO
explícito en el código para cuando exista el módulo `auth`).

## Partes del multipart

| Campo          | Tipo   | Descripción                                                                 |
|----------------|--------|------------------------------------------------------------------------------|
| `cutId`        | texto  | Identificador único del corte, `^[a-zA-Z0-9_-]{1,64}$`. Clave de idempotencia. |
| `version`      | texto  | Versión del corte, 1-32 caracteres (comparada numéricamente por segmentos, ej. `2.10` > `2.9`). |
| `activationAt` | texto  | Fecha/hora ISO 8601 de activación programada.                                |
| `manifest`     | texto  | JSON **como cadena** (ver esquema abajo). Incluye la firma.                   |
| `database`     | archivo| El `.db3` SQLite. Único campo de archivo — no hay campos `manifest`/`signature` como archivos separados. |

No se envía un campo `signature` aparte: va **dentro** del JSON de `manifest`.

## Esquema del manifest

```json
{
  "cutId": "corte-2026-09-05-01",
  "version": "1.0",
  "activationAt": "2026-09-05T18:05:00.000Z",
  "sha256": "<sha256 hex del archivo database, 64 chars>",
  "generatedAt": "2026-09-05T17:58:00.000Z",
  "signatureAlgorithm": "HMAC-SHA256",
  "signature": "<HMAC-SHA256 hex, 64 chars>"
}
```

Validado por `class-validator` en `dto/manifest.dto.ts`
(`forbidNonWhitelisted: true` — cualquier campo extra rechaza el manifest).

### Cómo firmar (lado difusor)

1. Calcular `sha256` = SHA-256 hex del archivo `.db3` completo.
2. Construir el payload canónico — **exactamente estos 6 campos, en este
   orden**, serializados con `JSON.stringify` (sin espacios extra, sin
   reordenar):
   ```json
   {"cutId":"...","version":"...","activationAt":"...","sha256":"...","generatedAt":"...","signatureAlgorithm":"HMAC-SHA256"}
   ```
   (función `canonicalManifestPayload` en `dto/manifest.dto.ts`).
3. `signature` = HMAC-SHA256(payload canónico, `CORTES_MANIFEST_HMAC_SECRET`) en hex.
4. El multipart debe llevar los mismos `cutId`/`version`/`activationAt` como
   campos de formulario Y dentro del manifest — `manifest-verification.service.ts`
   rechaza (`422`) si no coinciden byte a byte.

Implementación de referencia completa (Node, sin dependencias):
`deployment-prep-2027/scripts/send-test-cut.mjs`.

## Respuestas

| Código | Cuándo |
|--------|--------|
| `202 Accepted` | Corte nuevo recibido, en validación asíncrona. `Location: /api/v1/cortes/:cutId/estado`. |
| `200 OK` | Mismo `cutId` + mismo `fileSha256` ya recibido antes (idempotente). |
| `400 Bad Request` | `cutId` ausente/inválido, JSON de manifest inválido, o no cumple el DTO. |
| `401 Unauthorized` | Token ausente/inválido/expirado, o firma HMAC del manifest inválida. |
| `409 Conflict` | Mismo `cutId` con un archivo de contenido distinto (`fileSha256` no coincide). |
| `413 Payload Too Large` | Excede `CORTES_MAX_UPLOAD_MB` (default 100). Límite de Multer, respuesta estándar de Nest. |
| `422 Unprocessable Entity` | El manifest no coincide con los campos del formulario, o el `sha256` del manifest no coincide con el archivo. |
| `500` | Error no controlado — nunca expone stack trace, SQL ni rutas internas (filtro global de Nest). |

Nota: la tabla original de la tarea pedía `201` para "activado inmediatamente"
— el endpoint de subida siempre responde `202`/`200` (la activación es
**asíncrona**, ver siguiente sección); el resultado final se consulta en
`GET /cortes/:cutId/estado`.

## Validación asíncrona y activación

Tras responder, `CortesService.runValidationPipeline` corre en background:

1. `VALIDATING` → `SqliteFileValidationService`: abre el archivo en modo
   solo-lectura, `PRAGMA integrity_check`, verifica que existan las 22 tablas
   legacy esperadas (`RESULTADOS_LEGACY_TABLE_NAMES`).
2. Si falla: `FAILED` con motivo.
3. Si pasa: `VALIDATED`, y `ActivationService.scheduleOrActivate` decide:
   - Si `activationAt` ya pasó: activa de inmediato.
   - Si es futuro: programa un timer (persistido implícitamente — al
     reiniciar el contenedor, `ActivationService.onModuleInit` relee los
     `VALIDATED` pendientes y reprograma).
4. Activación (`ActivationService.activate`):
   - Rechaza (marca `FAILED`) si ya hay un corte `ACTIVATED` con versión
     igual o mayor.
   - Archiva el `database.db3` vigente a `data/archive/<timestamp>-<cutId>.db3`
     (conserva las últimas 2 versiones).
   - Cierra el DataSource `resultados`, reemplaza el archivo (rename atómico),
     lo reabre, corre una consulta de sanidad.
   - Si algo falla en este paso: restaura el archivo anterior, reabre el
     DataSource con él, marca el nuevo release `FAILED` — la app sigue
     sirviendo el corte anterior sin interrupción.
   - Si todo sale bien: el release nuevo pasa a `ACTIVATED`, el anterior a
     `ARCHIVED`.

## Endpoints de consulta

```
GET /api/v1/cortes/:cutId/estado   -> { cutId, version, activationAt, status, failureReason }
GET /api/v1/cortes/activo          -> el release con status=ACTIVATED, o null
```

`status` es uno de: `uploaded`, `validating`, `validated`, `failed`,
`activated`, `archived`.

## Layout de datos (adaptación documentada)

La tarea original pedía una jerarquía literal `current/pending/archive/state/`.
Se adaptó a lo que ya existía en `services-prep-2027` para no reestructurar la
configuración TypeORM ya wireada:

| Concepto original | Ruta real usada                          | Notas |
|--------------------|-------------------------------------------|-------|
| `current/`         | `data/database.db3` (`DB_STORAGE`)         | Archivo fijo, ya usado por el DataSource `resultados`. |
| `pending/`          | `data/staging/<cutId>/<uuid>.db3`         | Ya existía (Multer). |
| `archive/`          | `data/archive/<timestamp>-<cutId>.db3`    | Nuevo, agregado por `ActivationService`. Retiene 2. |
| `state/`            | `data/control.db3` (tabla `corte_releases`)| Ya existía — no hace falta un directorio de estado aparte. |

## Secretos

- `JWT_SECRET`: firma los JWT del difusor. Mínimo 16 caracteres (Joi).
- `CORTES_MANIFEST_HMAC_SECRET`: firma/verifica el manifest. Mínimo 16
  caracteres. **Compartido** entre el difusor real y el backend — no hay
  llave pública/privada en este contrato (ver nota RSA-PSS arriba).
- Ninguno de los dos se registra en logs ni se expone en respuestas de error.

## Runtime/keys (reservado, no usado por este contrato)

`deployment-prep-2027/runtime/keys/` existe en el árbol de despliegue para un
futuro esquema asimétrico (TLS de cliente, RSA-PSS) — hoy no lo consume
ningún código; el secreto HMAC viaja como variable de entorno
(`CORTES_MANIFEST_HMAC_SECRET`).
