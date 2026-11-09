#!/usr/bin/env bash
# UDP-CUSTOM (ePro Dev Team, el servidor para HTTP Custom en modo UDP).
# Binario cerrado y ofuscado: se baja SOLO del repositorio oficial http-custom/udp-custom con el SHA-256 fijado aquí.
# A diferencia de HCR, este binario necesita root: crea reglas NAT en iptables (redirige TODOS los puertos UDP a su puerto)
# y ajusta sysctl, así que no se puede dejar sin privilegios ni con la jaula de red. Se limita con systemd.
# shellcheck shell=bash

UDPC_UNIT="${APP_SLUG}-udpcustom"
UDPC_BIN="/usr/local/bin/${APP_SLUG}-udpcustom"
UDPC_DIR="/etc/${APP_SLUG}-udpcustom"
UDPC_CLEAN="/usr/local/sbin/${APP_SLUG}-udpcustom-clean"
UDPC_URL="https://raw.githubusercontent.com/http-custom/udp-custom/main/bin/udp-custom-linux-amd64"
UDPC_PINNED_SHA256="2a1b5584c7947feb5a02e847e09795751024f63ce7137a353c2b9c2a4282d636"
UDPC_MAX_BIN=$((32 * 1024 * 1024))

# Puertos UDP que ya usan otros servicios del panel: se excluyen de la redirección para no romperlos.
udpc_auto_exclude() {
    local k p proto out="53 5300"
    for k in HY_PORT WG_PORT SS_PORT XRAY_UDP_PORTS SLOWDNS_PORT; do
        for p in $(conf_get "$k" | tr ',' ' '); do [[ "$p" =~ ^[0-9]+$ ]] && out+=" $p"; done
    done
    p="$(conf_get OVPN_PORT)"; proto="$(conf_get OVPN_PROTO)"
    [[ "$p" =~ ^[0-9]+$ && "$proto" == udp* ]] && out+=" $p"
    # shellcheck disable=SC2086
    printf '%s\n' $out | sort -un | paste -sd, -
}

# Script que quita las reglas del puerto $1 (por si el proceso muere sin limpiar).
udpc_clean_install() {
    cat > "$UDPC_CLEAN" <<'CLEANEOF'
#!/bin/sh
# Uso: clean PUERTO. Quita las reglas DNAT/INPUT de UDP-CUSTOM de ese puerto (iptables e ip6tables).
P="$1"; case "$P" in ''|*[!0-9]*) exit 0 ;; esac
for T in iptables ip6tables; do
    command -v "$T" >/dev/null 2>&1 || continue
    "$T" -w -t nat -S PREROUTING 2>/dev/null | grep -- "-j DNAT --to-destination :$P\$" | sed 's/^-A/-D/' | while read -r R; do
        # shellcheck disable=SC2086
        "$T" -w -t nat $R 2>/dev/null
    done
    while "$T" -w -D INPUT -p udp --dport "$P" -j ACCEPT 2>/dev/null; do :; done
done
exit 0
CLEANEOF
    chmod 755 "$UDPC_CLEAN"
}

