#!/usr/bin/env bash
# Funciones comunes. Se carga con: source "$ROOT/lib/common.sh"
# shellcheck shell=bash
# shellcheck disable=SC2034

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../config/app.conf
source "$ROOT/config/app.conf"

DATA_DIR="${MVS_DATA_DIR:-/etc/${APP_SLUG}}"
CONF="${DATA_DIR}/config.conf"
USERS_DB="${DATA_DIR}/users.db"
USERS_GROUP="${APP_SLUG}-users"
MVS_UNITS=("${APP_SLUG}-dropbear" squid shadowsocks-libev "${APP_SLUG}-udpgw" "${APP_SLUG}-stunnel" "${APP_SLUG}-xray"
    "${APP_SLUG}-slowdns" "${APP_SLUG}-wsproxy" "${APP_SLUG}-wspro" "${APP_SLUG}-hysteria"
    "${APP_SLUG}-checkuser" "${APP_SLUG}-fileserver" "${APP_SLUG}-bot" "${APP_SLUG}-websockify"
    "openvpn-server@${APP_SLUG}" "wg-quick@${APP_SLUG}" fail2ban)

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; C=$'\e[1;36m'; N=$'\e[0m'
else
    R=""; G=""; Y=""; C=""; N=""
fi

info() { printf '%s\n' "${C}[i]${N} $*"; }
ok()   { printf '%s\n' "${G}[ok]${N} $*"; }
warn() { printf '%s\n' "${Y}[!]${N} $*" >&2; }
err()  { printf '%s\n' "${R}[x]${N} $*" >&2; }
die()  { err "$*"; exit 1; }

bar()  { printf '%s\n' "${R}------------------------------------------------${N}"; }
title() { [[ -t 1 ]] && clear; bar; printf '%s\n' "  ${G}${APP_NAME}${N} - $*"; bar; }
pause() { read -rp "Enter para continuar..." _; }

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Ejecutá como root (sudo -i)."; }

ensure_data() {
    mkdir -p "$DATA_DIR"; chmod 700 "$DATA_DIR"
    touch "$USERS_DB" "$CONF"; chmod 600 "$USERS_DB" "$CONF"
}

# Configuración clave=valor en $CONF
conf_get() { grep -m1 "^$1=" "$CONF" 2>/dev/null | cut -d= -f2- || true; }
conf_set() {
    local tmp; tmp="$(mktemp)"
    grep -v "^$1=" "$CONF" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    install -m 600 "$tmp" "$CONF"; rm -f "$tmp"
}

pkg_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
}

# --- compatibilidad con systemd viejo (Debian 8/9, Ubuntu 18.04) ---------------------------------
systemd_ver() { systemctl --version 2>/dev/null | awk 'NR==1{print $2}'; }

# jq >= 1.5 (--argjson, --slurpfile): Debian 8 trae 1.4.
jq_ok() {
    local v; v="$(jq --version 2>/dev/null | sed -E 's/^jq-//')"
    [[ "$v" =~ ^1\.([0-9]+) ]] && (( BASH_REMATCH[1] >= 5 ))
}

# Adapta una unidad recién escrita a lo que entiende el systemd instalado.
unit_compat() { # nombre de la unidad (sin .service)
    local f="/etc/systemd/system/$1.service" v; v="$(systemd_ver)"
    [[ -f "$f" && "$v" =~ ^[0-9]+$ ]] || return 0
    (( v < 240 )) && sed -i 's/^Type=exec$/Type=simple/' "$f"
    if (( v < 231 )); then
        sed -i -E 's/^(ExecStartPre|ExecStopPost)=\+/\1=/; s/^MemoryMax=/MemoryLimit=/' "$f"
        grep -qE '^Exec(StartPre|StopPost)=' "$f" && ! grep -q '^PermissionsStartOnly=' "$f" \
            && sed -i '/^\[Service\]/a PermissionsStartOnly=true' "$f"
    fi
    if (( v < 235 )) && grep -q '^DynamicUser=' "$f"; then
        if grep -q '^User=' "$f"; then sed -i '/^DynamicUser=/d' "$f"
        else sed -i 's/^DynamicUser=.*/User=nobody\nGroup=nogroup/' "$f"; fi
    fi
    if (( v < 229 )) && grep -qE '^AmbientCapabilities=.+' "$f" && grep -q '^User=' "$f"; then
        # sin capacidades ambientales no puede abrir puertos < 1024 como usuario normal: corre como root
        sed -i '/^User=/d; /^AmbientCapabilities=/d; /^CapabilityBoundingSet=/d' "$f"
        warn "systemd $v es muy viejo: $1 corre como root (sin AmbientCapabilities)."
    fi
    return 0
}

