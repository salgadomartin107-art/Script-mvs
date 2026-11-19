#!/usr/bin/env bash
# OPTIMIZAR [38]: seis ajustes que se activan y desactivan de a uno.
#   1 Ping WebSocket cada 25 s   (wstunnel, WS-PRO y Websockify)
#   2 Nginx sin buffering        (proxy WebSocket delante de un servicio local)
#   3 SSH con keepalive          (OpenSSH y Dropbear)
#   4 Monitoreo CPU/RAM/tráfico  (vista en vivo + historial de 7 días)
#   5 Unbound DNS                (caché DNS local en 127.0.0.1)
#   6 Websockify                 (WebSocket -> TCP hacia un puerto local)
# Todo lo que se instala con apt se instala SIN arrancar solo (policy-rc.d), se valida la configuración antes de
# arrancar y se puede volver atrás desde el mismo menú. Al desactivar solo se quita lo que instaló el panel.
# shellcheck shell=bash

OPT_PING_SECS=25
OPT_SSH_KA=30
OPT_SSH_DROPIN="/etc/ssh/sshd_config.d/92-${APP_SLUG}-keepalive.conf"
OPT_SSH_MARK_B="# >>> ${APP_SLUG} keepalive >>>"
OPT_SSH_MARK_E="# <<< ${APP_SLUG} keepalive <<<"
OPT_NGX_CONF="/etc/nginx/conf.d/${APP_SLUG}-ws.conf"
OPT_UNB_CONF="/etc/unbound/unbound.conf.d/${APP_SLUG}.conf"
OPT_UNB_INC_B="# >>> ${APP_SLUG} unbound >>>"
OPT_UNB_INC_E="# <<< ${APP_SLUG} unbound <<<"
OPT_RESOLVED_CONF="/etc/systemd/resolved.conf.d/zz-${APP_SLUG}-unbound.conf"
OPT_RESOLV_BAK="/etc/${APP_SLUG}-resolv.conf.bak"
OPT_STATS_DIR="/var/lib/${APP_SLUG}-stats"
OPT_STATS_CRON="/etc/cron.d/${APP_SLUG}-stats"
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

