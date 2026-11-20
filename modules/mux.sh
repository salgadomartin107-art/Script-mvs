#!/usr/bin/env bash
# Multiplexor de puerto (tipo sslh) [21]: un solo puerto público (normalmente 443) reparte cada conexión según lo que llega:
# TLS -> SSL/TLS (stunnel), "SSH-" -> SSH/Dropbear, HTTP/payload -> WS-PRO o PYTHON-WS. (lib/py/muxfront.py)
# shellcheck shell=bash

# Si el multiplexor movió el SSL a un puerto interno, lo devuelve al público (sirve al reconfigurar y al quitar).
mux_restore_ssl() {
    local int pub conf="${DATA_DIR}/stunnel.conf"
    int="$(conf_get SSL_INTERNAL)"; [[ -n "$int" ]] || return 0
    pub="$(conf_get SSL_PORT)"
    if [[ -f "$conf" && -n "$pub" ]]; then
        sed -i -E "s|^accept = .*|accept = ${pub}|" "$conf"
        svc_is_active "${APP_SLUG}-stunnel" && systemctl restart "${APP_SLUG}-stunnel" 2>/dev/null
    fi
    conf_set SSL_INTERNAL ""
}

mux_pick_http() { # imprime el puerto local del destino HTTP/payload (o nada)
    local wp py c p
    wp="$(conf_get WSPRO_PORT)"; py="$(wsproxy_ports 2>/dev/null | awk '{print $1}')"
    {
        echo "Destino para HTTP / payload (WebSocket, 101, CONNECT):"
        echo " 1) WS-PRO       (${wp:-no instalado})"
        echo " 2) SOCKS PYTHON (${py:-no instalado})"
        echo " 3) Otro: escribir el puerto   (también podés escribir el número directamente)"
    } >&2
    while true; do
        read -rp "Opción o puerto [1]: " c; c="${c:-1}"; p=""
        case "$c" in
            1) p="$wp" ;; 2) p="$py" ;;
            3) read -rp "Puerto: " p ;;
            *) p="$c" ;;
        esac
        if [[ -z "$p" ]]; then warn "Ese servicio no está instalado."; continue; fi
        valid_port "$p" || { warn "Puerto inválido."; continue; }
        printf '%s' "$p"; return
    done
}

install_mux() {
    local port tls="" http="" ssh="" moved=0 sslint py unit="${APP_SLUG}-mux" conf="${DATA_DIR}/stunnel.conf"
    while true; do
        read -rp "Puerto público del multiplexor [443]: " port; port="${port:-443}"
        valid_port "$port" || { warn "Puerto inválido."; continue; }
        if port_in_use "$port"; then
            if [[ "$(conf_get SSL_PORT)" == "$port" && -z "$(conf_get SSL_INTERNAL)" ]] && svc_is_active "${APP_SLUG}-stunnel"; then
                echo "El puerto $port lo usa SSL/TLS [5]."
                confirm "¿Lo muevo a un puerto interno (solo local) para que el multiplexor lo reparta?" || continue
                moved=1; break
            fi
            warn "El puerto $port ya está en uso por otro servicio: movelo o quitalo primero."; continue
        fi
        break
    done

    # --- destino TLS ---
    if (( moved )); then
        sslint=4443; while port_in_use "$sslint"; do sslint=$((sslint + 1)); done
        sed -i -E "s|^accept = .*|accept = 127.0.0.1:${sslint}|" "$conf"
        systemctl restart "${APP_SLUG}-stunnel" 2>/dev/null; sleep 1
        conf_set SSL_INTERNAL "$sslint"; tls="127.0.0.1:${sslint}"
        info "SSL/TLS pasó al puerto interno $sslint (el público sigue siendo $port, ahora por el multiplexor)."
    elif [[ -n "$(conf_get SSL_INTERNAL)" ]]; then
        tls="127.0.0.1:$(conf_get SSL_INTERNAL)"
    elif svc_is_active "${APP_SLUG}-stunnel" && [[ -n "$(conf_get SSL_PORT)" ]]; then
        tls="127.0.0.1:$(conf_get SSL_PORT)"
    else
        warn "SSL/TLS [5] no está instalado: las conexiones TLS se descartarán. Instalalo y reconfigurá el multiplexor si lo querés."
    fi

    # --- destinos HTTP y SSH ---
    http="$(mux_pick_http)"
    ssh="$(ask_target 1)" || { mux_restore_ssl; return 1; }

    pkg_install python3 || { err "No se pudo instalar python3."; mux_restore_ssl; return 1; }
    py="$(command -v python3)"
    ensure_service_user "$unit"
    cat > "/etc/systemd/system/${unit}.service" <<EOF2
[Unit]
Description=${APP_NAME} multiplexor de puerto
After=network.target ${APP_SLUG}-stunnel.service

[Service]
User=${unit}
ExecStart=${py} ${ROOT}/lib/py/muxfront.py --listen 0.0.0.0:${port}${tls:+ --tls $tls}${http:+ --http 127.0.0.1:$http} --ssh 127.0.0.1:${ssh}
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF2
    svc_enable_restart "$unit"; sleep 1
    if ! svc_is_active "$unit"; then
        err "El multiplexor no arrancó. Revisá: journalctl -u $unit -n 30"
        rm -f "/etc/systemd/system/${unit}.service"; systemctl daemon-reload; mux_restore_ssl; return 1
    fi
    conf_set MUX_PORT "$port"; conf_set MUX_TLS "${tls##*:}"; conf_set MUX_HTTP "$http"; conf_set MUX_SSH "$ssh"
    ok "Multiplexor activo en el puerto $port."
    ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$port/tcp" >/dev/null 2>&1
    warn "En la nube, abrí el puerto $port en el firewall del proveedor (NSG de Azure)."
}

mux_info() {
    echo "Puerto público: $(conf_get MUX_PORT)"
    echo "  TLS (SNI)        -> $([[ -n "$(conf_get MUX_TLS)" ]] && echo "127.0.0.1:$(conf_get MUX_TLS)" || echo "sin destino")"
    echo "  HTTP / payload   -> 127.0.0.1:$(conf_get MUX_HTTP)"
    echo "  SSH directo      -> 127.0.0.1:$(conf_get MUX_SSH)"
    echo "Un cliente que no manda nada en 2 s se trata como SSH (espera el banner del servidor)."
}

remove_mux() {
    local unit="${APP_SLUG}-mux"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}.service"; systemctl daemon-reload
    mux_restore_ssl
    conf_set MUX_PORT ""; conf_set MUX_TLS ""; conf_set MUX_HTTP ""; conf_set MUX_SSH ""
    ok "Multiplexor eliminado."
}
