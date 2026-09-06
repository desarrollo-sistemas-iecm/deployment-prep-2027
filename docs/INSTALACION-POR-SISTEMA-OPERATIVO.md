# Instalación por sistema operativo — servidores de difusores

Este documento complementa `OPERACION-DIFUSOR-EXTERNO.md`: aquí solo se cubre
lo que cambia **según el sistema operativo del servidor** (instalación de
Docker Engine + Compose, firewall, SELinux/AppArmor). El resto del proceso
— cargar la imagen, levantar el stack, enviar un corte, hacer rollback — es
idéntico en todos los sistemas y ya está descrito ahí y en los scripts de
`scripts/`.

Clasificación según `PROPUESTA TECNOLÓGICA - DOCKER.docx` (sección 7):

| Categoría | Sistemas | Estado |
|---|---|---|
| **Soportados (piloto oficial)** | Ubuntu Server 22.04/24.04 LTS, RHEL 9, Debian estable — todos x86-64/amd64 | Cumplen el requisito del documento |
| **Exploratorio (fuera de alcance)** | Windows 11/Server con Docker Desktop + WSL2 | No sustituye los criterios de aceptación del piloto — ver nota al final |
| **Prueba negativa (fuera de alcance)** | Linux ARM64 | Sirve para confirmar el límite documentado ("ARM requeriría una liberación multi-arquitectura separada"), no para desplegar |

La imagen es siempre `linux/amd64`. Ningún sistema operativo cambia ese
hecho — lo que cambia es cómo cada host llega a tener un motor Docker capaz
de ejecutarla.

---

## 1. Ubuntu Server 22.04 / 24.04 LTS (amd64) — requisito mínimo del documento

```bash
# Quitar versiones antiguas si existieran
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

docker --version
docker compose version
```

**Firewall (ufw)**:

```bash
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp     # solo para redirección a 443, ver apache/prep.conf.example
sudo ufw deny 2375/tcp
sudo ufw deny 2376/tcp
sudo ufw enable
```

