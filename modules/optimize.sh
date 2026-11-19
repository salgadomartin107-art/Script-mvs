#!/usr/bin/env bash
# OPTIMIZAR [Q]: tres ajustes que se activan y desactivan de a uno.
#   1 Ping WebSocket cada 25 s   (wstunnel, WS-PRO y Websockify)
#   2 Nginx sin buffering        (proxy WebSocket delante de un servicio local)
#   3 Websockify                 (WebSocket -> TCP hacia un puerto local)
# Todo lo que se instala con apt se instala SIN arrancar solo (policy-rc.d), se valida la configuración antes de
# arrancar y se puede volver atrás desde el mismo menú. Al desactivar solo se quita lo que instaló el panel.
# shellcheck shell=bash

OPT_PING_SECS=25
OPT_NGX_CONF="/etc/nginx/conf.d/${APP_SLUG}-ws.conf"
WSFY_UNIT="${APP_SLUG}-websockify"
WSFY_USER="${APP_SLUG}-websockify"

# ---------------------------------------------------------------------------------------------------------------
# utilidades
# ---------------------------------------------------------------------------------------------------------------
# apt sin que el paquete arranque su servicio (nginx tomaría el puerto 80, unbound el 53...).
opt_pkg_nostart() {
    local pol=/usr/sbin/policy-rc.d had=0 rc
    if [[ -e "$pol" ]]; then had=1; cp -a "$pol" "$pol.${APP_SLUG}bak"; fi
    printf '#!/bin/sh\nexit 101\n' > "$pol"; chmod 755 "$pol"
    pkg_install "$@"; rc=$?
    if (( had )); then mv -f "$pol.${APP_SLUG}bak" "$pol"; else rm -f "$pol"; fi
    return $rc
}

opt_pkg_present() { dpkg -s "$1" >/dev/null 2>&1; }

# Pregunta a qué servicio WebSocket local reenviar. Imprime SOLO el puerto (el menú va por stderr).
opt_ask_ws_upstream() {
    local c p wpro wst wsfy
    wpro="$(conf_get WSPRO_PORT)"; wst="$(conf_get WST_PORT)"; wsfy="$(conf_get WSFY_PORT)"
    {
        echo "¿Qué servicio local querés poner detrás de Nginx?"
        echo " 1) WS-PRO      (${wpro:-no instalado})"
        echo " 2) WSTUNNEL    (${wst:-no instalado})"
        echo " 3) Websockify  (${wsfy:-no activado})"
        echo " 4) Otro: escribir el puerto (también podés escribir el número directamente)"
    } >&2
    while true; do
        read -rp "Opción o puerto: " c || return 1
        p=""
        case "$c" in
            1) p="$wpro" ;; 2) p="$wst" ;; 3) p="$wsfy" ;;
            4) read -rp "Puerto local: " p || return 1 ;;
            *) p="$c" ;;
        esac
        if valid_port "$p"; then printf '%s' "$p"; return 0; fi
        warn "Opción inválida o servicio no instalado."
    done
}

# ---------------------------------------------------------------------------------------------------------------
# 1. Ping WebSocket cada 25 s
# ---------------------------------------------------------------------------------------------------------------
opt_on_wsping() { [[ -n "$(conf_get WS_PING)" ]]; }

# Deja el ping en las unidades que ya existen (idempotente: quita la opción y la vuelve a poner si está activado).
opt_ws_ping_sync() {
    local n f; n="$(conf_get WS_PING)"
    f="/etc/systemd/system/${WST_UNIT:-${APP_SLUG}-wstunnel}.service"
    if [[ -f "$f" ]]; then
        sed -i -E '/^ExecStart=/s/ --websocket-ping-frequency [^ ]+//' "$f"
        [[ -n "$n" ]] && sed -i -E "/^ExecStart=/s| --no-color| --websocket-ping-frequency ${n}s --no-color|" "$f"
    fi
    f="/etc/systemd/system/${APP_SLUG}-wspro.service"
    if [[ -f "$f" ]]; then
        sed -i -E '/^ExecStart=/s/ --ping [0-9]+//' "$f"
        [[ -n "$n" ]] && sed -i -E "/^ExecStart=/s|\$| --ping ${n}|" "$f"
    fi
    f="/etc/systemd/system/${WSFY_UNIT}.service"
    if [[ -f "$f" ]]; then
        sed -i -E '/^ExecStart=/s/ --heartbeat=[0-9]+//' "$f"
        [[ -n "$n" ]] && sed -i -E "/^ExecStart=/s|(/websockify)|\\1 --heartbeat=${n}|" "$f"
    fi
    return 0
}