# ¿OpenSSH lee /etc/ssh/sshd_config.d/*.conf? (OpenSSH 8.2+/Debian 11+; en los viejos no hay Include)
opt_sshd_has_include() {
    [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null
}

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
# 3. SSH con keepalive
# ---------------------------------------------------------------------------------------------------------------
opt_on_ssh() { [[ -n "$(conf_get SSH_KEEPALIVE)" ]]; }

opt_dropbear_ka_sync() { # quita/pone -K en la unidad de dropbear del panel
    local f="/etc/systemd/system/${APP_SLUG}-dropbear.service" n; n="$(conf_get SSH_KEEPALIVE)"
    [[ -f "$f" ]] || return 1
    sed -i -E '/^ExecStart=/s/ -K [0-9]+//' "$f"
    [[ -n "$n" ]] && sed -i -E "/^ExecStart=/s|^(ExecStart=[^ ]+)|\\1 -K ${n}|" "$f"
    return 0
}

opt_ssh_on() {
    local cfg=/etc/ssh/sshd_config body tmp
    body="ClientAliveInterval ${OPT_SSH_KA}
ClientAliveCountMax 3
TCPKeepAlive yes"
    if command -v sshd >/dev/null 2>&1 && [[ -f "$cfg" ]]; then
        if opt_sshd_has_include; then
            printf '%s\n' "$body" > "$OPT_SSH_DROPIN"; chmod 644 "$OPT_SSH_DROPIN"
        else
            # OpenSSH viejo: sin Include. Vale la PRIMERA aparición de cada opción, así que el bloque va al principio.
            cp -a "$cfg" "${cfg}.${APP_SLUG}-ka.bak"
            tmp="$(mktemp)"
            { printf '%s\n%s\n%s\n' "$OPT_SSH_MARK_B" "$body" "$OPT_SSH_MARK_E"; cat "$cfg"; } > "$tmp"
            cat "$tmp" > "$cfg"; rm -f "$tmp"
        fi
        if sshd -t 2>/dev/null; then
            ssh_reload; ok "OpenSSH: ClientAliveInterval ${OPT_SSH_KA}, ClientAliveCountMax 3, TCPKeepAlive yes."
            rm -f "${cfg}.${APP_SLUG}-ka.bak"
        else
            err "sshd rechazó la configuración: se deshace."
            rm -f "$OPT_SSH_DROPIN"
            [[ -f "${cfg}.${APP_SLUG}-ka.bak" ]] && mv -f "${cfg}.${APP_SLUG}-ka.bak" "$cfg"
            return 1
        fi
    else
        info "OpenSSH no está instalado: se salta."
    fi
    conf_set SSH_KEEPALIVE "$OPT_SSH_KA"
    if opt_dropbear_ka_sync; then
        systemctl daemon-reload
        svc_is_active "${APP_SLUG}-dropbear" && systemctl restart "${APP_SLUG}-dropbear" 2>/dev/null
        ok "Dropbear: -K ${OPT_SSH_KA} (las sesiones abiertas no se cortan)."
    else
        info "Dropbear del panel no está instalado: se aplicará al instalarlo."
    fi
}
opt_ssh_off() {
    local cfg=/etc/ssh/sshd_config
    rm -f "$OPT_SSH_DROPIN"
    if [[ -f "$cfg" ]] && grep -qF "$OPT_SSH_MARK_B" "$cfg"; then
        sed -i "\\|^${OPT_SSH_MARK_B}\$|,\\|^${OPT_SSH_MARK_E}\$|d" "$cfg"
    fi
    if command -v sshd >/dev/null 2>&1; then
        if sshd -t 2>/dev/null; then ssh_reload; else warn "sshd no valida su configuración: revisá /etc/ssh/sshd_config."; fi
    fi
    conf_set SSH_KEEPALIVE ""
    if opt_dropbear_ka_sync; then
        systemctl daemon-reload
        svc_is_active "${APP_SLUG}-dropbear" && systemctl restart "${APP_SLUG}-dropbear" 2>/dev/null
    fi
    ok "SSH keepalive desactivado."
}
opt_ssh_info() {
    echo "OpenSSH: ClientAliveInterval $(conf_get SSH_KEEPALIVE), ClientAliveCountMax 3, TCPKeepAlive yes"
    echo "Dropbear: -K $(conf_get SSH_KEEPALIVE)"
    command -v sshd >/dev/null 2>&1 && sshd -T 2>/dev/null | grep -E '^(clientaliveinterval|clientalivecountmax|tcpkeepalive) '
}
opt_ssh_desc() {
    echo "El servidor manda un paquete de control cada ${OPT_SSH_KA} s por cada sesión SSH (OpenSSH y Dropbear)."
    echo "Una sesión muerta se cierra sola a los ~90 s y las quietas no las corta el NAT del operador."
}

# ---------------------------------------------------------------------------------------------------------------
# 4. Monitoreo de CPU, RAM y tráfico
# ---------------------------------------------------------------------------------------------------------------
opt_on_stats() { [[ -f "$OPT_STATS_CRON" ]]; }

opt_bar() { # porcentaje ancho
    local p="$1" w="${2:-20}" n i out="" col="$G"
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    (( p > 100 )) && p=100
    (( p >= 70 )) && col="$Y"; (( p >= 90 )) && col="$R"
    n=$(( p * w / 100 ))
    for ((i = 0; i < w; i++)); do (( i < n )) && out+="█" || out+="░"; done
    printf '%s%s%s %3d%%' "$col" "$out" "$N" "$p"
}

opt_human() { # bytes -> texto
    awk -v b="$1" 'BEGIN{ split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5) { b/=1024; i++ } printf (i==1 ? "%d %s" : "%.2f %s"), b, u[i] }'
}

opt_def_iface() { ip route show default 2>/dev/null | awk '{for(k=1;k<NF;k++) if($k=="dev"){print $(k+1); exit}}'; }

opt_stats_live() {
    local iface pt pi rx0 tx0 rx1 tx1 key cpu mem swap load t0 t1 dt up dn
    iface="$(opt_def_iface)"
    [[ -n "$iface" ]] || iface="$(awk 'NR>2 && $1!="lo:" {sub(":","",$1); print $1; exit}' /proc/net/dev)"
    read -r _ u n s i w q sq st _ < /proc/stat; pt=$((u + n + s + i + w + q + sq + st)); pi=$((i + w))
    read -r rx0 tx0 < <(awk -v i="${iface}:" '$1==i {print $2, $10}' /proc/net/dev); t0=$(date +%s.%N)
    while true; do
        read -rsn1 -t 2 key && break
        read -r _ u n s i w q sq st _ < /proc/stat
        local nt=$((u + n + s + i + w + q + sq + st)) ni=$((i + w)) dtot didl
        dtot=$((nt - pt)); didl=$((ni - pi)); cpu=0
        (( dtot > 0 )) && cpu=$(( (100 * (dtot - didl)) / dtot ))
        pt=$nt; pi=$ni
        mem="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if(t>0) printf "%d", (t-a)*100/t}' /proc/meminfo)"
        swap="$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{if(t>0) printf "%d", (t-f)*100/t; else print 0}' /proc/meminfo)"
        load="$(cut -d' ' -f1-3 /proc/loadavg)"
        read -r rx1 tx1 < <(awk -v i="${iface}:" '$1==i {print $2, $10}' /proc/net/dev); t1=$(date +%s.%N)
        dt="$(awk -v a="$t0" -v b="$t1" 'BEGIN{d=b-a; if(d<=0)d=1; print d}')"
        dn="$(awk -v a="${rx0:-0}" -v b="${rx1:-0}" -v d="$dt" 'BEGIN{v=(b-a)/d; if(v<0)v=0; printf "%d", v}')"
        up="$(awk -v a="${tx0:-0}" -v b="${tx1:-0}" -v d="$dt" 'BEGIN{v=(b-a)/d; if(v<0)v=0; printf "%d", v}')"
        rx0="$rx1"; tx0="$tx1"; t0="$t1"
        clear
        bar; printf '  %sMONITOR EN VIVO%s  (cualquier tecla = salir)  %s\n' "$G" "$N" "$(date '+%H:%M:%S')"; bar
        printf ' CPU   %s\n' "$(opt_bar "$cpu" 30)"
        printf ' RAM   %s   %s / %s\n' "$(opt_bar "${mem:-0}" 30)" \
            "$(free -m | awk '/^Mem:/{printf "%d MB", $3}')" "$(free -m | awk '/^Mem:/{printf "%d MB", $2}')"
        printf ' SWAP  %s\n' "$(opt_bar "${swap:-0}" 30)"
        printf ' Carga %s   (núcleos: %s)\n' "$load" "$(nproc)"
        bar
        printf ' Red %s   ↓ %s/s   ↑ %s/s\n' "$iface" "$(opt_human "$dn")" "$(opt_human "$up")"
        printf ' Total desde el arranque   ↓ %s   ↑ %s\n' "$(opt_human "${rx1:-0}")" "$(opt_human "${tx1:-0}")"
        printf ' Conexiones TCP establecidas: %s\n' "$(ss -Htn state established 2>/dev/null | wc -l)"
        bar
        echo " Procesos que más CPU usan:"
        ps -eo pcpu,pmem,comm --sort=-pcpu 2>/dev/null | awk 'NR>1 && NR<=6 {printf "  %5s%% CPU  %5s%% RAM  %s\n", $1, $2, $3}'
    done
}

# Resumen del CSV: últimas 1 h / 24 h / 7 días
opt_stats_summary() {
    local csv="$OPT_STATS_DIR/stats.csv" now w label
    [[ -s "$csv" ]] || { warn "Todavía no hay datos: el historial junta una muestra por minuto."; return 1; }
    now="$(date +%s)"
    printf ' %-10s %-8s %-8s %-8s %-8s %-14s %-14s\n' "Ventana" "CPU med" "CPU máx" "RAM med" "RAM máx" "Bajada" "Subida"
    for w in 3600:1\ hora 86400:24\ horas 604800:7\ días; do
        label="${w#*:}"
        awk -F, -v now="$now" -v win="${w%%:*}" -v label="$label" '
            function hum(b,   u, i) { split("B KB MB GB TB", u, " "); i=1; while (b>=1024 && i<5) { b/=1024; i++ } return (i==1) ? sprintf("%d %s", b, u[i]) : sprintf("%.2f %s", b, u[i]) }
            $1 >= now-win {
                n++; c+=$2; m+=$3
                if ($2+0 > cm) cm=$2+0
                if ($3+0 > mm) mm=$3+0
                if (have) {
                    d=$6-prx; if (d<0) d=$6   # contador reiniciado (reinicio del VPS)
                    e=$7-ptx; if (e<0) e=$7
                    rx+=d; tx+=e
                }
                prx=$6; ptx=$7; have=1
            }
            END {
                if (n == 0) { printf " %-10s sin datos\n", label; exit }
                printf " %-10s %-8s %-8s %-8s %-8s %-14s %-14s\n", label, sprintf("%d%%", c/n), sprintf("%d%%", cm), sprintf("%d%%", m/n), sprintf("%d%%", mm), hum(rx), hum(tx)
            }' "$csv"
    done
    echo " Muestras guardadas: $(wc -l < "$csv")  (una por minuto, hasta 7 días)"
}

opt_stats_on() {
    command -v ip >/dev/null 2>&1 || pkg_install iproute2
    install -d -m 700 "$OPT_STATS_DIR"
    printf '* * * * * root %s/bin/statlog >/dev/null 2>&1\n' "$ROOT" > "$OPT_STATS_CRON"
    chmod 644 "$OPT_STATS_CRON"
    "$ROOT/bin/statlog" 2>/dev/null || true
    ok "Historial activado: una muestra por minuto en $OPT_STATS_DIR (7 días)."
}
opt_stats_off() {
    rm -f "$OPT_STATS_CRON"
    if confirm "¿Borrar también el historial guardado?"; then rm -rf "$OPT_STATS_DIR"; fi
    ok "Historial desactivado."
}

opt_stats_menu() {
    local op
    while true; do
        title "MONITOREO CPU / RAM / TRÁFICO"
        echo " Historial: $(opt_on_stats && echo "${G}ACTIVADO${N}" || echo "${R}DESACTIVADO${N}")"
        bar
        echo " 1) Ver en vivo (CPU, RAM, red, procesos)"
        echo " 2) Resumen del historial (1 h / 24 h / 7 días)"
        if opt_on_stats; then echo " 3) Desactivar el historial"; else echo " 3) Activar el historial (cron cada minuto)"; fi
        echo " 0) Volver"
        bar; read -rp " Opción: " op || return
        case "$op" in
            1) opt_stats_live ;;
            2) opt_stats_summary; pause ;;
            3) if opt_on_stats; then opt_stats_off; else opt_stats_on; fi; pause ;;
            0) return ;;
        esac
    done
}

