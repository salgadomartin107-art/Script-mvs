#!/usr/bin/env bash
# WSTUNNEL (erebe/wstunnel, licencia BSD-3): túnel TCP/UDP sobre WebSocket o HTTP/2, servidor del lado del VPS.
# Se baja el binario oficial de la release fijada y se verifica su SHA-256 (fijado aquí, tomado de checksums.txt de la release).
# Seguridad: el servidor se instala SIEMPRE con --restrict-to (solo puede reenviar a un puerto local elegido) y con un
# prefijo de ruta secreto (--restrict-http-upgrade-path-prefix) que hace de contraseña. El prefijo va en un archivo de
# entorno (no se ve en `ps` ni en la unidad). Con certificado propio, no con el que viene embebido en el binario.
# Tras instalar se comprueba con el propio cliente que un prefijo incorrecto sea rechazado; si no, se desinstala solo.
# shellcheck shell=bash

WST_UNIT="${APP_SLUG}-wstunnel"
WST_BIN="/usr/local/bin/${APP_SLUG}-wstunnel"
WST_DIR="/etc/${APP_SLUG}-wstunnel"
WST_USER="${APP_SLUG}-wstunnel"
WST_ENV="${WST_DIR}/env"
WST_FRONT="${WST_UNIT}-front"
WST_VERSION="11.1.0"
WST_MAX_BIN=$((64 * 1024 * 1024))
declare -A WST_SHA=(
    [amd64]="512edf4e7bb64fc133522220123514868fae75b5bae4124b53e396787276aa23"
    [arm64]="148895f957a68be39e2b65d28c5f2065b9c58c4a0cfd48c560b2b3267f398464"
    [armv7]="0a37948d6b68885acb5b2f8d275a6e256b65770fc39f9fe67882284eeafd40e3"
    [armv6]="da42f0dea5a43353a81a4077c4b8753e6217eb3dd1daea30c8f2c34b864a5931"
    [386]="dfdb0a0183d37405ed83768eb5c53215c39e92502d459e0e425c75a2e2ce2b9d"
)

wst_installed() { [[ -x "$WST_BIN" && -s "$WST_ENV" ]]; }

wst_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l) echo armv7 ;;
        armv6l) echo armv6 ;;
        i386|i686) echo 386 ;;
        *) return 1 ;;
    esac
}

# Deja el binario verificado en $WST_BIN.
wst_get_binary() {
    local arch tmp url sum want
    [[ -x "$WST_BIN" ]] && return 0
    arch="$(wst_arch)" || { err "Arquitectura no soportada: $(uname -m)."; return 1; }
    want="${WST_SHA[$arch]}"
    url="https://github.com/erebe/wstunnel/releases/download/v${WST_VERSION}/wstunnel_${WST_VERSION}_linux_${arch}.tar.gz"
    pkg_install curl tar ca-certificates || return 1
    tmp="$(mktemp -d)"; chmod 711 "$tmp"
    info "Descargando wstunnel ${WST_VERSION} (${arch}) de la release oficial..."
    if ! curl -fL --proto '=https' --tlsv1.2 --max-filesize "$WST_MAX_BIN" -o "$tmp/pkg.tgz" "$url"; then
        err "No se pudo descargar wstunnel."; rm -rf "$tmp"; return 1
    fi
    sum="$(sha256sum "$tmp/pkg.tgz" | awk '{print $1}')"
    if [[ "$sum" != "$want" ]]; then
        err "El SHA-256 del paquete NO coincide con el esperado."; echo "  obtenido: $sum"; echo "  esperado: $want"
        rm -rf "$tmp"; return 1
    fi
    ok "SHA-256 verificado (coincide con checksums.txt de la release v${WST_VERSION})."
    # solo se extrae el binario, con límite de tamaño
    tar -xzOf "$tmp/pkg.tgz" wstunnel 2>/dev/null | head -c "$((WST_MAX_BIN + 1))" > "$tmp/wstunnel"
    if [[ ! -s "$tmp/wstunnel" ]] || (( $(stat -c %s "$tmp/wstunnel") > WST_MAX_BIN )) \
       || [[ "$(head -c 4 "$tmp/wstunnel" | od -An -tx1 | tr -d ' \n')" != 7f454c46 ]]; then
        err "El paquete no trae un binario wstunnel válido."; rm -rf "$tmp"; return 1
    fi
    chmod 755 "$tmp/wstunnel"
    local ver; ver="$(cd "$tmp" && runuser -u nobody -- timeout 5 ./wstunnel --version 2>/dev/null)" || ver=""
    if [[ ! "$ver" =~ ^wstunnel ]]; then
        err "El binario no responde como wstunnel (--version)."; rm -rf "$tmp"; return 1
    fi
    ok "$ver"
    install -m 755 -o root -g root "$tmp/wstunnel" "$WST_BIN"; rm -rf "$tmp"
}

