#!/usr/bin/env bash
# OpenVPN con autenticación por usuario/clave de los usuarios SSH de este panel (PAM).
# PKI propia con easy-rsa. Un único archivo .ovpn para todos los usuarios.
# shellcheck shell=bash

OVPN_SUBNET="10.8.0.0"
OVPN_DIR="/etc/openvpn/server/${APP_SLUG}"
OVPN_CONF="/etc/openvpn/server/${APP_SLUG}.conf"
OVPN_PKI="${DATA_DIR}/pki"
OVPN_FILE="${DATA_DIR}/${APP_SLUG}.ovpn"

install_openvpn() {
    local p proto port host easyrsa plugin iface ipt cc
    read -rp "Protocolo: 1) TCP  2) UDP [1]: " p
    proto=tcp; [[ "$p" == 2 ]] && proto=udp
    port="$(ask_port "Puerto de OpenVPN" 1194)"
    host="$(ask_host)"

    info "Instalando openvpn, easy-rsa e iptables..."
    pkg_install openvpn easy-rsa iptables openssl || { err "Falló la instalación."; return 1; }

    easyrsa=/usr/share/easy-rsa/easyrsa
    [[ -x "$easyrsa" ]] || easyrsa="$(command -v easyrsa || true)"
    [[ -n "$easyrsa" ]] || { err "No se encontró easy-rsa."; return 1; }
    plugin="$(find /usr/lib -name openvpn-plugin-auth-pam.so 2>/dev/null | head -1)"
    [[ -n "$plugin" ]] || { err "No se encontró el plugin PAM de OpenVPN."; return 1; }
    ipt="$(command -v iptables)"
    iface="$(ip -4 route show default | awk '{print $5; exit}')"
    [[ -n "$iface" ]] || { err "No se detectó la interfaz de red."; return 1; }

    export EASYRSA_PKI="$OVPN_PKI" EASYRSA_BATCH=1
    if [[ ! -f "$OVPN_PKI/ca.crt" ]]; then
        info "Generando CA y certificado del servidor..."
        "$easyrsa" init-pki >/dev/null 2>&1
        EASYRSA_REQ_CN="${APP_NAME}-CA" "$easyrsa" --days=3650 build-ca nopass >/dev/null 2>&1
        "$easyrsa" --days=3650 build-server-full server nopass >/dev/null 2>&1
    fi
    [[ -f "$OVPN_PKI/issued/server.crt" ]] || { err "Falló la generación de certificados."; return 1; }

    install -d -m 750 "$OVPN_DIR"
    cp "$OVPN_PKI/ca.crt" "$OVPN_PKI/issued/server.crt" "$OVPN_PKI/private/server.key" "$OVPN_DIR/"
    chmod 600 "$OVPN_DIR/server.key"
    if [[ ! -s "$OVPN_DIR/tc.key" ]]; then
        openvpn --genkey secret "$OVPN_DIR/tc.key" >/dev/null 2>&1 || openvpn --genkey --secret "$OVPN_DIR/tc.key" >/dev/null 2>&1
    fi
    [[ -s "$OVPN_DIR/tc.key" ]] || { err "No se pudo generar la clave tls-crypt."; return 1; }

    # PAM: valida contra los usuarios del sistema (incluye vencimiento de cuenta).
    cat > "/etc/pam.d/${APP_SLUG}-openvpn" <<EOF
auth    required pam_unix.so
account required pam_unix.so
EOF

    cc=""; [[ "$proto" == udp ]] && cc="explicit-exit-notify 1"
    cat > "$OVPN_CONF" <<EOF
port ${port}
proto ${proto}
dev tun
ca ${OVPN_DIR}/ca.crt
cert ${OVPN_DIR}/server.crt
key ${OVPN_DIR}/server.key
dh none
ecdh-curve prime256v1
tls-crypt ${OVPN_DIR}/tc.key
topology subnet
server ${OVPN_SUBNET} 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
tls-version-min 1.2
verify-client-cert none
username-as-common-name
plugin ${plugin} ${APP_SLUG}-openvpn
user nobody
group nogroup
persist-key
persist-tun
verb 3
${cc}
EOF

    printf 'net.ipv4.ip_forward=1\n' > "/etc/sysctl.d/99-${APP_SLUG}-ovpn.conf"
    sysctl -q -p "/etc/sysctl.d/99-${APP_SLUG}-ovpn.conf" >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null

    cat > "/etc/systemd/system/${APP_SLUG}-nat.service" <<EOF
[Unit]
Description=${APP_NAME} NAT para OpenVPN
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ipt} -t nat -A POSTROUTING -s ${OVPN_SUBNET}/24 -o ${iface} -j MASQUERADE
ExecStart=${ipt} -A FORWARD -s ${OVPN_SUBNET}/24 -j ACCEPT
ExecStart=${ipt} -A FORWARD -d ${OVPN_SUBNET}/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ExecStop=-${ipt} -t nat -D POSTROUTING -s ${OVPN_SUBNET}/24 -o ${iface} -j MASQUERADE
ExecStop=-${ipt} -D FORWARD -s ${OVPN_SUBNET}/24 -j ACCEPT
ExecStop=-${ipt} -D FORWARD -d ${OVPN_SUBNET}/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

