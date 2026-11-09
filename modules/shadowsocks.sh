#!/usr/bin/env bash
# Shadowsocks (shadowsocks-libev, paquete de la distro). shellcheck shell=bash

SS_CONF=/etc/shadowsocks-libev/config.json
SS_METHOD="chacha20-ietf-poly1305"

install_shadowsocks() {
    local port pass custom host
    port="$(ask_port "Puerto de Shadowsocks" 8388)"
    read -rp "Clave [aleatoria]: " custom
    pass="${custom:-$(rand_pass)}"
    [[ "$pass" =~ ^[A-Za-z0-9._~-]{6,64}$ ]] || { err "Clave inválida (6-64 caracteres: letras, números . _ ~ -)."; return 1; }
    host="$(ask_host)"

    info "Instalando shadowsocks-libev..."
    pkg_install shadowsocks-libev || { err "Tu distribución no trae shadowsocks-libev."; return 1; }

    cat > "$SS_CONF" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${port},
    "password": "${pass}",
    "timeout": 300,
    "method": "${SS_METHOD}",
    "mode": "tcp_and_udp"
}
EOF
    chown root:nogroup "$SS_CONF"; chmod 640 "$SS_CONF"
    svc_enable_restart shadowsocks-libev
    conf_set SS_PORT "$port"; conf_set SS_HOST "$host"; conf_set SS_PASS "$pass"
    ok "Shadowsocks activo en el puerto $port."
    shadowsocks_info
}

shadowsocks_info() {
    local port host pass b64
    port="$(conf_get SS_PORT)"; host="$(conf_get SS_HOST)"; pass="$(conf_get SS_PASS)"
    [[ -n "$port" ]] || { err "Shadowsocks no está instalado."; return 1; }
    b64="$(printf '%s' "${SS_METHOD}:${pass}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    echo "Servidor: $host   Puerto: $port"
    echo "Método:   $SS_METHOD"
    echo "Clave:    $pass"
    echo "URI:      ss://${b64}@${host}:${port}#${APP_NAME}"
}

remove_shadowsocks() {
    systemctl disable --now shadowsocks-libev >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get remove -y shadowsocks-libev >/dev/null 2>&1 || true
    for k in SS_PORT SS_HOST SS_PASS; do conf_set "$k" ""; done
    ok "Shadowsocks eliminado."
}