wst_rand_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24; }
wst_valid_secret() { [[ "$1" =~ ^[A-Za-z0-9]{8,64}$ ]]; }
wst_conf_get() { sed -n "s/^$1=//p" "$WST_ENV" 2>/dev/null | head -1; }

wst_write_env() { # secreto
    install -d -m 750 -o root -g "$WST_USER" "$WST_DIR"
    printf 'WSTUNNEL_RESTRICT_HTTP_UPGRADE_PATH_PREFIX=%s\n' "$1" > "$WST_ENV"
    chown root:"$WST_USER" "$WST_ENV"; chmod 640 "$WST_ENV"
}

# Frente 101 (lib/py/wstfront.py): escucha en el puerto público y deja a wstunnel en 127.0.0.1:$iport
wst_front_write_unit() { # puerto_publico puerto_interno destino
    local port="$1" iport="$2" tport="$3" cap="" py; py="$(command -v python3)"
    (( port < 1024 )) && cap="CAP_NET_BIND_SERVICE"
    cat > "/etc/systemd/system/${WST_FRONT}.service" <<EOF
[Unit]
Description=${APP_NAME} WSTUNNEL frente 101 (payloads HTTP Custom)
After=network-online.target ${WST_UNIT}.service
Wants=network-online.target

[Service]
Type=simple
User=${WST_USER}
ExecStart=${py} ${ROOT}/lib/py/wstfront.py --listen ${port} --internal ${iport} --target ${tport}
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
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
UMask=0077
LimitNOFILE=65535
LimitCORE=0
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
}

wst_write_unit() { # modo(wss|ws) puerto destino [puerto_interno: wstunnel solo en loopback]
    local mode="$1" port="$2" tport="$3" iport="${4:-}" cap="" tls="" url
    (( port < 1024 )) && cap="CAP_NET_BIND_SERVICE"
    [[ -n "$iport" ]] && cap=""
    if [[ "$mode" == wss ]]; then
        tls=" --tls-certificate ${WST_DIR}/fullchain.pem --tls-private-key ${WST_DIR}/privkey.pem"
    fi
    url="${mode}://0.0.0.0:${port}"
    [[ -n "$iport" ]] && url="ws://127.0.0.1:${iport}"
    cat > "/etc/systemd/system/${WST_UNIT}.service" <<EOF
[Unit]
Description=${APP_NAME} WSTUNNEL (servidor)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=${WST_USER}
EnvironmentFile=${WST_ENV}
ExecStart=${WST_BIN} server --restrict-to 127.0.0.1:${tport} --restrict-to localhost:${tport}${tls} --no-color ${url}
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
LimitNOFILE=65535
LimitCORE=0
Restart=on-failure
RestartSec=3s
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF
}