opt_ws_ping_apply() { # reinicia lo que esté activo para que tome el cambio
    local u done_list=""
    opt_ws_ping_sync
    systemctl daemon-reload
    for u in "${WST_UNIT:-${APP_SLUG}-wstunnel}" "${APP_SLUG}-wspro" "$WSFY_UNIT"; do
        [[ -f "/etc/systemd/system/${u}.service" ]] || continue
        if svc_is_active "$u"; then systemctl restart "$u" 2>/dev/null; fi
        done_list+=" $u"
    done
    if [[ -n "$done_list" ]]; then ok "Aplicado a:${done_list}."
    else info "No hay WSTUNNEL, WS-PRO ni Websockify instalados todavía: el ping se pondrá solo cuando los instales."; fi
}

opt_wsping_on() {
    warn "Se reinician WSTUNNEL, WS-PRO y Websockify si están activos (las conexiones abiertas se cortan un instante)."
    confirm "¿Continuar?" || return 0
    conf_set WS_PING "$OPT_PING_SECS"
    opt_ws_ping_apply
    ok "Ping WebSocket cada ${OPT_PING_SECS} s activado."
}
opt_wsping_off() {
    conf_set WS_PING ""
    opt_ws_ping_apply
    ok "Ping WebSocket desactivado."
}
opt_wsping_info() {
    echo "Ping WebSocket del servidor cada $(conf_get WS_PING) s en: WSTUNNEL, WS-PRO y Websockify."
    echo "(Nginx no genera pings; solo deja pasar los de los servicios de atrás.)"
}
opt_wsping_desc() {
    echo "El servidor envía un ping WebSocket cada ${OPT_PING_SECS} s. Evita que CDN (Cloudflare), NAT o la red móvil"
    echo "corten conexiones quietas. Se aplica a WSTUNNEL, WS-PRO y Websockify."
}

# ---------------------------------------------------------------------------------------------------------------
# 2. Nginx sin buffering
# ---------------------------------------------------------------------------------------------------------------
opt_on_ngx() { [[ -f "$OPT_NGX_CONF" ]]; }

