#!/usr/bin/env bash
# SOCKS5 con UDP (HevSocks5Server, de heiher; licencia MIT): https://github.com/heiher/hev-socks5-server
# Es el servidor que acompaña al "motor SOCKS" HevSocks5Tunnel de las apps (tun2socks). Soporta CONNECT, UDP ASSOCIATE
# y UDP-en-TCP ("FWD UDP"), con varios usuarios/claves.
# Se compila desde el código fuente en el tag fijado y se verifica el commit (los submódulos quedan fijados por ese commit).
# IMPORTANTE: sin la sección "auth" el servidor es un proxy ABIERTO. Este módulo siempre la escribe y, tras instalar,
# comprueba que rechace conexiones sin credenciales; si no las rechaza, se desinstala solo.
# shellcheck shell=bash

HEVS_UNIT="${APP_SLUG}-hevsocks5"
HEVS_BIN="/usr/local/bin/${APP_SLUG}-hevsocks5"
HEVS_DIR="/etc/${APP_SLUG}-hevsocks5"
HEVS_USER="${APP_SLUG}-hevsocks5"
HEVS_AUTH="${HEVS_DIR}/auth.txt"
HEVS_REPO="https://github.com/heiher/hev-socks5-server.git"
HEVS_TAG="2.9.0"
HEVS_COMMIT="492b0de45bf3300dfc6d769f235252da1b617f4f"

hevs_installed() { [[ -x "$HEVS_BIN" && -s "$HEVS_DIR/main.yml" ]]; }

# Deja el binario en $HEVS_BIN, compilado del tag oficial.
hevs_get_binary() {
    local tmp
    [[ -x "$HEVS_BIN" ]] && return 0
    info "Compilando HevSocks5Server ${HEVS_TAG} desde el repositorio oficial..."
    pkg_install git build-essential || { err "No se pudieron instalar git y el compilador."; return 1; }
    tmp="$(mktemp -d)"
    if ! git clone -q --depth 1 --branch "$HEVS_TAG" --recurse-submodules --shallow-submodules "$HEVS_REPO" "$tmp/src" 2>/dev/null; then
        rm -rf "$tmp/src"   # git viejo (Debian 8/Ubuntu 16-): sin --shallow-submodules
        if ! { git clone -q --branch "$HEVS_TAG" "$HEVS_REPO" "$tmp/src" 2>/dev/null \
               && git -C "$tmp/src" submodule update -q --init 2>/dev/null; }; then
            err "No se pudo descargar HevSocks5Server desde GitHub."; rm -rf "$tmp"; return 1
        fi
    fi
    if [[ "$(git -C "$tmp/src" rev-parse HEAD)" != "$HEVS_COMMIT" ]]; then
        err "El commit descargado no coincide con el esperado. Instalación cancelada."; rm -rf "$tmp"; return 1
    fi
    if ! ( cd "$tmp/src" && make -j"$(nproc)" >/dev/null 2>&1 ) || [[ ! -x "$tmp/src/bin/hev-socks5-server" ]]; then
        err "Falló la compilación de HevSocks5Server."; rm -rf "$tmp"; return 1
    fi
    install -m 755 -o root -g root "$tmp/src/bin/hev-socks5-server" "$HEVS_BIN"
    rm -rf "$tmp"
}

# El servidor crea siempre un socket IPv6 (aunque escuche en IPv4): necesita IPv6 habilitado en el kernel.
hevs_ipv6_ok() { [[ -d /proc/sys/net/ipv6 ]]; }

hevs_valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }
hevs_valid_pass() { [[ "$1" =~ ^[A-Za-z0-9._-]{4,64}$ ]]; }

hevs_users() { awk 'NF>=2 {print $1}' "$HEVS_AUTH" 2>/dev/null; }
hevs_reload() { svc_is_active "$HEVS_UNIT" && systemctl reload "$HEVS_UNIT" >/dev/null 2>&1; return 0; }

