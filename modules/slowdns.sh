#!/usr/bin/env bash
# SlowDNS = túnel sobre DNS con dnstt (https://www.bamsoftware.com/software/dnstt/).
# Se compila localmente desde el repositorio oficial del autor.
# shellcheck shell=bash

DNSTT_USER="${APP_SLUG}-dnstt"
DNSTT_BIN="/usr/local/bin/${APP_SLUG}-dnstt-server"
DNSTT_DIR="/etc/${APP_SLUG}-dnstt"
DNSTT_PORT=5300

install_slowdns() {
    local ns tport choice tmp ipt
    echo "Antes: creá un registro A (ej: ns1.tudominio.com -> IP de este VPS) y un registro NS"
    echo "(ej: dns.tudominio.com -> ns1.tudominio.com). El 'dominio NS' de abajo es el segundo."
    read -rp "Dominio NS (ej: dns.tudominio.com): " ns
    [[ "$ns" =~ ^([a-z0-9-]+\.)+[a-z]{2,}$ ]] || { err "Dominio inválido."; return 1; }
    read -rp "Destino: 1) OpenSSH (22)  2) Dropbear [1]: " choice
    if [[ "$choice" == 2 ]]; then
        tport="$(conf_get DROPBEAR_PORT)"; [[ -n "$tport" ]] || { err "Instalá Dropbear primero."; return 1; }
    else
        tport=22
    fi
    port_in_use "$DNSTT_PORT" && ! systemctl is-active --quiet "${APP_SLUG}-slowdns" \
        && { err "El puerto $DNSTT_PORT ya está en uso."; return 1; }

    info "Instalando go, git e iptables..."
    pkg_install golang-go git iptables || { err "Falló la instalación de dependencias."; return 1; }
    tmp="$(mktemp -d)"
    info "Compilando dnstt-server (puede tardar un minuto)..."
    if ! git clone --depth 1 https://www.bamsoftware.com/git/dnstt.git "$tmp/dnstt" >/dev/null 2>&1 \
       || ! (cd "$tmp/dnstt/dnstt-server" && go build -o "$DNSTT_BIN" . >/dev/null 2>&1); then
        err "No se pudo obtener o compilar dnstt (¿versión de Go muy vieja o sin acceso a la red?)."
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"

    ensure_service_user "$DNSTT_USER"
    install -d -m 750 -o root -g "$DNSTT_USER" "$DNSTT_DIR"
    if [[ ! -s "$DNSTT_DIR/server.key" ]]; then
        "$DNSTT_BIN" -gen-key -privkey-file "$DNSTT_DIR/server.key" -pubkey-file "$DNSTT_DIR/server.pub" >/dev/null
    fi
    chown root:"$DNSTT_USER" "$DNSTT_DIR"/server.*; chmod 640 "$DNSTT_DIR"/server.key; chmod 644 "$DNSTT_DIR/server.pub"

    ipt="$(command -v iptables)"
    cat > "/etc/systemd/system/${APP_SLUG}-slowdns.service" <<EOF
[Unit]
Description=${APP_NAME} SlowDNS (dnstt)
After=network.target

[Service]
User=${DNSTT_USER}
ExecStartPre=-+${ipt} -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${DNSTT_PORT}
ExecStartPre=+${ipt} -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${DNSTT_PORT}
ExecStart=${DNSTT_BIN} -udp :${DNSTT_PORT} -privkey-file ${DNSTT_DIR}/server.key ${ns} 127.0.0.1:${tport}
ExecStopPost=-+${ipt} -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${DNSTT_PORT}
NoNewPrivileges=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "${APP_SLUG}-slowdns"
    conf_set SLOWDNS_NS "$ns"
    ok "SlowDNS activo (UDP 53 -> $DNSTT_PORT -> 127.0.0.1:$tport)."
    warn "Si usás ufw/firewall, abrí UDP 53."
    slowdns_info
}

slowdns_info() {
    local ns; ns="$(conf_get SLOWDNS_NS)"
    [[ -n "$ns" && -f "$DNSTT_DIR/server.pub" ]] || { err "SlowDNS no está instalado."; return 1; }
    echo "Dominio NS:     $ns"
    echo "Clave pública:  $(cat "$DNSTT_DIR/server.pub")"
    echo "El cliente usa dnstt-client con esa clave pública y el dominio NS."
}

remove_slowdns() {
    systemctl disable --now "${APP_SLUG}-slowdns" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${APP_SLUG}-slowdns.service" "$DNSTT_BIN"
    rm -rf "$DNSTT_DIR"; systemctl daemon-reload
    conf_set SLOWDNS_NS ""
    ok "SlowDNS eliminado."
}