opt_ngx_write() { # puerto_publico puerto_destino
    local port="$1" up="$2" v6=""
    [[ -e /proc/net/if_inet6 ]] && v6="    listen [::]:${port};"
    cat > "$OPT_NGX_CONF" <<NGXEOF
# ${APP_NAME}: proxy WebSocket sin buffering hacia 127.0.0.1:${up}
map \$http_upgrade \$${APP_SLUG}_ws_conn {
    default upgrade;
    ''      close;
}

server {
    listen ${port};
${v6}
    server_name _;
    access_log off;

    location / {
        proxy_pass http://127.0.0.1:${up};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$${APP_SLUG}_ws_conn;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        tcp_nodelay on;
        proxy_connect_timeout 10s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGXEOF
    chmod 644 "$OPT_NGX_CONF"
}

opt_ngx_on() {
    local port up by_us=0 out
    echo "Nginx quedará escuchando en un puerto público y reenviará todo (incluido el Upgrade a WebSocket) a un"
    echo "servicio de este VPS con proxy_buffering y proxy_request_buffering apagados."
    up="$(opt_ask_ws_upstream)" || return 1
    port="$(ask_port "Puerto público de Nginx" 8080)"
    [[ "$port" == "$up" ]] && { err "El puerto público y el de destino no pueden ser el mismo."; return 1; }

    if ! command -v nginx >/dev/null 2>&1; then
        info "Instalando nginx (sin arrancarlo)..."
        opt_pkg_nostart nginx-light || opt_pkg_nostart nginx || { err "No se pudo instalar nginx."; return 1; }
        by_us=1
        # nginx recién instalado por el panel: su sitio de ejemplo escucha en el 80 y chocaría con otros servicios
        rm -f /etc/nginx/sites-enabled/default
    fi
    opt_ngx_write "$port" "$up"
    if ! out="$(nginx -t 2>&1)"; then
        err "nginx rechazó la configuración:"; echo "$out" | tail -5 >&2
        rm -f "$OPT_NGX_CONF"
        (( by_us )) && DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx-light nginx nginx-common >/dev/null 2>&1
        return 1
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx 2>/dev/null; sleep 1
    if ! svc_is_active nginx; then
        err "nginx no arrancó. Revisá: journalctl -u nginx -n 30"
        rm -f "$OPT_NGX_CONF"; (( by_us )) && systemctl disable --now nginx >/dev/null 2>&1
        return 1
    fi
    conf_set NGX_PORT "$port"; conf_set NGX_UPSTREAM "$up"
    (( by_us )) && conf_set NGX_BY_US 1
    ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$port/tcp" >/dev/null 2>&1
    ok "Nginx activo: :${port} -> 127.0.0.1:${up} (sin buffering)."
    warn "Abrí el puerto TCP ${port} en el firewall de la nube."
    info "Sirve para clientes WebSocket reales (con Upgrade). Un payload que no pide Upgrade se corta tras la respuesta: para eso usá el puerto directo de WS-PRO/WSTUNNEL."
}

opt_ngx_off() {
    local port; port="$(conf_get NGX_PORT)"
    rm -f "$OPT_NGX_CONF"
    if [[ "$(conf_get NGX_BY_US)" == 1 ]]; then
        systemctl disable --now nginx >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx-light nginx nginx-common >/dev/null 2>&1 || true
    elif command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    fi
    [[ -n "$port" ]] && ufw status 2>/dev/null | grep -q "Status: active" && ufw delete allow "$port/tcp" >/dev/null 2>&1
    conf_set NGX_PORT ""; conf_set NGX_UPSTREAM ""; conf_set NGX_BY_US ""
    ok "Nginx sin buffering desactivado."
}
opt_ngx_info() {
    echo "Nginx: :$(conf_get NGX_PORT) -> 127.0.0.1:$(conf_get NGX_UPSTREAM)   (proxy_buffering off, proxy_request_buffering off)"
    echo "Configuración: $OPT_NGX_CONF"
    svc_is_active nginx && echo "Servicio nginx: activo" || echo "Servicio nginx: DETENIDO (journalctl -u nginx -n 30)"
}
opt_ngx_desc() {
    echo "Pone Nginx como proxy WebSocket con el buffering apagado (los datos pasan al instante, menos latencia)."
    echo "Reenvía a un servicio local que elijas (WS-PRO, WSTUNNEL, Websockify u otro puerto)."
}
# ---------------------------------------------------------------------------------------------------------------
# 6. Websockify
# ---------------------------------------------------------------------------------------------------------------
opt_on_wsfy() { [[ -f "/etc/systemd/system/${WSFY_UNIT}.service" ]]; }

opt_wsfy_on() {
    local port tport bin cap="" hb="" by_us=0
    echo "Websockify: acepta WebSocket (RFC 6455, con Sec-WebSocket-Key) y lo reenvía como TCP a UN puerto local."
    port="$(ask_port "Puerto público de Websockify" 8081)"
    tport="$(ask_target)" || return 1
    if ! command -v websockify >/dev/null 2>&1; then
        info "Instalando websockify (sin arrancarlo)..."
        opt_pkg_nostart websockify || opt_pkg_nostart python3-websockify || { err "No se pudo instalar websockify desde los repositorios de este sistema."; return 1; }
        by_us=1
    fi
    bin="$(command -v websockify)" || { err "No se encontró el binario de websockify."; return 1; }
    ensure_service_user "$WSFY_USER"
    (( port < 1024 )) && cap="CAP_NET_BIND_SERVICE"
    [[ -n "$(conf_get WS_PING)" ]] && hb=" --heartbeat=$(conf_get WS_PING)"
    cat > "/etc/systemd/system/${WSFY_UNIT}.service" <<WSFYEOF
[Unit]
Description=${APP_NAME} Websockify (WebSocket a TCP)
After=network.target

[Service]
User=${WSFY_USER}
ExecStart=${bin}${hb} 0.0.0.0:${port} 127.0.0.1:${tport}
AmbientCapabilities=${cap}
CapabilityBoundingSet=${cap}
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
UMask=0077
LimitCORE=0
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
WSFYEOF
    svc_enable_restart "$WSFY_UNIT"; sleep 2
    if ! svc_is_active "$WSFY_UNIT"; then
        err "Websockify no arrancó. Revisá: journalctl -u ${WSFY_UNIT} -n 30"
        systemctl disable --now "$WSFY_UNIT" >/dev/null 2>&1; rm -f "/etc/systemd/system/${WSFY_UNIT}.service"
        return 1
    fi
    conf_set WSFY_PORT "$port"; conf_set WSFY_TARGET "$tport"; (( by_us )) && conf_set WSFY_BY_US 1
    ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$port/tcp" >/dev/null 2>&1
    ok "Websockify activo: ws://0.0.0.0:${port} -> 127.0.0.1:${tport}${hb:+ (heartbeat $(conf_get WS_PING) s)}"
    warn "Abrí el puerto TCP ${port} en el firewall de la nube."
}
opt_wsfy_off() {
    local port; port="$(conf_get WSFY_PORT)"
    systemctl disable --now "$WSFY_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${WSFY_UNIT}.service"; systemctl daemon-reload
    [[ -n "$port" ]] && ufw status 2>/dev/null | grep -q "Status: active" && ufw delete allow "$port/tcp" >/dev/null 2>&1
    id "$WSFY_USER" >/dev/null 2>&1 && userdel "$WSFY_USER" >/dev/null 2>&1
    if [[ "$(conf_get WSFY_BY_US)" == 1 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y websockify python3-websockify >/dev/null 2>&1 || true
    fi
    conf_set WSFY_PORT ""; conf_set WSFY_TARGET ""; conf_set WSFY_BY_US ""
    ok "Websockify desactivado."
}
opt_wsfy_info() {
    echo "Websockify: ws://0.0.0.0:$(conf_get WSFY_PORT) -> 127.0.0.1:$(conf_get WSFY_TARGET)"
    svc_is_active "$WSFY_UNIT" && echo "Servicio: activo" || echo "Servicio: DETENIDO (journalctl -u ${WSFY_UNIT} -n 30)"
    echo "Pide un WebSocket real (con Sec-WebSocket-Key). Para payloads sueltos de HTTP Custom usá WS-PRO o el frente 101 de WSTUNNEL."
}
opt_wsfy_desc() {
    echo "Websockify convierte un WebSocket en una conexión TCP a un puerto de este VPS (SSH, Dropbear...)."
    echo "Corre sin privilegios y con un único destino fijo."
}

# ---------------------------------------------------------------------------------------------------------------
# Limpieza de lo que dejó la v1.15 (SSH keepalive, monitoreo de CPU/RAM y Unbound ya no están en el menú)
# ---------------------------------------------------------------------------------------------------------------
opt_legacy_present() {
    [[ -n "$(conf_get SSH_KEEPALIVE)" || -n "$(conf_get UNB_MODE)" || -n "$(conf_get UNB_SYSDNS)" ]] \
        || [[ -f "/etc/cron.d/${APP_SLUG}-stats" || -d "/var/lib/${APP_SLUG}-stats" ]] \
        || [[ -f "/etc/ssh/sshd_config.d/92-${APP_SLUG}-keepalive.conf" || -f "/etc/unbound/unbound.conf.d/${APP_SLUG}.conf" ]]
}

opt_legacy_cleanup() {
    local cfg=/etc/ssh/sshd_config f how unbound_conf="/etc/unbound/unbound.conf.d/${APP_SLUG}.conf"
    # monitoreo
    rm -f "/etc/cron.d/${APP_SLUG}-stats"; rm -rf "/var/lib/${APP_SLUG}-stats"
    # SSH keepalive (OpenSSH + -K de Dropbear)
    rm -f "/etc/ssh/sshd_config.d/92-${APP_SLUG}-keepalive.conf"
    if [[ -f "$cfg" ]] && grep -qF "# >>> ${APP_SLUG} keepalive >>>" "$cfg"; then
        sed -i "\\|^# >>> ${APP_SLUG} keepalive >>>\$|,\\|^# <<< ${APP_SLUG} keepalive <<<\$|d" "$cfg"
    fi
    if [[ -n "$(conf_get SSH_KEEPALIVE)" ]] && command -v sshd >/dev/null 2>&1; then
        if sshd -t 2>/dev/null; then ssh_reload; else warn "sshd no valida su configuración: revisá /etc/ssh/sshd_config."; fi
    fi
    f="/etc/systemd/system/${APP_SLUG}-dropbear.service"
    if [[ -f "$f" ]] && grep -qE '^ExecStart=.* -K [0-9]+' "$f"; then
        sed -i -E '/^ExecStart=/s/ -K [0-9]+//' "$f"; systemctl daemon-reload
        svc_is_active "${APP_SLUG}-dropbear" && systemctl restart "${APP_SLUG}-dropbear" 2>/dev/null
    fi
    # Unbound: se devuelve el DNS del sistema y se quita lo que puso el panel
    how="$(conf_get UNB_SYSDNS)"
    if [[ "$how" == resolved || -f "/etc/systemd/resolved.conf.d/zz-${APP_SLUG}-unbound.conf" ]]; then
        rm -f "/etc/systemd/resolved.conf.d/zz-${APP_SLUG}-unbound.conf"; systemctl restart systemd-resolved 2>/dev/null
    fi
    if [[ "$how" == resolvconf && -f "/etc/${APP_SLUG}-resolv.conf.bak" ]]; then
        cat "/etc/${APP_SLUG}-resolv.conf.bak" > /etc/resolv.conf; rm -f "/etc/${APP_SLUG}-resolv.conf.bak"
    fi
    if [[ -f "$unbound_conf" ]]; then
        systemctl disable --now unbound >/dev/null 2>&1 || true
        rm -f "$unbound_conf"
        [[ -f /etc/unbound/unbound.conf ]] && sed -i "\\|^# >>> ${APP_SLUG} unbound >>>\$|,\\|^# <<< ${APP_SLUG} unbound <<<\$|d" /etc/unbound/unbound.conf
        if [[ "$(conf_get UNB_BY_US)" == 1 ]]; then DEBIAN_FRONTEND=noninteractive apt-get purge -y unbound >/dev/null 2>&1 || true; fi
    fi
    local k; for k in SSH_KEEPALIVE UNB_MODE UNB_SYSDNS UNB_BY_US; do conf_set "$k" ""; done
    return 0
}

# ---------------------------------------------------------------------------------------------------------------
# menú
# ---------------------------------------------------------------------------------------------------------------
opt_tag() { if "$1"; then printf '%s[ON ]%s' "$G" "$N"; else printf '%s[OFF]%s' "$R" "$N"; fi; }

opt_item() { # etiqueta fn_estado fn_on fn_off fn_info fn_desc
    local label="$1" st="$2" on="$3" off="$4" info="$5" desc="$6" a
    title "$label"
    if "$st"; then
        echo " Estado: ${G}ACTIVADO${N}"; bar
        "$info"; bar
        echo " 1) Desactivar"; echo " 0) Volver"
        read -rp " Opción: " a || return
        [[ "$a" == 1 ]] && { "$off"; pause; }
    else
        echo " Estado: ${R}DESACTIVADO${N}"; bar
        "$desc"; bar
        if confirm "¿Activar?"; then "$on"; pause; fi
    fi
}

optimize_menu() {
    local op
    if opt_legacy_present; then
        info "Se quitan los ajustes que ya no existen (SSH keepalive, monitoreo, Unbound) y se devuelve el sistema a como estaba..."
        opt_legacy_cleanup
    fi
    while true; do
        title "OPTIMIZAR"
        printf ' 1) Ping WebSocket cada %s s        %s\n' "$OPT_PING_SECS" "$(opt_tag opt_on_wsping)"
        printf ' 2) Nginx sin buffering               %s\n' "$(opt_tag opt_on_ngx)"
        printf ' 3) Websockify                        %s\n' "$(opt_tag opt_on_wsfy)"
        echo " 0) Volver"
        bar; read -rp " Opción: " op || return
        case "$op" in
            1) opt_item "PING WEBSOCKET ${OPT_PING_SECS} s" opt_on_wsping opt_wsping_on opt_wsping_off opt_wsping_info opt_wsping_desc ;;
            2) opt_item "NGINX SIN BUFFERING" opt_on_ngx opt_ngx_on opt_ngx_off opt_ngx_info opt_ngx_desc ;;
            3) opt_item "WEBSOCKIFY" opt_on_wsfy opt_wsfy_on opt_wsfy_off opt_wsfy_info opt_wsfy_desc ;;
            0) return ;;
        esac
    done
}

# Indicador del panel: ON si hay al menos un ajuste activo
optimize_any_on() { opt_on_wsping || opt_on_ngx || opt_on_wsfy; }

# Desinstalación: apaga todo lo que haya activado este módulo (sin preguntar)
remove_optimize() {
    opt_on_wsfy    && opt_wsfy_off
    opt_on_ngx     && opt_ngx_off
    opt_on_wsping  && { conf_set WS_PING ""; opt_ws_ping_sync; }
    opt_legacy_cleanup
    return 0
}