# Comprobación con el propio cliente de wstunnel: con el prefijo correcto el túnel queda abierto (el destino local acepta);
# con uno incorrecto el servidor lo rechaza y la conexión se cierra enseguida. Imprime: ok | abierto | fallo
wst_selftest() { # modo puerto destino secreto
    local mode="$1" port="$2" tport="$3" secret="$4" tmpport=39871 res_good res_bad lpid=""
    while port_in_use "$tmpport"; do tmpport=$((tmpport + 1)); done
    # si el destino todavía no está activo, se abre un oyente temporal en ese puerto para poder comprobar
    if ! port_in_use "$tport" && command -v python3 >/dev/null 2>&1; then
        timeout 25 python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', ${tport})); s.listen(8)
while True:
    c, _ = s.accept(); time.sleep(10)" >/dev/null 2>&1 &
        lpid=$!; sleep 0.7
    fi
    _wst_try() { # prefijo -> "cerrada" | "abierta"
        local pref="$1" pid rc
        timeout 12 "$WST_BIN" client --http-upgrade-path-prefix "$pref" -L "tcp://127.0.0.1:${tmpport}:127.0.0.1:${tport}" \
            "${mode}://127.0.0.1:${port}" >/dev/null 2>&1 &
        pid=$!
        sleep 1.5
        { exec 8<>"/dev/tcp/127.0.0.1/${tmpport}"; } 2>/dev/null || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "sin-cliente"; return; }
        timeout 3 cat <&8 >/dev/null 2>&1; rc=$?
        exec 8>&- 8<&-
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        [[ "$rc" == 124 ]] && echo abierta || echo cerrada
    }
    res_good="$(_wst_try "$secret")"
    res_bad="$(_wst_try "prefijo-incorrecto-$$")"
    unset -f _wst_try
    [[ -n "$lpid" ]] && { kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null; }
    if [[ "$res_bad" == abierta ]]; then echo abierto
    elif [[ "$res_good" == abierta && "$res_bad" == cerrada ]]; then echo ok
    else echo "fallo(${res_good}/${res_bad})"; fi
}

wst_client_examples() { # secreto host puerto modo destino
    local secret="$1" host="$2" port="$3" mode="$4" tport="$5"
    echo "Comandos del cliente (en tu PC/celular con wstunnel; el prefijo es la contraseña):"
    echo "  wstunnel client --http-upgrade-path-prefix ${secret} -L tcp://127.0.0.1:2222:127.0.0.1:${tport} ${mode}://${host}:${port}"
    echo "  wstunnel client --http-upgrade-path-prefix ${secret} -L 'udp://51820:127.0.0.1:51820?timeout_sec=0' ${mode}://${host}:${port}"
    echo "  (el segundo ejemplo es para UDP; el destino debe ser el puerto permitido: ${tport})"
    [[ "$mode" == wss ]] && echo "  Certificado propio/autofirmado: el cliente no lo verifica salvo que uses --tls-verify-certificate."
}