# Prueba el protocolo SOCKS5 a mano (bash puro). $1=puerto, resto = nada (sin auth) | usuario clave.
# Imprime la respuesta de la negociación en hexadecimal (y la de la autenticación si corresponde).
hevs_probe() { # puerto [usuario clave]
    local port="$1" u="${2:-}" p="${3:-}" r1 r2=""
    { exec 9<>"/dev/tcp/127.0.0.1/${port}"; } 2>/dev/null || { echo "sin-conexion"; return 1; }
    if [[ -z "$u" ]]; then
        printf '\x05\x01\x00' >&9
        r1="$(timeout 4 head -c 2 <&9 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    else
        printf '\x05\x01\x02' >&9
        r1="$(timeout 4 head -c 2 <&9 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        if [[ "$r1" == 0502 ]]; then
            printf "\\x01\\x$(printf '%02x' ${#u})%s\\x$(printf '%02x' ${#p})%s" "$u" "$p" >&9
            r2="$(timeout 4 head -c 2 <&9 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        fi
    fi
    exec 9>&- 9<&-
    echo "${r1}${r2:+ $r2}"
}

hevs_write_config() { # puerto modo(local|public) ip_publica
    local port="$1" mode="$2" pubip="$3" laddr dtype=ipv4 workers
    workers="$(nproc 2>/dev/null || echo 2)"; (( workers > 4 )) && workers=4
    [[ -n "$(ip -6 addr show scope global 2>/dev/null)" ]] && dtype=unspec
    install -d -m 750 -o root -g "$HEVS_USER" "$HEVS_DIR"
    if [[ "$mode" == public ]]; then laddr="'::'"; else laddr="'127.0.0.1'"; fi
    {
        echo "# Generado por ${APP_NAME}. No borres la sección auth: sin ella el servidor queda abierto a cualquiera."
        echo "main:"
        echo "  workers: ${workers}"
        echo "  port: ${port}"
        echo "  listen-address: ${laddr}"
        echo "  listen-ipv6-only: false"
        echo "  domain-address-type: ${dtype}"
        if [[ "$mode" == public ]]; then
            echo "  udp-port: ${port}"
            [[ "$pubip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && echo "  udp-public-address-v4: '${pubip}'"
        else
            echo "  udp-listen-address: '127.0.0.1'"
        fi
        echo "auth:"
        echo "  file: ${HEVS_AUTH}"
    } > "$HEVS_DIR/main.yml"
    chown root:"$HEVS_USER" "$HEVS_DIR/main.yml"; chmod 640 "$HEVS_DIR/main.yml"
}

hevs_write_unit() { # puerto
    local port="$1" cap=""
    (( port < 1024 )) && cap="CAP_NET_BIND_SERVICE"
    cat > "/etc/systemd/system/${HEVS_UNIT}.service" <<EOF
[Unit]
Description=${APP_NAME} SOCKS5 (HevSocks5Server)
After=network.target

[Service]
Type=simple
User=${HEVS_USER}
ExecStart=${HEVS_BIN} ${HEVS_DIR}/main.yml
ExecReload=/bin/kill -USR1 \$MAINPID
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

hevs_card() { # usuario clave
    local mode port host
    mode="$(conf_get HEVS_MODE)"; port="$(conf_get HEVS_PORT)"
    host="127.0.0.1"; [[ "$mode" == public ]] && host="$(conf_get HEVS_HOST)"
    bar
    printf ' %sServidor:%s %s:%s  (%s)\n' "$Y" "$N" "$host" "$port" "$([[ "$mode" == public ]] && echo público || echo 'solo local')"
    printf ' %sUsuario :%s %s\n' "$Y" "$N" "$1"
    printf ' %sClave   :%s %s\n' "$Y" "$N" "$2"
    bar
}

hevs_user_add() { # nombre clave
    local name="$1" pass="$2"
    hevs_installed || { err "SOCKS5 no está instalado."; return 1; }
    hevs_valid_name "$name" || { err "Usuario inválido (letras, números, . _ -, hasta 32)."; return 1; }
    hevs_valid_pass "$pass" || { err "Clave inválida (letras, números, . _ - ; de 4 a 64 caracteres, sin espacios)."; return 1; }
    hevs_users | grep -qx -- "$name" && { err "Ese usuario SOCKS5 ya existe."; return 1; }
    printf '%s %s\n' "$name" "$pass" >> "$HEVS_AUTH"
    hevs_reload
    ok "Usuario SOCKS5 $name agregado."
    hevs_card "$name" "$pass"
}

hevs_user_del() {
    local name="$1"
    hevs_installed || { err "SOCKS5 no está instalado."; return 1; }
    hevs_users | grep -qx -- "$name" || { err "Ese usuario no existe."; return 1; }
    [[ "$(hevs_users | wc -l)" -le 1 ]] && { err "No se puede quitar el último usuario. Si querés cerrar el servicio, usá 'Quitar'."; return 1; }
    awk -v u="$name" '$1 != u' "$HEVS_AUTH" > "$HEVS_AUTH.tmp" && cat "$HEVS_AUTH.tmp" > "$HEVS_AUTH"; rm -f "$HEVS_AUTH.tmp"
    hevs_reload
    ok "Usuario SOCKS5 $name eliminado (las sesiones abiertas de ese usuario terminan al cerrarse)."
}

install_hevsocks5() {
    local port mode choice pubip="" host user pass
    echo "SOCKS5 + UDP (HevSocks5Server): el servidor para apps con motor SOCKS (HevSocks5Tunnel)."
    hevs_ipv6_ok || { err "Este kernel no tiene IPv6 habilitado (ipv6.disable=1) y el servidor lo necesita para arrancar."; return 1; }
    pkg_install openssl curl iproute2 || return 1
    hevs_get_binary || return 1
    ensure_service_user "$HEVS_USER"

    echo "Modo de escucha:"
    echo " 1) Solo local (127.0.0.1)  -> se usa a través de un túnel: SSL/TLS [5], SSH, PYTHON... con 'Destino' = este puerto (recomendado)"
    echo " 2) Público                 -> cualquiera puede conectarse con usuario y clave; la clave viaja SIN cifrar"
    read -rp " Opción [1]: " choice
    if [[ "$choice" == 2 ]]; then
        mode=public
        warn "En modo público el usuario y la clave de SOCKS5 viajan sin cifrar. Usá claves exclusivas para esto."
    else
        mode=local
    fi
    port="$(ask_port "Puerto SOCKS5" 1080)"
    if [[ "$mode" == public ]]; then
        pubip="$(curl -4 -fsS -m 4 https://api.ipify.org 2>/dev/null)"
        [[ "$pubip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || pubip="$(server_ip)"
        read -rp "IP pública de este VPS (para UDP) [${pubip}]: " host; host="${host:-$pubip}"
        [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { err "IP inválida."; return 1; }
        pubip="$host"
    fi

    install -d -m 750 -o root -g "$HEVS_USER" "$HEVS_DIR"
    if [[ "$(hevs_users | wc -l)" -ge 1 ]]; then
        info "Se conservan los $(hevs_users | wc -l) usuario(s) SOCKS5 actuales ($(hevs_users | paste -sd' ' -))."
        read -r user pass < <(awk 'NF>=2 {print $1, $2; exit}' "$HEVS_AUTH")
    else
        read -rp "Usuario SOCKS5 [socks]: " user; user="${user:-socks}"
        hevs_valid_name "$user" || { err "Usuario inválido (letras, números, . _ -, hasta 32)."; return 1; }
        read -rp "Clave (Enter = generar una al azar): " pass; pass="${pass:-$(rand_pass)}"
        hevs_valid_pass "$pass" || { err "Clave inválida (letras, números, . _ - ; de 4 a 64 caracteres, sin espacios)."; return 1; }
        printf '%s %s\n' "$user" "$pass" > "$HEVS_AUTH"
    fi
    chown root:"$HEVS_USER" "$HEVS_AUTH"; chmod 640 "$HEVS_AUTH"
    hevs_write_config "$port" "$mode" "$pubip" || return 1
    hevs_write_unit "$port"
    svc_enable_restart "$HEVS_UNIT"; sleep 2
    conf_set HEVS_PORT "$port"; conf_set HEVS_MODE "$mode"; conf_set HEVS_HOST "${pubip:-$(server_ip)}"
    if ! svc_is_active "$HEVS_UNIT"; then
        err "No arrancó. Revisá: journalctl -u ${HEVS_UNIT} -n 30"; return 1
    fi

    # Comprobación de seguridad: sin credenciales NO debe aceptar nada.
    local noauth withauth
    noauth="$(hevs_probe "$port")"
    if [[ "$noauth" != "05ff" ]]; then
        err "El servidor no rechazó una conexión sin credenciales (respuesta: ${noauth}). Se desinstala por seguridad."
        remove_hevsocks5; return 1
    fi
    withauth="$(hevs_probe "$port" "$user" "$pass")"
    if [[ "$withauth" == "0502 0100" ]]; then ok "Comprobado: rechaza sin credenciales y acepta usuario y clave."
    else warn "El servidor rechaza a los anónimos, pero la prueba con tu usuario no dio lo esperado (${withauth}). Revisá con 'Ver datos'."; fi

    if [[ "$mode" == public ]]; then
        conf_set HEVS_FWPORT "$port"
        ufw status 2>/dev/null | grep -q "Status: active" && { ufw allow "$port/tcp" >/dev/null 2>&1; ufw allow "$port/udp" >/dev/null 2>&1; }
        warn "Abrí TCP y UDP $port en el firewall de la nube (NSG de Azure)."
    else
        conf_set HEVS_FWPORT ""
        info "Solo escucha en 127.0.0.1:${port}. Para usarlo desde afuera: en SSL/TLS [5] o SOCKS PYTHON [3] elegí Destino = ${port}."
    fi
    ok "SOCKS5 activo en el puerto ${port}."
    hevs_card "$user" "$pass"
}

hevsocks_info() {
    local mode port
    mode="$(conf_get HEVS_MODE)"; port="$(conf_get HEVS_PORT)"
    echo "Modo: $([[ "$mode" == public ]] && echo "público ($(conf_get HEVS_HOST):${port}, TCP y UDP)" || echo "solo local (127.0.0.1:${port})")"
    echo "Usuarios SOCKS5: $(hevs_users | paste -sd' ' -)"
    echo "Versión: HevSocks5Server ${HEVS_TAG}"
    echo "Soporta CONNECT, UDP ASSOCIATE y UDP-en-TCP. En la app: Motor SOCKS = HevSocks5Tunnel, servidor SOCKS5 con usuario y clave."
}

remove_hevsocks5() {
    local p k; p="$(conf_get HEVS_FWPORT)"
    systemctl disable --now "$HEVS_UNIT" >/dev/null 2>&1 || true
    if [[ -n "$p" ]] && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "$p/tcp" >/dev/null 2>&1; ufw delete allow "$p/udp" >/dev/null 2>&1
    fi
    rm -f "/etc/systemd/system/${HEVS_UNIT}.service" "$HEVS_BIN"; rm -rf "$HEVS_DIR"; systemctl daemon-reload
    id "$HEVS_USER" >/dev/null 2>&1 && userdel "$HEVS_USER" >/dev/null 2>&1
    for k in HEVS_PORT HEVS_MODE HEVS_HOST HEVS_FWPORT; do conf_set "$k" ""; done
    ok "SOCKS5 (HevSocks5Server) eliminado."
}

hevsocks_menu() {
    local op name pass
    if ! hevs_installed; then install_hevsocks5; pause; return; fi
    while true; do
        title "SOCKS5 + UDP (HevSocks5Server)"
        echo " Estado: $(svc_is_active "$HEVS_UNIT" && echo "${G}ACTIVO${N}" || echo "${R}DETENIDO${N}")   Puerto: $(conf_get HEVS_PORT) ($([[ "$(conf_get HEVS_MODE)" == public ]] && echo público || echo local))"
        bar
        echo " 1) Ver datos            4) Listar usuarios"
        echo " 2) Agregar usuario      5) Reinstalar / cambiar puerto o modo"
        echo " 3) Eliminar usuario     6) Quitar"
        echo " 0) Volver"
        bar; read -rp " Opción: " op || return
        case "$op" in
            1) hevsocks_info; pause ;;
            2) read -rp "Usuario: " name; read -rp "Clave (Enter = al azar): " pass
               hevs_user_add "$name" "${pass:-$(rand_pass)}"; pause ;;
            3) read -rp "Usuario a eliminar: " name; hevs_user_del "$name"; pause ;;
            4) hevs_users | sed 's/^/ - /'; pause ;;
            5) systemctl stop "$HEVS_UNIT" 2>/dev/null; install_hevsocks5 || systemctl start "$HEVS_UNIT" 2>/dev/null; pause ;;
            6) confirm "¿Quitar SOCKS5?" && remove_hevsocks5; pause; return ;;
            0) return ;;
        esac
    done
}