install_udpcustom() {
    local src tmp sum ver port excl extra
    echo "UDP-CUSTOM: servidor UDP del ePro Dev Team (https://github.com/http-custom/udp-custom)."
    warn "Es un binario cerrado y ofuscado: no se puede auditar. Necesita ejecutarse como root porque crea reglas de"
    warn "iptables y cambia sysctl; por eso NO puede ir en la jaula de red de HCR. Se limita con systemd."
    warn "Redirige TODOS los puertos UDP (1-65535) a su puerto, salvo los excluidos. Abrí UDP en el firewall de la nube."
    case "$(uname -m)" in x86_64|amd64) ;; *) err "El binario es solo x86_64 (este sistema es $(uname -m))."; return 1 ;; esac
    pkg_install openssl curl iptables iproute2 procps || return 1

    echo "Origen del binario: Enter = descargar del repo oficial (con SHA-256 fijado) | ruta local o URL https | 0 = cancelar"
    read -rp "Origen [oficial]: " src
    [[ "$src" == 0 ]] && { info "Cancelado."; return 0; }
    tmp="$(mktemp -d)"; chmod 700 "$tmp"
    case "$src" in
        '') curl -fL --proto '=https' --tlsv1.2 --max-filesize "$UDPC_MAX_BIN" -o "$tmp/udp-custom" "$UDPC_URL" \
                || { err "No se pudo descargar."; rm -rf "$tmp"; return 1; } ;;
        https://*) curl -fL --proto '=https' --max-filesize "$UDPC_MAX_BIN" -o "$tmp/udp-custom" "$src" \
                || { err "No se pudo descargar."; rm -rf "$tmp"; return 1; } ;;
        *) [[ -f "$src" && ! -L "$src" ]] || { err "No existe el archivo: $src"; rm -rf "$tmp"; return 1; }
           cp -- "$src" "$tmp/udp-custom" ;;
    esac
    if [[ "$(head -c 4 "$tmp/udp-custom" | od -An -tx1 | tr -d ' \n')" != 7f454c46 ]]; then
        err "El archivo no es un ejecutable de Linux."; rm -rf "$tmp"; return 1
    fi
    sum="$(sha256sum "$tmp/udp-custom" | awk '{print $1}')"
    echo "SHA-256 del binario: $sum"
    if [[ "$sum" == "$UDPC_PINNED_SHA256" ]]; then
        ok "Coincide con la versión revisada (ePro Dev Team, v1.4)."
    else
        warn "NO coincide con la versión revisada (${UDPC_PINNED_SHA256:0:16}...). Puede ser una versión más nueva del autor, o un archivo alterado."
        confirm "¿Continuar de todos modos con este binario?" || { rm -rf "$tmp"; info "Cancelado."; return 0; }
    fi
    chmod 755 "$tmp/udp-custom"; chmod 711 "$tmp"
    # prueba de identidad como usuario sin privilegios (solo --help: no abre puertos ni toca iptables)
    ver="$(cd "$tmp" && runuser -u nobody -- timeout 5 ./udp-custom --help 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | awk '/^Version:/ {print $2; exit}')" || ver=""
    if [[ -z "$ver" ]]; then
        err "El binario no responde como UDP-Custom (--help). Cancelado."; rm -rf "$tmp"; return 1
    fi
    ok "UDP-Custom versión $ver"
    install -m 755 -o root -g root "$tmp/udp-custom" "$UDPC_BIN"; rm -rf "$tmp"

    port="$(ask_port "Puerto de escucha UDP de UDP-CUSTOM" 36712)"
    excl="$(udpc_auto_exclude)"
    echo "Puertos UDP que NO se redirigen (los usan otros servicios): ${excl}"
    read -rp "Puertos UDP extra a excluir, separados por coma (Enter = ninguno): " extra
    extra="${extra//[[:space:]]/}"
    if [[ -n "$extra" ]]; then
        [[ "$extra" =~ ^[0-9]+(,[0-9]+)*$ ]] || { err "Formato inválido (ej. 5000,6000)."; return 1; }
        # shellcheck disable=SC2086
        excl="$(printf '%s\n' ${excl//,/ } ${extra//,/ } | sort -un | paste -sd, -)"
    fi

    install -d -m 750 "$UDPC_DIR"
    cat > "$UDPC_DIR/config.json" <<CFGEOF
{
  "listen": ":${port}",
  "stream_buffer": 33554432,
  "receive_buffer": 83886080,
  "auth": {
    "mode": "passwords"
  }
}
CFGEOF
    chmod 640 "$UDPC_DIR/config.json"
    udpc_clean_install
    cat > "/etc/systemd/system/${UDPC_UNIT}.service" <<UNITEOF
[Unit]
Description=${APP_NAME} UDP-CUSTOM (ePro Dev Team)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=+${UDPC_CLEAN} ${port}
ExecStart=${UDPC_BIN} server -c ${UDPC_DIR}/config.json --exclude ${excl}
ExecStopPost=+${UDPC_CLEAN} ${port}
WorkingDirectory=${UDPC_DIR}
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH CAP_SETUID CAP_SETGID CAP_AUDIT_WRITE CAP_SYS_RESOURCE
ProtectSystem=strict
ReadWritePaths=/run
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes
UMask=0077
LimitCORE=0
Restart=on-failure
RestartSec=3s
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
UNITEOF
    svc_enable_restart "$UDPC_UNIT"; sleep 3
    conf_set UDPC_PORT "$port"; conf_set UDPC_EXCLUDE "$excl"; conf_set UDPC_SHA256 "$sum"
    ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$port/udp" >/dev/null 2>&1
    if svc_is_active "$UDPC_UNIT"; then
        ok "UDP-CUSTOM activo en el puerto UDP $port (excluidos: $excl)."
        warn "En el firewall de la nube (NSG de Azure) abrí UDP 1-65535 (o al menos los puertos que vayas a usar)."
        info "Los usuarios son los usuarios SSH del panel ([35]). En HTTP Custom: modo UDP, IP $(server_ip), usuario y contraseña."
        info "Si instalás luego Hysteria2/WireGuard/SlowDNS, volvé a elegir esta opción (2) para actualizar las exclusiones."
    else
        err "No arrancó. Revisá: journalctl -u ${UDPC_UNIT} -n 30"; return 1
    fi
}

udpcustom_info() {
    echo "Puerto UDP: $(conf_get UDPC_PORT)   redirige 1-65535 excepto: $(conf_get UDPC_EXCLUDE)"
    echo "SHA-256 instalado: $(conf_get UDPC_SHA256)"
    echo "Usuarios: los usuarios SSH del panel. IP: $(server_ip)"
    journalctl -u "$UDPC_UNIT" -n 8 --no-pager 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tail -8
}

remove_udpcustom() {
    local port k; port="$(conf_get UDPC_PORT)"
    systemctl disable --now "$UDPC_UNIT" >/dev/null 2>&1 || true
    [[ -x "$UDPC_CLEAN" && -n "$port" ]] && "$UDPC_CLEAN" "$port"
    if [[ -n "$port" ]] && ufw status 2>/dev/null | grep -q "Status: active"; then ufw delete allow "$port/udp" >/dev/null 2>&1; fi
    rm -f "/etc/systemd/system/${UDPC_UNIT}.service" "$UDPC_BIN" "$UDPC_CLEAN"; rm -rf "$UDPC_DIR"; systemctl daemon-reload
    for k in UDPC_PORT UDPC_EXCLUDE UDPC_SHA256; do conf_set "$k" ""; done
    ok "UDP-CUSTOM eliminado."
}