install_wstunnel() {
    local mode choice port tport host secret chk front="" iport=""
    echo "WSTUNNEL: túnel TCP/UDP sobre WebSocket/HTTP2 (erebe/wstunnel ${WST_VERSION})."
    wst_get_binary || return 1
    ensure_service_user "$WST_USER"
    pkg_install openssl curl iproute2 || return 1

    echo "Modo del servidor:"
    echo " 1) wss  (con TLS, certificado propio)   -> directo, o detrás de Cloudflare en modo \"Full\""
    echo " 2) ws   (sin TLS)                        -> detrás de un CDN/Cloudflare \"Flexible\" o dentro de otro túnel"
    read -rp " Opción [1]: " choice
    if [[ "$choice" == 2 ]]; then mode=ws; port="$(ask_port "Puerto de WSTUNNEL" 80)"
    else mode=wss; port="$(ask_port "Puerto de WSTUNNEL" 443)"; fi

    echo "El servidor solo podrá reenviar a UN puerto de este VPS (así nadie lo usa como proxy abierto)."
    tport="$(ask_target)" || return 1

    host="$(ask_host)"
    [[ "$host" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || { err "Dominio o IP inválido."; return 1; }
    if [[ "$mode" == wss ]]; then
        install -d -m 750 -o root -g "$WST_USER" "$WST_DIR"
        hcr_tls_setup "$host" "$WST_DIR" "$WST_USER" || return 1
    fi

    secret="$(wst_conf_get WSTUNNEL_RESTRICT_HTTP_UPGRADE_PATH_PREFIX)"
    if [[ -n "$secret" ]]; then read -rp "Prefijo secreto de acceso [Enter = conservar el actual]: " chk
    else read -rp "Prefijo secreto de acceso [Enter = generar uno al azar]: " chk; fi
    if [[ -n "$chk" ]]; then
        wst_valid_secret "$chk" || { err "Prefijo inválido (8 a 64 letras y números)."; return 1; }
        secret="$chk"
    else
        secret="${secret:-$(wst_rand_secret)}"
    fi
    wst_valid_secret "$secret" || { err "No se pudo generar el prefijo secreto."; return 1; }

    if [[ "$mode" == ws ]]; then
        echo "Payloads de HTTP Custom / HTTP Injector: wstunnel solo contesta 101 a su propio cliente y 400 al resto."
        echo "El frente 101 contesta \"101 Switching Protocols\" a esos payloads y los conecta directo a ${tport} (SSH/Dropbear),"
        echo "y deja pasar al cliente wstunnel real. Ojo: esa vía no usa el prefijo secreto; la protege el usuario/clave SSH."
        read -rp "¿Activar el frente 101? [S/n]: " chk
        if [[ ! "$chk" =~ ^[nN] ]]; then
            command -v python3 >/dev/null 2>&1 || pkg_install python3 || return 1
            front=1; iport=45871
            while port_in_use "$iport" && [[ "$iport" != "$(conf_get WST_IPORT)" ]]; do iport=$((iport + 1)); done
        fi
    fi

    systemctl disable --now "$WST_FRONT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${WST_FRONT}.service"
    wst_write_env "$secret"
    wst_write_unit "$mode" "$port" "$tport" "$iport"
    declare -F opt_ws_ping_sync >/dev/null && opt_ws_ping_sync
    svc_enable_restart "$WST_UNIT"; sleep 2
    conf_set WST_PORT "$port"; conf_set WST_MODE "$mode"; conf_set WST_TARGET "$tport"; conf_set WST_HOST "$host"
    conf_set WST_IPORT "$iport"
    if [[ -n "$front" ]]; then
        wst_front_write_unit "$port" "$iport" "$tport"
        svc_enable_restart "$WST_FRONT"; sleep 1
        svc_is_active "$WST_FRONT" || { err "El frente 101 no arrancó. Revisá: journalctl -u ${WST_FRONT} -n 30"; return 1; }
    fi
    if ! svc_is_active "$WST_UNIT"; then
        err "No arrancó. Revisá: journalctl -u ${WST_UNIT} -n 30"; return 1
    fi

    chk="$(wst_selftest "$mode" "$port" "$tport" "$secret")"
    case "$chk" in
        ok) ok "Comprobado: el servidor rechaza un prefijo incorrecto y acepta el correcto." ;;
        abierto)
            err "El servidor aceptó un prefijo incorrecto. Se desinstala por seguridad."
            remove_wstunnel; return 1 ;;
        *)  warn "No pude completar la comprobación automática (${chk}). Revisá con: journalctl -u ${WST_UNIT} -n 30" ;;
    esac

    conf_set WST_FWPORT "$port"
    ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$port/tcp" >/dev/null 2>&1
    ok "WSTUNNEL activo: ${mode}://0.0.0.0:${port} -> 127.0.0.1:${tport}"
    [[ -n "$front" ]] && ok "Frente 101 activo: un payload HTTP en el puerto ${port} recibe 101 Switching Protocols y va a ${tport}."
    warn "Abrí el puerto TCP ${port} en el firewall de la nube (NSG de Azure)."
    bar
    printf ' %sPrefijo secreto:%s %s\n' "$Y" "$N" "$secret"
    bar
    wst_client_examples "$secret" "$host" "$port" "$mode" "$tport"
}

