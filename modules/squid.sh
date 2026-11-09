#!/usr/bin/env bash
# Proxy HTTP (squid) restringido: solo permite CONNECT hacia este mismo servidor y
# solo a los puertos de tus servicios. No es un proxy abierto.
# shellcheck shell=bash

install_squid() {
    local port; port="$(ask_port "Puerto del proxy HTTP" 8080)"
    info "Instalando squid..."
    pkg_install squid || { err "Falló la instalación de squid."; return 1; }

    local conf=/etc/squid/squid.conf
    [[ -f "${conf}.orig" ]] || cp -a "$conf" "${conf}.orig"

    local ips k
    local -a ports extra
    ips="$(hostname -I 2>/dev/null) 127.0.0.1"
    read -ra ports <<<"$(sshd_ports)"
    for k in DROPBEAR_PORT DROPBEAR_EXTRA SSL_PORT WSPROXY_PORT WSPRO_PORT; do
        read -ra extra <<<"$(conf_get "$k")"
        ports+=("${extra[@]}")
    done

    cat > "$conf" <<EOF
http_port ${port}
acl self_dst dst ${ips}
acl svc_ports port ${ports[*]}
acl CONNECT method CONNECT
http_access allow CONNECT self_dst svc_ports
http_access deny all
via off
forwarded_for delete
access_log none
cache deny all
EOF
    squid -k parse >/dev/null 2>&1 || { err "Configuración de squid inválida; se restaura la original."; cp -a "${conf}.orig" "$conf"; return 1; }
    svc_enable_restart squid
    conf_set SQUID_PORT "$port"
    ok "Proxy HTTP en el puerto $port (CONNECT solo a: ${ports[*]})."
}

remove_squid() {
    systemctl disable --now squid >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get remove -y squid >/dev/null 2>&1 || true
    conf_set SQUID_PORT ""
    ok "Squid eliminado."
}