Continuar en la sección [2. Pasos comunes](#2-pasos-comunes-todas-las-distribuciones-linux).

---

## RHEL 9 (amd64)

```bash
# Podman viene preinstalado en RHEL 9 y registra un alias docker.io — quitarlo
# para evitar confusión con el docker.io real de Docker CE
sudo dnf remove -y podman-docker 2>/dev/null || true

sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

docker --version
docker compose version
```

**Firewall (firewalld)**:

```bash
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-service=http   # solo para redirección a 443
sudo firewall-cmd --reload
# 2375/2376 no se abren por defecto en firewalld — no hace falta bloqueo explícito
```

**SELinux**: dejarlo en `enforcing` (no desactivar, control explícito de la
sección 9 del documento). Si el bind mount de `/opt/prep/data` da
`Permission denied` dentro del contenedor pese a permisos Unix correctos, es
el contexto SELinux del volumen, no un bug de la aplicación:

```bash
sudo semanage fcontext -a -t container_file_t "/opt/prep/data(/.*)?"
sudo restorecon -Rv /opt/prep/data
# alternativa rápida para diagnóstico (no usar en producción sin evaluar):
# agregar ":Z" al mount en compose.external.yaml, ej. /opt/prep/data:/app/data:Z
```

Continuar en la sección [2. Pasos comunes](#2-pasos-comunes-todas-las-distribuciones-linux).

---

## Debian 12/13 estable (amd64)

```bash
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

docker --version
docker compose version
```

**Firewall (ufw o nftables, según lo que use la instalación)**: igual que
Ubuntu — solo 443/TCP público y 80/TCP para redirección; bloquear 2375/2376.

**AppArmor**: activo por defecto en Debian (a diferencia de RHEL/SELinux),
compatible con `no-new-privileges` y `cap_drop: ALL` ya usados en
`compose.external.yaml` sin ajustes adicionales.

Continuar en la sección [2. Pasos comunes](#2-pasos-comunes-todas-las-distribuciones-linux).

---

## 2. Pasos comunes (todas las distribuciones Linux)

Idénticos en Ubuntu, RHEL y Debian una vez que `docker` y `docker compose`
existen. Ver `OPERACION-DIFUSOR-EXTERNO.md` para el detalle completo de cada
comando.

```bash
sudo mkdir -p /opt/prep/{data,logs,keys}
sudo useradd --system --no-create-home prepops 2>/dev/null || true   # opcional, ver nota de usuario

# Copiar al servidor: prep-2027_<version>_linux-amd64.tar, SHA256SUMS,
# manifest-release.json, manifest-release.sig, compose.external.yaml,
# .env.example, apache/, scripts/

cd /opt/prep/release
cp .env.example .env
# editar JWT_SECRET, CORTES_MANIFEST_HMAC_SECRET, CORS_ORIGINS

sha256sum -c SHA256SUMS                # verificar antes de cargar
./scripts/install-release.sh prep-2027_1.2.0_linux-amd64.tar prep-2027:1.2.0

PREP_IMAGE=prep-2027:1.2.0 docker compose --env-file .env -f compose.external.yaml up -d
./scripts/smoke-test.sh                # BASE_URL=http://127.0.0.1:3000 por defecto
```

Instalar y configurar Apache o Nginx como proxy inverso con TLS (`apache/prep.conf.example`)
publicando solo 443/TCP, es el mismo procedimiento en las tres distribuciones
(cambia únicamente el nombre del paquete: `apache2` en Ubuntu/Debian,
`httpd` en RHEL).

---

## 3. Windows 11 / Windows Server con Docker Desktop + WSL2 (exploratorio, fuera de alcance)

El documento pide explícitamente servidores Linux x86-64 con Docker Engine
(sección 7); esta ruta no lo sustituye. Se documenta como prueba adicional
por si algún difusor solo dispone de hardware Windows.

Windows no ejecuta contenedores Linux de forma nativa. Docker Desktop con
backend WSL2 levanta por debajo una VM Linux ligera — la imagen sigue
corriendo sobre Linux, con una capa extra de virtualización y traducción de
red/volúmenes.

```powershell
# En PowerShell como administrador
wsl --install -d Ubuntu-24.04
# reiniciar si lo pide, y completar el setup del usuario de la distro Ubuntu
```

Instalar Docker Desktop desde el instalador oficial, marcando "Use WSL 2
based engine" durante la instalación. Verificar en PowerShell:

```powershell
docker --version
docker compose version
docker context ls
```

**Ejecutar todo dentro de la distro WSL2 (Ubuntu-24.04), no desde
PowerShell/`C:\`**, para evitar el costo de traducción de E/S en los bind
mounts:

```bash
# dentro de la terminal Ubuntu-24.04 (wsl.exe o Windows Terminal)
mkdir -p ~/prep/data ~/prep/logs
cd ~/prep
# copiar aquí el paquete de release, igual que en Linux nativo
sha256sum -c SHA256SUMS
./scripts/install-release.sh prep-2027_1.2.0_linux-amd64.tar prep-2027:1.2.0
PREP_IMAGE=prep-2027:1.2.0 docker compose --env-file .env -f compose.external.yaml up -d
./scripts/smoke-test.sh
```

**Diferencias a documentar, no a tratar como fallas de la aplicación**:

- **Persistencia**: usar una ruta dentro del filesystem de WSL2
  (`~/prep/data`) en vez de un bind mount a `C:\...` — el rendimiento y los
  permisos de archivo son distintos al cruzar el límite Windows↔WSL2.
- **Proxy/TLS**: Apache o Nginx normalmente se instalan dentro de la misma
  distro WSL2 (mismo paquete que en Ubuntu nativo) o como contenedor aparte;
  no existe un equivalente directo de `apache2`/`httpd` como servicio nativo
  de Windows en este flujo.
- **Seguridad**: los controles de la sección 9 del documento (SELinux/
  AppArmor, bloqueo de 2375/2376 a nivel de SO) no aplican igual bajo WSL2 —
  requiere revisión aparte, no asumir equivalencia con Linux nativo.
- **Arquitectura**: sigue siendo amd64 — aquí no se repite la limitación de
  ARM (ver sección 4).

Los resultados de esta ruta deben registrarse por separado (p. ej. en
`PRUEBAS-LOCALES.md`, sección "Pruebas exploratorias fuera de alcance") y no
usarse para certificar Windows como plataforma válida de difusor ante el
IECM.

---

## 4. Linux ARM64 (prueba negativa, fuera de alcance)

Objetivo: confirmar el límite que el propio documento señala ("ARM
requeriría una liberación multi-arquitectura separada"), no habilitar un
despliegue real en ARM.

En una VM Linux **arm64 nativa** (sin capa de traducción como Rosetta):

```bash
uname -m   # debe reportar aarch64
docker --version

# Intento directo: debe fallar o requerir emulación explícita
docker load -i prep-2027_1.2.0_linux-amd64.tar
docker run --rm prep-2027:1.2.0 node -e "console.log(process.arch)"
```

Resultado esperado: falla de arquitectura (`exec format error`) o, si se
instala soporte de emulación (`qemu-user-static` + `binfmt_misc`), corre
pero con degradación de rendimiento notable — exactamente el escenario que
el documento descarta para producción:

```bash
# Solo para documentar el comportamiento, no para habilitarlo en un difusor real
sudo apt-get install -y qemu-user-static binfmt-support
docker run --rm --platform linux/amd64 prep-2027:1.2.0 node -e "console.log(process.arch)"
```

Este resultado se documenta como evidencia de que un difusor con hardware
ARM necesitaría una imagen `linux/arm64` publicada aparte (build multi-
arquitectura en CI), no como un defecto a corregir en el Dockerfile actual.

---

## Referencias

- `OPERACION-DIFUSOR-EXTERNO.md` — runbook completo (instalar, rollback, verificar firma/checksum, Apache).
- `API-CORTES-SQLITE.md` — contrato de envío de cortes, usado en las pruebas de extremo a extremo en cada SO.
- `PRUEBAS-LOCALES.md` — resultados reales de pruebas ya ejecutadas; agregar ahí los resultados por SO conforme se vayan corriendo estas VMs.
- `../../RESUMEN-EJECUTIVO-DOCKER.md` — resumen general del trabajo de dockerización.