svc_enable_restart() {
    unit_compat "$1"
    systemctl daemon-reload
    systemctl enable "$1" >/dev/null 2>&1 || true
    systemctl restart "$1"
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

port_in_use() { ss -ltun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$1$"; }

server_ip()    { hostname -I 2>/dev/null | awk '{print $1}'; }
rand_pass()    { openssl rand -base64 18 | tr -d '/+=' | cut -c1-20; }
ensure_service_user() { id "$1" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$1"; }

# Pregunta IP o dominio público. Imprime el valor.
ask_host() {
    local d h; d="$(server_ip)"
    read -rp "IP o dominio público del servidor [$d]: " h
    printf '%s' "${h:-$d}"
}

# Pregunta un puerto libre. Uso: ask_port "Texto" default -> imprime el puerto
ask_port() {
    local p
    while true; do
        read -rp "$1 [$2]: " p; p="${p:-$2}"
        if ! valid_port "$p"; then warn "Puerto inválido."; continue; fi
        if port_in_use "$p"; then warn "El puerto $p ya está en uso."; continue; fi
        printf '%s' "$p"; return
    done
}

# Pregunta a qué puerto local se reenvía el túnel. Imprime SOLO el puerto (el menú va por stderr).
# Se puede elegir 1-4 o escribir directamente un número de puerto (ej. 8080). El destino es siempre 127.0.0.1.
ask_target() { # [1 = no ofrecer SOCKS PYTHON]
    local no_py="${1:-0}" ssh_p db_p py_p c p
    ssh_p="$(sshd_ports | head -1)"; db_p="$(conf_get DROPBEAR_PORT)"; py_p="$(wsproxy_ports 2>/dev/null | awk '{print $1}')"
    {
        echo "Destino (el tráfico se reenvía a este mismo VPS):"
        echo " 1) OpenSSH     (${ssh_p})"
        echo " 2) Dropbear    (${db_p:-no instalado})"
        [[ "$no_py" == 1 ]] || echo " 3) SOCKS PYTHON (${py_p:-no instalado})"
        echo " 4) Otro: escribir el puerto"
        echo " (también podés escribir el número de puerto directamente, ej. 8080)"
    } >&2
    while true; do
        read -rp "Opción o puerto [1]: " c; c="${c:-1}"; p=""
        case "$c" in
            1) p="$ssh_p" ;;
            2) [[ -n "$db_p" ]] && p="$db_p" || { warn "Dropbear no está instalado."; continue; } ;;
            3) if [[ "$no_py" == 1 ]]; then warn "Opción no disponible aquí."; continue; fi
               [[ -n "$py_p" ]] && p="$py_p" || { warn "SOCKS PYTHON no está instalado."; continue; } ;;
            4) read -rp "Puerto destino: " p
               valid_port "$p" || { warn "Puerto inválido."; continue; } ;;
            *) if valid_port "$c"; then p="$c"; else warn "Opción o puerto inválido."; continue; fi ;;
        esac
        if [[ "$c" == 4 || ( "$c" != [123] && -n "$p" ) ]] && ! port_in_use "$p"; then
            warn "Ahora no hay nada escuchando en el puerto $p (si lo instalás después, no hace falta repetir esto)."
        fi
        printf '%s' "$p"; return 0
    done
}

ensure_false_shell() {
    grep -qx '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells
}


confirm() { local a; read -rp "$1 (s/N): " a; [[ "$a" == [sS] ]]; }
svc_is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
sshd_ports() { local p; p="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')"; echo "${p:-22}"; }
