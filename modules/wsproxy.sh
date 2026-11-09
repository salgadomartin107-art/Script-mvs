#!/usr/bin/env bash
# Puentes HTTP/WebSocket -> SSH/Dropbear (lib/py/wsproxy.py). Destino fijo y local.
#   wsproxy [3]: modo "raw" (responde 101 y reenvía el flujo crudo, estilo HTTP Injector)
#   wspro   [E]: modo "ws"  (WebSocket real con framing, apto para ir detrás de un CDN)
# shellcheck shell=bash

WSPROXY_STATUS_FILE="/etc/${APP_SLUG}-wsproxy.status"   # legible por el usuario del servicio (DATA_DIR es 700)

_wsproxy_install() { # instancia puerto_por_defecto etiqueta modo clave_conf
    local inst="$1" def="$2" label="$3" mode="$4" key="$5"
    local unit="${APP_SLUG}-${inst}" port tport choice status="Switching Protocols" py
    port="$(ask_port "Puerto público de $label" "$def")"
    read -rp "Destino: 1) OpenSSH ($(sshd_ports | head -1))  2) Dropbear [1]: " choice
    if [[ "$choice" == 2 ]]; then
        tport="$(conf_get DROPBEAR_PORT)"; [[ -n "$tport" ]] || { err "Instalá Dropbear primero."; return 1; }
    else
        tport="$(sshd_ports | head -1)"
    fi

    pkg_install python3 || { err "No se pudo instalar python3."; return 1; }
    py="$(command -v python3)"
    ensure_service_user "$unit"
    cat > "/etc/systemd/system/${unit}.service" <<EOF
[Unit]
Description=${APP_NAME} ${label}
After=network.target

[Service]
User=${unit}
ExecStart=${py} ${ROOT}/lib/py/wsproxy.py --listen 0.0.0.0:${port} --target 127.0.0.1:${tport} --mode ${mode} --status "${status}" --status-file ${WSPROXY_STATUS_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    [[ "$mode" == raw ]] && printf '%s\n' "$status" > "$WSPROXY_STATUS_FILE" && chmod 644 "$WSPROXY_STATUS_FILE"
    svc_enable_restart "$unit"
    conf_set "${key}_PORT" "$port"; conf_set "${key}_TARGET" "$tport"
    [[ "$mode" == raw ]] && conf_set "${key}_STATUS" "$status"
    ok "${label} activo en el puerto $port -> 127.0.0.1:$tport (modo $mode)."
}

_wsproxy_remove() { # instancia clave_conf
    local unit="${APP_SLUG}-$1"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}.service"; systemctl daemon-reload
    conf_set "$2_PORT" ""; conf_set "$2_EXTRA" ""; conf_set "$2_CONNECT" ""; conf_set "$2_TARGET" ""; conf_set "$2_STATUS" ""
    ok "Eliminado."
}

install_wsproxy() { _wsproxy_install wsproxy 80 "proxy Python (raw)" raw WSPROXY; }
remove_wsproxy()  { _wsproxy_remove wsproxy WSPROXY; }
wsproxy_info() {
    local p
    echo "Destino fijo: 127.0.0.1:$(conf_get WSPROXY_TARGET)"
    for p in $(wsproxy_ports); do echo "  Puerto $p -> responde $(wsproxy_mode_label "$p")"; done
    echo "Banner de login: opción 4 de este menú."
    echo "Payload 101: GET / HTTP/1.1[crlf]Host: tu.host[crlf]Upgrade: websocket[crlf][crlf]"
    echo "Payload 200: CONNECT tu.host:puerto HTTP/1.1[crlf]Host: tu.host[crlf][crlf]  (el destino real es siempre el fijo)"
}

install_wspro() { _wsproxy_install wspro 2082 "WS-PRO (WebSocket)" ws WSPRO; }
remove_wspro()  { _wsproxy_remove wspro WSPRO; }
wspro_info() {
    echo "Puerto: $(conf_get WSPRO_PORT) -> 127.0.0.1:$(conf_get WSPRO_TARGET)  (WebSocket real)"
    echo "Sirve para clientes 'SSH sobre WebSocket' y para ponerlo detrás de un CDN."
}

# Puertos que responden "200 Connection established" (el resto responde "101 ...").
wsproxy_is_connect() { [[ " $(conf_get WSPROXY_CONNECT) " == *" $1 "* ]]; }
wsproxy_mode_label() { wsproxy_is_connect "$1" && echo "200 Connection established" || echo "101 Switching Protocols"; }
wsproxy_connect_set() { # puerto on|off
    local p="$1" x keep=""
    for x in $(conf_get WSPROXY_CONNECT); do [[ "$x" == "$p" ]] || keep+="$x "; done
    [[ "$2" == on ]] && keep+="$p "
    conf_set WSPROXY_CONNECT "${keep% }"
}

wsproxy_ports() { printf '%s %s' "$(conf_get WSPROXY_PORT)" "$(conf_get WSPROXY_EXTRA)" | xargs; }