# ---------------------------------------------------------------------------------------------------------------
# 5. Unbound DNS
# ---------------------------------------------------------------------------------------------------------------
opt_on_unbound() { [[ -f "$OPT_UNB_CONF" ]]; }

# Quién escucha en 127.0.0.1:53 o en todas las interfaces:53 (el stub 127.0.0.53 de systemd-resolved no molesta)
opt_dns_port_owner() {
    ss -H -lnptu 2>/dev/null | awk '$5 ~ /^(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]):53$/ {print $0}' | head -1
}

# Consulta DNS A de prueba a 127.0.0.1:53 (sin dig): imprime ok si trae al menos una respuesta
opt_dns_test() {
    python3 - <<'PYEOF' 2>/dev/null
import socket, struct, os
q = os.urandom(2) + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
for lab in ("example", "com"):
    q += bytes([len(lab)]) + lab.encode()
q += b"\x00\x00\x01\x00\x01"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(6)
try:
    s.sendto(q, ("127.0.0.1", 53)); r = s.recv(512)
    print("ok" if len(r) > 12 and struct.unpack("!H", r[6:8])[0] > 0 and (r[3] & 0x0F) == 0 else "fallo")
except Exception:
    print("fallo")
PYEOF
}

opt_unbound_write() { # modo: forward | recursive
    local mode="$1" thr
    thr="$(nproc)"; (( thr > 2 )) && thr=2
    install -d -m 755 /etc/unbound/unbound.conf.d
    {
        cat <<UNBEOF
# ${APP_NAME}: caché DNS local (solo 127.0.0.1)
server:
    interface: 127.0.0.1
    port: 53
    access-control: 127.0.0.0/8 allow
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    num-threads: ${thr}
    msg-cache-size: 16m
    rrset-cache-size: 32m
    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    use-caps-for-id: no
UNBEOF
        if [[ "$mode" == forward ]]; then
            cat <<UNBEOF2

forward-zone:
    name: "."
    forward-addr: 1.1.1.1
    forward-addr: 1.0.0.1
    forward-addr: 8.8.8.8
UNBEOF2
        fi
    } > "$OPT_UNB_CONF"
    chmod 644 "$OPT_UNB_CONF"
}

