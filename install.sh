#!/usr/bin/env bash
# Instalador de MvS. Copia el panel a /opt/<slug> e instala solo paquetes de apt.
# Sistemas: Ubuntu 18.04–24.04 (x86_64 y ARM64) y Debian 8–12 (x86_64; ARM64 sin garantía).
# Variable opcional: MVS_FORCE=1 salta la comprobación de sistema operativo.
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SRC/config/app.conf"

say()  { printf '\033[1;36m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Ejecutá como root (sudo -i)."
command -v apt-get >/dev/null 2>&1 || die "Se requiere Debian o Ubuntu (apt)."

# ---------- sistema operativo y arquitectura ----------
OS_ID=""; OS_VER=""
if [[ -r /etc/os-release ]]; then
    OS_ID="$(. /etc/os-release; echo "${ID:-}")"
    OS_VER="$(. /etc/os-release; echo "${VERSION_ID:-}")"
fi
ARCH="$(uname -m)"
OS_OK=0
case "$OS_ID" in
    ubuntu)
        if [[ "$OS_VER" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
            n=$(( 10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]} ))
            (( n >= 1804 && n <= 2404 )) && OS_OK=1
        fi
        [[ "$ARCH" == x86_64 || "$ARCH" == aarch64 ]] || OS_OK=0 ;;
    debian)
        [[ "$OS_VER" =~ ^[0-9]+$ ]] && (( OS_VER >= 8 && OS_VER <= 12 )) && OS_OK=1
        [[ "$ARCH" == x86_64 ]] || { [[ "$ARCH" == aarch64 && "$OS_OK" == 1 ]] && warn "Debian en ARM64: funciona la mayor parte, sin garantía."; } || OS_OK=0 ;;
esac
if (( ! OS_OK )); then
    if [[ "${MVS_FORCE:-0}" == 1 ]]; then warn "Sistema no soportado ($OS_ID $OS_VER $ARCH): continúo por MVS_FORCE=1."
    else die "Sistema no soportado: ${OS_ID:-?} ${OS_VER:-?} ${ARCH}. Soportados: Ubuntu 18.04–24.04 (x64/ARM64) y Debian 8–12 (x64). Para forzar: MVS_FORCE=1 ./install.sh"; fi
fi
say "Sistema: ${OS_ID} ${OS_VER} (${ARCH})"
[[ -d /run/systemd/system ]] || warn "No se detecta systemd en ejecución: los servicios del panel no van a arrancar."

# ---------- apt (Debian viejo mueve sus repositorios a archive.debian.org) ----------
export DEBIAN_FRONTEND=noninteractive
apt_update() { apt-get update -y -o Acquire::Retries=2 >/dev/null 2>&1; }
if ! apt_update; then
    if [[ "$OS_ID" == debian && "$OS_VER" =~ ^(8|9|10)$ ]]; then
        case "$OS_VER" in 8) c=jessie ;; 9) c=stretch ;; *) c=buster ;; esac
        warn "apt no puede actualizar (Debian $OS_VER terminó su soporte). Se usan los repositorios de archive.debian.org."
        cp -a /etc/apt/sources.list "/etc/apt/sources.list.mvs-backup.$(date +%s)" 2>/dev/null || true
        printf 'deb http://archive.debian.org/debian %s main\ndeb http://archive.debian.org/debian-security %s/updates main\n' "$c" "$c" > /etc/apt/sources.list
        rm -f /etc/apt/sources.list.d/*backports* 2>/dev/null || true
        printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99mvs-archive
        apt_update || warn "apt update sigue fallando; sigo con los paquetes que ya estén instalados."
    else
        warn "apt update falló; sigo con los paquetes que ya estén instalados."
    fi
fi

# ---------- dependencias: una por una, para que un paquete ausente no frene a los demás ----------
say "Instalando dependencias..."
MISSING_REQ=""
for pkg in curl openssl cron procps iproute2 ca-certificates python3 jq; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        apt-get install -y "$pkg" >/dev/null 2>&1 || {
            case "$pkg" in curl|openssl|cron|python3|ca-certificates) MISSING_REQ+=" $pkg" ;; *) warn "No se pudo instalar $pkg (algunas funciones quedarán limitadas)." ;; esac
        }
    fi
done
[[ -z "$MISSING_REQ" ]] || die "Faltan paquetes obligatorios:${MISSING_REQ}. Revisá la conexión y los repositorios de apt."
if ! command -v ss >/dev/null 2>&1; then apt-get install -y iproute2 >/dev/null 2>&1 || warn "No hay 'ss': la detección de puertos usados no funcionará."; fi

# ---------- copia del panel ----------
DEST="/opt/${APP_SLUG}"
DATA="/etc/${APP_SLUG}"
if [[ "$SRC" != "$DEST" ]]; then
    rm -rf "$DEST"; mkdir -p "$DEST"
    cp -a "$SRC/." "$DEST/"; rm -rf "$DEST/.git" "$DEST/tools"
fi
chmod -R go+rX "$DEST"
chmod 755 "$DEST" "$DEST"/bin/*

mkdir -p "$DATA"; chmod 700 "$DATA"
touch "$DATA/users.db" "$DATA/config.conf"; chmod 600 "$DATA/users.db" "$DATA/config.conf"

ln -sf "$DEST/bin/menu" /usr/local/bin/menu
ln -sf "$DEST/bin/menu" "/usr/local/bin/${APP_SLUG}"

cat > "/etc/cron.d/${APP_SLUG}" <<EOF
* * * * * root ${DEST}/bin/limiter
5 0 * * * root ${DEST}/bin/limiter --expire
EOF
chmod 644 "/etc/cron.d/${APP_SLUG}"

echo
say "Listo. Ejecutá:  menu   (o ${APP_SLUG})"
if [[ "$OS_ID" == debian && "$OS_VER" == 8 ]]; then
    warn "Debian 8: el gestor de Xray no está disponible (jq 1.4) y los servicios con puertos < 1024 corren como root."
fi
