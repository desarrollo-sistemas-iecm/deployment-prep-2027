# GitHub App de CI (`prep-2027-ci`)

La GitHub App es una identidad de la organización **en GitHub** (no en Azure). El pipeline
[`release.yml`](../.github/workflows/release.yml) la usa para:

- Hacer checkout de los repos privados `services-prep-2027` y `publicador-prep-2027` desde
  `deployment-prep-2027` (el `GITHUB_TOKEN` de un repo no puede leer otros repos privados).
- Que `services-prep-2027` y `publicador-prep-2027` disparen el release en `deployment-prep-2027`
  (`repository_dispatch` desde `notify-deployment.yml`).

Se prefiere sobre un PAT personal porque no depende de la cuenta de una persona, sus permisos se
limitan a 3 repos y los tokens que emite duran una hora.

Contexto general del pipeline: [`CI-CD.md`](CI-CD.md).

## Requisito

Ser **owner** de la organización `desarrollo-sistemas-iecm` o tener el rol "GitHub App manager". Si en
la organización no aparece **Settings**, no se tienen esos permisos.

## 1. Crear la App

Organización → **Settings** (de la organización, no de un repo) → **Developer settings** →
**GitHub Apps** → **New GitHub App**.

Enlace directo: <https://github.com/organizations/desarrollo-sistemas-iecm/settings/apps/new>

| Campo | Valor |
|---|---|
| GitHub App name | `prep-2027-ci`. Es único en todo GitHub: si está ocupado, usar por ejemplo `iecm-prep-2027-ci` |
| Homepage URL | `https://github.com/desarrollo-sistemas-iecm` (obligatorio, no se usa) |
| Webhook → Active | **Desmarcado** |
| Repository permissions → **Contents** | **Read and write** |
| Repository permissions → **Metadata** | Read-only (se marca automáticamente) |
| Resto de permisos | Sin acceso |
| Where can this GitHub App be installed? | **Only on this account** |

**Create GitHub App**.

Contents: Read and write es el mínimo necesario: lectura para el checkout y escritura porque GitHub
la exige para enviar `repository_dispatch`.

## 2. App ID y llave privada

1. En la página de la App, anotar el **App ID** (parte superior).
2. **Private keys** → **Generate a private key**. Se descarga un `.pem` que **no puede volver a
   descargarse** (si se pierde, se genera otra y se revoca la anterior).

## 3. Instalar la App

Menú izquierdo de la App → **Install App** → **Install** en `desarrollo-sistemas-iecm` →
**Only select repositories**:

- `services-prep-2027`
- `publicador-prep-2027`
- `deployment-prep-2027`

## 4. Variable y secret de organización

Organización → **Settings** → **Secrets and variables** → **Actions**:

| Pestaña | Nombre | Valor | Repository access |
|---|---|---|---|
| Variables | `CI_APP_ID` | App ID | Los 3 repos anteriores |
| Secrets | `CI_APP_PRIVATE_KEY` | Contenido completo del `.pem`, incluidas las líneas `-----BEGIN…` y `-----END…` | Los 3 repos anteriores |

Después, borrar el `.pem` de la carpeta de descargas o resguardarlo en un gestor de secretos.

## Uso en los workflows

```yaml
- name: Token de la GitHub App
  id: app-token
  uses: actions/create-github-app-token@v2
  with:
    app-id: ${{ vars.CI_APP_ID }}
    private-key: ${{ secrets.CI_APP_PRIVATE_KEY }}
    owner: desarrollo-sistemas-iecm
    repositories: services-prep-2027,publicador-prep-2027
```

El token resultante (`steps.app-token.outputs.token`) solo tiene acceso a los repos listados en
`repositories` y expira en una hora.

## Mantenimiento

- **Rotar la llave**: generar una nueva private key, actualizar `CI_APP_PRIVATE_KEY` y borrar la
  anterior desde la página de la App.
- **Agregar un repo** al pipeline: incluirlo en la instalación de la App (Install App → Configure) y en
  el "Repository access" de la variable y del secret.
- **Fallo `Could not create installation access token`** en el paso del token: revisar que la App esté
  instalada en el repo que se pide y que `CI_APP_ID`/`CI_APP_PRIVATE_KEY` sean visibles para el repo
  que ejecuta el workflow.