# Reescribe los --listen de la unidad (el primero es el principal) y reinicia.
wsproxy_set_ports() { # "p1 p2 ..."
    local f="/etc/systemd/system/${APP_SLUG}-wsproxy.service" p main extra list="$*" args=""
    for p in $list; do
        if wsproxy_is_connect "$p"; then args+=" --listen 0.0.0.0:${p}=connect"; else args+=" --listen 0.0.0.0:$p"; fi
    done
    sed -i -E "/^ExecStart=/{s/ --listen [0-9.]+:[0-9]+(=[a-z]+)?//g; s|(wsproxy\.py)|\1${args}|}" "$f"
    systemctl daemon-reload; systemctl restart "${APP_SLUG}-wsproxy" 2>/dev/null; sleep 1
    svc_is_active "${APP_SLUG}-wsproxy" || { warn "No arrancó. Revisá: journalctl -u ${APP_SLUG}-wsproxy -n 30"; return 1; }
    main="${list%% *}"; extra="${list#"$main"}"; extra="${extra# }"
    conf_set WSPROXY_PORT "$main"; conf_set WSPROXY_EXTRA "$extra"
}

wsproxy_add_ports() {
    local cur new p added="" mode
    cur="$(wsproxy_ports)"; echo "Puertos actuales: $cur"
    read -rp "Puertos nuevos separados por espacio (ej: 8080 8888): " new
    [[ -n "$new" ]] || return 0
    for p in $new; do
        valid_port "$p" || { err "Puerto inválido: $p"; return 1; }
        [[ " $cur$added " == *" $p "* ]] && { err "El $p ya está en la lista."; return 1; }
        port_in_use "$p" && { err "El puerto $p ya está en uso."; return 1; }
        added+=" $p"
    done
    echo "Respuesta de los puertos nuevos:  1) 101 Switching Protocols   2) 200 Connection established"
    read -rp "Opción [1]: " mode
    for p in $added; do if [[ "$mode" == 2 ]]; then wsproxy_connect_set "$p" on; fi; done
    warn "Se reinicia el proxy: se cortan las conexiones que estén pasando por él."
    confirm "¿Continuar?" || { for p in $added; do wsproxy_connect_set "$p" off; done; return 0; }
    wsproxy_set_ports "$cur$added" || return 1
    for p in $added; do ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$p/tcp" >/dev/null 2>&1; done
    ok "Puertos de PYTHON-WS: $(wsproxy_ports)"
    warn "En la nube, abrí también$added en el firewall del proveedor (NSG de Azure)."
}

wsproxy_del_port() {
    local cur main p x keep=""
    cur="$(wsproxy_ports)"; main="${cur%% *}"; echo "Puertos actuales: $cur   (el principal $main no se puede quitar)"
    read -rp "Puerto a quitar: " p
    [[ " $cur " == *" $p "* ]] || { err "Ese puerto no es de PYTHON-WS."; return 1; }
    [[ "$p" == "$main" ]] && { err "Es el principal. Para cambiarlo, reinstalá."; return 1; }
    for x in $cur; do [[ "$x" == "$p" ]] || keep+="$x "; done
    wsproxy_connect_set "$p" off
    wsproxy_set_ports "${keep% }" && ok "Puerto $p quitado. Quedan: $(wsproxy_ports)"
}

wsproxy_change_mode() {
    local cur p op
    cur="$(wsproxy_ports)"
    for p in $cur; do echo "  $p -> $(wsproxy_mode_label "$p")"; done
    read -rp "Puerto a cambiar: " p
    [[ " $cur " == *" $p "* ]] || { err "Ese puerto no es de PYTHON-WS."; return 1; }
    echo " 1) 101 Switching Protocols   2) 200 Connection established"
    read -rp "Nueva respuesta: " op
    case "$op" in 1) wsproxy_connect_set "$p" off ;; 2) wsproxy_connect_set "$p" on ;; *) return 0 ;; esac
    warn "Se reinicia el proxy: se cortan las conexiones que estén pasando por él."
    confirm "¿Continuar?" || return 0
    wsproxy_set_ports "$cur" && ok "Puerto $p responde ahora: $(wsproxy_mode_label "$p")"
}

wsproxy_menu() {
    local op
    if [[ "$(state_of 3)" != on ]]; then install_wsproxy; pause; return; fi
    while true; do
        title "PYTHON-WS"
        echo " Estado: ${G}ACTIVO${N}"; bar
        echo " 1) Ver datos"
        echo " 2) Reinstalar / cambiar puerto principal"
        echo " 3) Quitar"
        echo " 4) Banner de login SSH (lo que muestra HTTP Custom)"
        echo " 5) Agregar puertos (sin borrar los actuales)"
        echo " 6) Quitar un puerto"
        echo " 7) Cambiar respuesta de un puerto (101 / 200 Connection established)"
        echo " 0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) wsproxy_info; pause ;;
            2) systemctl stop "${APP_SLUG}-wsproxy" 2>/dev/null
               install_wsproxy || systemctl start "${APP_SLUG}-wsproxy" 2>/dev/null; pause ;;
            3) confirm "¿Quitar PYTHON-WS?" && remove_wsproxy; pause; return ;;
            4) banner_menu ;;
            5) wsproxy_add_ports; pause ;;
            6) wsproxy_del_port; pause ;;
            7) wsproxy_change_mode; pause ;;
            0) return ;;
        esac
    done
}