[Install]
WantedBy=multi-user.target
EOF
    unit_compat "${APP_SLUG}-nat"; systemctl daemon-reload
    systemctl enable "${APP_SLUG}-nat" >/dev/null 2>&1; systemctl restart "${APP_SLUG}-nat"
    systemctl enable "openvpn-server@${APP_SLUG}" >/dev/null 2>&1
    systemctl restart "openvpn-server@${APP_SLUG}"

    conf_set OVPN_PORT "$port"; conf_set OVPN_PROTO "$proto"; conf_set OVPN_HOST "$host"
    openvpn_make_client
    if systemctl is-active --quiet "openvpn-server@${APP_SLUG}"; then
        ok "OpenVPN activo en ${proto^^}/${port}."
    else
        warn "El servicio no arrancó. Revisá: journalctl -u openvpn-server@${APP_SLUG} -n 30"
    fi
}

# Genera el .ovpn que se reparte a los usuarios (se autentican con su usuario/clave).
openvpn_make_client() {
    local proto port host
    proto="$(conf_get OVPN_PROTO)"; port="$(conf_get OVPN_PORT)"; host="$(conf_get OVPN_HOST)"
    [[ -n "$port" && -f "$OVPN_DIR/ca.crt" ]] || { err "OpenVPN no está instalado."; return 1; }
    {
        cat <<EOF
client
dev tun
proto ${proto}
remote ${host} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-user-pass
cipher AES-256-GCM
auth SHA256
verb 3
<ca>
$(cat "$OVPN_DIR/ca.crt")
</ca>
<tls-crypt>
$(cat "$OVPN_DIR/tc.key")
</tls-crypt>
EOF
    } > "$OVPN_FILE"
    chmod 600 "$OVPN_FILE"
    ok "Archivo de cliente: $OVPN_FILE (los usuarios entran con su usuario y clave SSH)."
}

remove_openvpn() {
    systemctl disable --now "openvpn-server@${APP_SLUG}" "${APP_SLUG}-nat" >/dev/null 2>&1 || true
    rm -f "$OVPN_CONF" "/etc/systemd/system/${APP_SLUG}-nat.service" "/etc/pam.d/${APP_SLUG}-openvpn" \
          "/etc/sysctl.d/99-${APP_SLUG}-ovpn.conf" "$OVPN_FILE"
    rm -rf "$OVPN_DIR"; systemctl daemon-reload
    for k in OVPN_PORT OVPN_PROTO OVPN_HOST; do conf_set "$k" ""; done
    ok "OpenVPN eliminado (la PKI se conserva en ${OVPN_PKI})."
}
