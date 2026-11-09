#!/usr/bin/env bash
# WireGuard (paquete de la distro). Un archivo .conf por cliente. shellcheck shell=bash

WG_IF="${APP_SLUG}"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
WG_NET="10.9.0"
WG_CLIENTS="${DATA_DIR}/wg"

install_wireguard() {
    local port host iface ipt priv
    port="$(ask_port "Puerto UDP de WireGuard" 51820)"
    host="$(ask_host)"
    info "Instalando wireguard..."
    pkg_install wireguard wireguard-tools iptables qrencode || { err "Falló la instalación."; return 1; }
    iface="$(ip -4 route show default | awk '{print $5; exit}')"
    [[ -n "$iface" ]] || { err "No se detectó la interfaz de red."; return 1; }
    ipt="$(command -v iptables)"

    install -d -m 700 /etc/wireguard "$WG_CLIENTS"
    priv="$(wg genkey)"
    cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_NET}.1/24
ListenPort = ${port}
PrivateKey = ${priv}
PostUp = ${ipt} -t nat -A POSTROUTING -s ${WG_NET}.0/24 -o ${iface} -j MASQUERADE; ${ipt} -A FORWARD -i %i -j ACCEPT; ${ipt} -A FORWARD -o %i -j ACCEPT
PostDown = ${ipt} -t nat -D POSTROUTING -s ${WG_NET}.0/24 -o ${iface} -j MASQUERADE; ${ipt} -D FORWARD -i %i -j ACCEPT; ${ipt} -D FORWARD -o %i -j ACCEPT

EOF
    chmod 600 "$WG_CONF"
    printf 'net.ipv4.ip_forward=1\n' > "/etc/sysctl.d/99-${APP_SLUG}-wg.conf"
    sysctl -q -p "/etc/sysctl.d/99-${APP_SLUG}-wg.conf" >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null
    systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1
    systemctl restart "wg-quick@${WG_IF}"
    conf_set WG_PORT "$port"; conf_set WG_HOST "$host"
    svc_is_active "wg-quick@${WG_IF}" && ok "WireGuard activo en UDP/$port." \
        || warn "No arrancó. Revisá: journalctl -u wg-quick@${WG_IF} -n 30"
    wireguard_add_peer "celular"
}

wg_ready() { [[ -f "$WG_CONF" ]] || { err "WireGuard no está instalado."; return 1; }; }

wireguard_add_peer() { # nombre
    local name="${1:-}" n=2 spub cpriv cpub psk host port out
    wg_ready || return 1
    [[ -n "$name" ]] || read -rp "Nombre del cliente: " name
    [[ "$name" =~ ^[A-Za-z0-9_-]{2,32}$ ]] || { err "Nombre inválido."; return 1; }
    grep -qx "# peer:${name}" "$WG_CONF" && { err "Ya existe ese cliente."; return 1; }
    while grep -q "AllowedIPs = ${WG_NET}\.${n}/32" "$WG_CONF"; do n=$((n + 1)); done
    (( n <= 254 )) || { err "No quedan direcciones libres."; return 1; }

    spub="$(grep -m1 '^PrivateKey' "$WG_CONF" | awk '{print $3}' | wg pubkey)"
    cpriv="$(wg genkey)"; cpub="$(printf '%s' "$cpriv" | wg pubkey)"; psk="$(wg genpsk)"
    host="$(conf_get WG_HOST)"; port="$(conf_get WG_PORT)"

    printf '# peer:%s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s.%s/32\n\n' \
        "$name" "$cpub" "$psk" "$WG_NET" "$n" >> "$WG_CONF"
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") 2>/dev/null || systemctl restart "wg-quick@${WG_IF}"

    out="${WG_CLIENTS}/${name}.conf"
    cat > "$out" <<EOF
[Interface]
PrivateKey = ${cpriv}
Address = ${WG_NET}.${n}/32
DNS = 1.1.1.1

[Peer]
PublicKey = ${spub}
PresharedKey = ${psk}
Endpoint = ${host}:${port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "$out"
    ok "Cliente $name creado: $out"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ansiutf8 < "$out"
}

wireguard_list() {
    wg_ready || return 1
    grep '^# peer:' "$WG_CONF" | sed 's/^# peer:/ - /'
    echo; wg show "$WG_IF" 2>/dev/null | grep -E 'peer|latest handshake|transfer' || true
}

wireguard_show_peer() {
    local name; wg_ready || return 1
    read -rp "Nombre del cliente: " name
    [[ -f "${WG_CLIENTS}/${name}.conf" ]] || { err "No existe."; return 1; }
    cat "${WG_CLIENTS}/${name}.conf"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ansiutf8 < "${WG_CLIENTS}/${name}.conf"
}

wireguard_del_peer() {
    local name tmp; wg_ready || return 1
    read -rp "Cliente a eliminar: " name
    [[ "$name" =~ ^[A-Za-z0-9_-]{2,32}$ ]] && grep -qx "# peer:${name}" "$WG_CONF" || { err "No existe."; return 1; }
    tmp="$(mktemp)"
    awk -v tag="# peer:${name}" '$0==tag{skip=1; next} skip && /^$/ {skip=0; next} !skip{print}' "$WG_CONF" > "$tmp"
    install -m 600 "$tmp" "$WG_CONF"; rm -f "$tmp" "${WG_CLIENTS}/${name}.conf"
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") 2>/dev/null || systemctl restart "wg-quick@${WG_IF}"
    ok "Cliente $name eliminado."
}

wireguard_info() { echo "Puerto: UDP/$(conf_get WG_PORT)  Servidor: $(conf_get WG_HOST)"; wireguard_list; }

remove_wireguard() {
    systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    rm -f "$WG_CONF" "/etc/sysctl.d/99-${APP_SLUG}-wg.conf"; rm -rf "$WG_CLIENTS"
    conf_set WG_PORT ""; conf_set WG_HOST ""
    ok "WireGuard eliminado."
}

wireguard_menu() {
    local op
    while true; do
        title "WireGuard"
        echo " 1) Instalar               4) Ver config / QR de un cliente"
        echo " 2) Agregar cliente        5) Eliminar cliente"
        echo " 3) Listar clientes        6) Quitar WireGuard"
        echo " 0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) install_wireguard; pause ;;
            2) wireguard_add_peer; pause ;;
            3) wireguard_list; pause ;;
            4) wireguard_show_peer; pause ;;
            5) wireguard_del_peer; pause ;;
            6) confirm "¿Quitar WireGuard?" && remove_wireguard; pause ;;
            0) return ;;
        esac
    done
}
