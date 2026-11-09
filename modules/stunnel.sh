#!/usr/bin/env bash
# SSL/TLS (stunnel) hacia SSH o Dropbear. shellcheck shell=bash

install_stunnel() {
    local port target tport
    port="$(ask_port "Puerto SSL público" 443)"
    read -rp "Destino: 1) OpenSSH (22)  2) Dropbear [1]: " target
    if [[ "$target" == 2 ]]; then
        tport="$(conf_get DROPBEAR_PORT)"
        [[ -n "$tport" ]] || { err "Instalá Dropbear primero."; return 1; }
    else
        tport=22
    fi

    info "Instalando stunnel..."
    pkg_install stunnel4 openssl || { err "Falló la instalación."; return 1; }

    local pem="${DATA_DIR}/stunnel.pem"
    if [[ ! -s "$pem" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/CN=$(hostname)" -keyout "$pem" -out "$pem.crt" >/dev/null 2>&1
        cat "$pem.crt" >> "$pem"; rm -f "$pem.crt"; chmod 600 "$pem"
    fi

    # Config en nuestro directorio para no chocar con el servicio stunnel4 del sistema.
    cat > "${DATA_DIR}/stunnel.conf" <<EOF
foreground = yes
cert = ${pem}
client = no
[ssh-tls]
accept = ${port}
connect = 127.0.0.1:${tport}
EOF
    cat > "/etc/systemd/system/${APP_SLUG}-stunnel.service" <<EOF
[Unit]
Description=${APP_NAME} SSL tunnel
After=network.target

[Service]
ExecStart=/usr/bin/stunnel4 ${DATA_DIR}/stunnel.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "${APP_SLUG}-stunnel"
    conf_set SSL_PORT "$port"
    ok "SSL activo en el puerto $port -> 127.0.0.1:$tport (certificado autofirmado)."
}

remove_stunnel() {
    systemctl disable --now "${APP_SLUG}-stunnel" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${APP_SLUG}-stunnel.service" "${DATA_DIR}/stunnel.conf"
    systemctl daemon-reload; conf_set SSL_PORT ""
    ok "SSL eliminado."
}