opt_unbound_on() {
    local owner mode choice by_us=0 out use_sys=0 i res
    command -v python3 >/dev/null 2>&1 || pkg_install python3 || { err "Hace falta python3."; return 1; }
    owner="$(opt_dns_port_owner)"
    if [[ -n "$owner" ]] && ! (opt_pkg_present unbound && svc_is_active unbound); then
        err "El puerto 53 ya lo usa otro servicio:"; echo "  $owner" >&2
        err "Si es SlowDNS u otro del panel, Unbound no puede escuchar ahí. Desactivá ese servicio primero."
        return 1
    fi
    echo "Modo de resolución:"
    echo " 1) Reenviar a 1.1.1.1 / 1.0.0.1 / 8.8.8.8 (rápido y funciona en cualquier red)"
    echo " 2) Recursivo desde los servidores raíz (sin intermediarios, un poco más lento al inicio)"
    read -rp " Opción [1]: " choice || return 1
    [[ "$choice" == 2 ]] && mode=recursive || mode=forward

    if ! opt_pkg_present unbound; then
        info "Instalando unbound (sin arrancarlo)..."
        opt_pkg_nostart unbound || { err "No se pudo instalar unbound."; return 1; }
        by_us=1
    fi
    command -v unbound >/dev/null 2>&1 || { err "No se encontró el binario de unbound."; return 1; }
    # Sin la clave raíz (DNSSEC) unbound no valida su configuración: la crea el paquete al arrancar, aquí se genera antes
    if [[ ! -s /var/lib/unbound/root.key ]] && command -v unbound-anchor >/dev/null 2>&1; then
        install -d -m 755 /var/lib/unbound
        unbound-anchor -a /var/lib/unbound/root.key >/dev/null 2>&1 || true
        id unbound >/dev/null 2>&1 && chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null
    fi
    opt_unbound_write "$mode"
    # En algunas versiones viejas el unbound.conf del paquete no incluye unbound.conf.d: se añade el include
    if ! unbound-checkconf -o interface 2>/dev/null | grep -qx '127.0.0.1'; then
        if ! grep -qF "$OPT_UNB_INC_B" /etc/unbound/unbound.conf 2>/dev/null; then
            printf '\n%s\ninclude: "%s"\n%s\n' "$OPT_UNB_INC_B" "$OPT_UNB_CONF" "$OPT_UNB_INC_E" >> /etc/unbound/unbound.conf
        fi
    fi
    if ! out="$(unbound-checkconf 2>&1)"; then
        err "unbound rechazó la configuración:"; echo "$out" | tail -5 >&2
        rm -f "$OPT_UNB_CONF"; opt_unbound_cleanup_include
        (( by_us )) && DEBIAN_FRONTEND=noninteractive apt-get purge -y unbound >/dev/null 2>&1
        return 1
    fi
    systemctl enable unbound >/dev/null 2>&1 || true
    systemctl restart unbound 2>/dev/null
    res=fallo
    for i in 1 2 3 4; do sleep 1; res="$(opt_dns_test)"; [[ "$res" == ok ]] && break; done
    if [[ "$res" != ok ]]; then
        err "Unbound arrancó pero no resuelve (¿el VPS bloquea el DNS saliente?). Revisá: journalctl -u unbound -n 30"
        systemctl disable --now unbound >/dev/null 2>&1; rm -f "$OPT_UNB_CONF"; opt_unbound_cleanup_include
        (( by_us )) && DEBIAN_FRONTEND=noninteractive apt-get purge -y unbound >/dev/null 2>&1
        return 1
    fi
    ok "Unbound responde en 127.0.0.1:53 (modo $mode)."
    (( by_us )) && conf_set UNB_BY_US 1
    conf_set UNB_MODE "$mode"

    if confirm "¿Usar Unbound como DNS de este servidor?"; then
        if svc_is_active systemd-resolved; then
            install -d -m 755 /etc/systemd/resolved.conf.d
            printf '[Resolve]\nDNS=\nDNS=127.0.0.1\n' > "$OPT_RESOLVED_CONF"
            systemctl restart systemd-resolved 2>/dev/null; use_sys=1
            conf_set UNB_SYSDNS resolved
        elif [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
            cp -a /etc/resolv.conf "$OPT_RESOLV_BAK"
            printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf; use_sys=1
            conf_set UNB_SYSDNS resolvconf
        else
            warn "/etc/resolv.conf lo administra otro programa: no lo toco. Poné 127.0.0.1 como DNS donde corresponda."
        fi
        if (( use_sys )); then
            if getent hosts example.com >/dev/null 2>&1; then ok "El servidor ya resuelve a través de Unbound."
            else
                warn "El sistema no resolvió con Unbound: se deja el DNS como estaba."
                opt_unbound_sysdns_off
            fi
        fi
    fi
    info "Unbound solo escucha en 127.0.0.1 (no es un resolvedor abierto). Para el DNS de tus clientes VPN apuntalo en sus propios ajustes."
}

opt_unbound_cleanup_include() {
    [[ -f /etc/unbound/unbound.conf ]] && grep -qF "$OPT_UNB_INC_B" /etc/unbound/unbound.conf &&
        sed -i "\\|^${OPT_UNB_INC_B}\$|,\\|^${OPT_UNB_INC_E}\$|d" /etc/unbound/unbound.conf
    return 0
}

opt_unbound_sysdns_off() {
    local how; how="$(conf_get UNB_SYSDNS)"
    if [[ "$how" == resolved || -f "$OPT_RESOLVED_CONF" ]]; then
        rm -f "$OPT_RESOLVED_CONF"; systemctl restart systemd-resolved 2>/dev/null
    fi
    if [[ "$how" == resolvconf && -f "$OPT_RESOLV_BAK" ]]; then
        cat "$OPT_RESOLV_BAK" > /etc/resolv.conf; rm -f "$OPT_RESOLV_BAK"
    fi
    conf_set UNB_SYSDNS ""
}

opt_unbound_off() {
    opt_unbound_sysdns_off
    systemctl disable --now unbound >/dev/null 2>&1 || true
    rm -f "$OPT_UNB_CONF"; opt_unbound_cleanup_include
    if [[ "$(conf_get UNB_BY_US)" == 1 ]]; then DEBIAN_FRONTEND=noninteractive apt-get purge -y unbound >/dev/null 2>&1 || true; fi
    conf_set UNB_BY_US ""; conf_set UNB_MODE ""
    ok "Unbound desactivado (el DNS del servidor volvió a como estaba)."
}
opt_unbound_info() {
    echo "Unbound: 127.0.0.1:53, modo $(conf_get UNB_MODE), DNS del sistema: ${G}$([[ -n "$(conf_get UNB_SYSDNS)" ]] && echo sí || echo no)${N}"
    echo "Prueba: $(opt_dns_test)"
    echo "Configuración: $OPT_UNB_CONF"
}
opt_unbound_desc() {
    echo "Caché DNS local (Unbound) en 127.0.0.1:53 con prefetch. Las resoluciones repetidas del servidor y de los"
    echo "túneles que salen por él responden al instante. No queda abierto a Internet."
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
    while true; do
        title "OPTIMIZAR"
        printf ' 1) Ping WebSocket cada %s s        %s\n' "$OPT_PING_SECS" "$(opt_tag opt_on_wsping)"
        printf ' 2) Nginx sin buffering               %s\n' "$(opt_tag opt_on_ngx)"
        printf ' 3) SSH con keepalive                 %s\n' "$(opt_tag opt_on_ssh)"
        printf ' 4) Monitoreo CPU / RAM / tráfico     %s\n' "$(opt_tag opt_on_stats)"
        printf ' 5) Unbound DNS                       %s\n' "$(opt_tag opt_on_unbound)"
        printf ' 6) Websockify                        %s\n' "$(opt_tag opt_on_wsfy)"
        echo " 0) Volver"
        bar; read -rp " Opción: " op || return
        case "$op" in
            1) opt_item "PING WEBSOCKET ${OPT_PING_SECS} s" opt_on_wsping opt_wsping_on opt_wsping_off opt_wsping_info opt_wsping_desc ;;
            2) opt_item "NGINX SIN BUFFERING" opt_on_ngx opt_ngx_on opt_ngx_off opt_ngx_info opt_ngx_desc ;;
            3) opt_item "SSH CON KEEPALIVE" opt_on_ssh opt_ssh_on opt_ssh_off opt_ssh_info opt_ssh_desc ;;
            4) opt_stats_menu ;;
            5) opt_item "UNBOUND DNS" opt_on_unbound opt_unbound_on opt_unbound_off opt_unbound_info opt_unbound_desc ;;
            6) opt_item "WEBSOCKIFY" opt_on_wsfy opt_wsfy_on opt_wsfy_off opt_wsfy_info opt_wsfy_desc ;;
            0) return ;;
        esac
    done
}

# Indicador del panel: ON si hay al menos un ajuste activo
optimize_any_on() {
    opt_on_wsping || opt_on_ngx || opt_on_ssh || opt_on_stats || opt_on_unbound || opt_on_wsfy
}

# Desinstalación: apaga todo lo que haya activado este módulo (sin preguntar)
remove_optimize() {
    opt_on_wsfy    && opt_wsfy_off
    opt_on_unbound && opt_unbound_off
    opt_on_ngx     && opt_ngx_off
    opt_on_ssh     && opt_ssh_off
    opt_on_wsping  && { conf_set WS_PING ""; opt_ws_ping_sync; }
    rm -f "$OPT_STATS_CRON"; rm -rf "$OPT_STATS_DIR"
    return 0
}