wstunnel_info() {
    local mode port tport host secret
    mode="$(conf_get WST_MODE)"; port="$(conf_get WST_PORT)"; tport="$(conf_get WST_TARGET)"; host="$(conf_get WST_HOST)"
    secret="$(wst_conf_get WSTUNNEL_RESTRICT_HTTP_UPGRADE_PATH_PREFIX)"
    echo "Servidor: ${mode}://0.0.0.0:${port}  ->  solo a 127.0.0.1:${tport}   (wstunnel ${WST_VERSION})"
    echo "Prefijo secreto: ${secret}"
    [[ -n "$(conf_get WST_IPORT)" ]] && echo "Frente 101: ACTIVO (payload HTTP -> 101 Switching Protocols -> 127.0.0.1:${tport}; cliente wstunnel -> túnel con prefijo)"
    echo "Usuario y clave: los de una cuenta SSH del panel (opción 5 de este menú, o [P] USUARIOS SSH)."
    wst_client_examples "$secret" "$host" "$port" "$mode" "$tport"
}

wst_change_secret() {
    local new
    read -rp "Nuevo prefijo (8-64 letras y números; Enter = generar uno): " new
    new="${new:-$(wst_rand_secret)}"
    wst_valid_secret "$new" || { err "Prefijo inválido (8 a 64 letras y números)."; return 1; }
    warn "Los clientes conectados quedarán cortados hasta que usen el prefijo nuevo."
    confirm "¿Cambiar el prefijo?" || return 0
    wst_write_env "$new"
    systemctl restart "$WST_UNIT" 2>/dev/null; sleep 1.5
    svc_is_active "$WST_UNIT" && ok "Prefijo nuevo: ${new}" || err "No arrancó tras el cambio. Revisá: journalctl -u ${WST_UNIT} -n 30"
}

remove_wstunnel() {
    local p k; p="$(conf_get WST_FWPORT)"
    systemctl disable --now "$WST_FRONT" >/dev/null 2>&1 || true
    systemctl disable --now "$WST_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${WST_FRONT}.service"
    if [[ -n "$p" ]] && ufw status 2>/dev/null | grep -q "Status: active"; then ufw delete allow "$p/tcp" >/dev/null 2>&1; fi
    rm -f "/etc/systemd/system/${WST_UNIT}.service" "$WST_BIN"; rm -rf "$WST_DIR"; systemctl daemon-reload
    id "$WST_USER" >/dev/null 2>&1 && userdel "$WST_USER" >/dev/null 2>&1
    for k in WST_PORT WST_MODE WST_TARGET WST_HOST WST_FWPORT WST_IPORT; do conf_set "$k" ""; done
    ok "WSTUNNEL eliminado."
}

wstunnel_menu() {
    local op
    if ! wst_installed; then install_wstunnel; pause; return; fi
    while true; do
        title "WSTUNNEL"
        echo " Estado: $(svc_is_active "$WST_UNIT" && echo "${G}ACTIVO${N}" || echo "${R}DETENIDO${N}")   $(conf_get WST_MODE)://:$(conf_get WST_PORT) -> 127.0.0.1:$(conf_get WST_TARGET)"
        bar
        echo " 1) Ver datos y comandos del cliente   3) Reinstalar / cambiar puerto, modo o destino"
        echo " 2) Cambiar el prefijo secreto         4) Quitar"
        echo " 5) Crear usuario SSH (el que pide la app al conectar)"
        echo " 0) Volver"
        bar; read -rp " Opción: " op || return
        case "$op" in
            1) wstunnel_info; pause ;;
            2) wst_change_secret; pause ;;
            3) systemctl stop "$WST_FRONT" "$WST_UNIT" 2>/dev/null; install_wstunnel || systemctl start "$WST_UNIT" "$WST_FRONT" 2>/dev/null; pause ;;
            4) confirm "¿Quitar WSTUNNEL?" && remove_wstunnel; pause; return ;;
            5) user_create_prompt; pause ;;
            0) return ;;
        esac
    done
}
