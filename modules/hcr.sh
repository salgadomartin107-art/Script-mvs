#!/usr/bin/env bash
# HCR Server (modo "HCR" de la app del ePro Dev Team). El binario es CERRADO y no se puede auditar:
# por eso este módulo (1) no lo descarga por su cuenta, (2) muestra su SHA-256 y exige confirmación,
# (3) lo prueba y lo ejecuta SIEMPRE como un usuario sin privilegios (nunca root) y (4) lo deja
# reenviando solo a un destino local fijo (SSH), sin permitir otros destinos.
# shellcheck shell=bash

HCR_USER="${APP_SLUG}-hcr"
HCR_UNIT="${APP_SLUG}-hcr"
HCR_BIN="/usr/local/bin/${APP_SLUG}-hcr-server"
HCR_DIR="/etc/${APP_SLUG}-hcr"
HCR_MAX_BIN=$((64 * 1024 * 1024))

# Deja en $2 el binario hcr-server a partir de un .tar.gz oficial o de un ELF suelto (se detecta por el contenido).
hcr_normalize() { # entrada salida
    local in="$1" out="$2" magic
    (( $(stat -c %s "$in") <= HCR_MAX_BIN )) || { err "El archivo es demasiado grande."; return 1; }
    magic="$(head -c 4 "$in" | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        1f8b*)   # tar.gz: se extrae SOLO el binario, con límite de tamaño
            tar -xzOf "$in" hcr-server 2>/dev/null | head -c "$((HCR_MAX_BIN + 1))" > "$out"
            [[ -s "$out" ]] && (( $(stat -c %s "$out") <= HCR_MAX_BIN )) || { err "El paquete no trae un hcr-server válido."; return 1; }
            [[ "$(head -c 4 "$out" | od -An -tx1 | tr -d ' \n')" == 7f454c46 ]] || { err "Lo extraído no es un ejecutable."; return 1; } ;;
        7f454c46) cp -- "$in" "$out" ;;
        *) err "El archivo no es un .tar.gz ni un ejecutable de Linux."; return 1 ;;
    esac
}

# Baja un archivo enviado a TU bot de Telegram (el mismo de [K]). Solo se acepta el que mandes desde tu chat.
tg_download() { # file_path destino
    local token; token="$(conf_get TG_TOKEN)"
    printf 'url = "https://api.telegram.org/file/bot%s/%s"\n' "$token" "$1" |
        curl -sS -K - --max-time 180 --max-filesize "$HCR_MAX_BIN" -o "$2"
}

hcr_from_telegram() { # destino
    local dst="$1" chat resp fid fsize fpath bot_was=0 rc=1
    tg_configured || { err "Primero configurá tu bot con [K] TELEGRAM (token y chat id)."; return 1; }
    chat="$(conf_get TG_CHAT)"
    # el bot del panel consume los mensajes con getUpdates: se pausa unos segundos para no robarle el archivo
    if svc_is_active "${APP_SLUG}-bot"; then bot_was=1; systemctl stop "${APP_SLUG}-bot"; fi
    echo "Abrí Telegram y enviá el archivo (hcr-server-linux-amd64.tar.gz) a tu bot. Máx. 20 MB."
    read -rp "Cuando ya lo enviaste, presioná Enter: " _
    resp="$(tg_api getUpdates -d limit=100 -d timeout=0 --data-urlencode 'allowed_updates=["message"]')" || resp=""
    fid="$(jq -r --arg c "$chat" '[.result[]? | select((.message.chat.id|tostring) == $c and .message.document != null)] | last | .message.document.file_id // empty' <<<"$resp" 2>/dev/null)"
    fsize="$(jq -r --arg c "$chat" '[.result[]? | select((.message.chat.id|tostring) == $c and .message.document != null)] | last | .message.document.file_size // 0' <<<"$resp" 2>/dev/null)"
    if [[ -z "$fid" ]]; then err "No encontré ningún archivo enviado desde tu chat."
    elif (( fsize > HCR_MAX_BIN )); then err "El archivo es demasiado grande."
    else
        fpath="$(tg_api getFile -d "file_id=$fid" | jq -r '.result.file_path // empty' 2>/dev/null)"
        [[ "$fpath" =~ ^[A-Za-z0-9_./-]+$ ]] || { err "Telegram no devolvió la ruta del archivo."; fpath=""; }
        [[ -n "$fpath" ]] && tg_download "$fpath" "$dst" && [[ -s "$dst" ]] && rc=0
        (( rc == 0 )) || err "No se pudo descargar el archivo."
    fi
    (( bot_was )) && systemctl start "${APP_SLUG}-bot"
    return "$rc"
}

hcr_get_binary() { # origen -> $2 (ruta local, https:// o la palabra TELEGRAM)
    local src="$1" dst="$2" raw
    raw="$(mktemp)"
    case "$src" in
        TELEGRAM|telegram|Telegram) hcr_from_telegram "$raw" || { rm -f "$raw"; return 1; } ;;
        https://www.mediafire.com/*|https://mediafire.com/*)
            # la página de MediaFire es HTML: se busca el enlace directo (solo de download*.mediafire.com)
            src="$(curl -fsSL --proto '=https' --max-filesize 2000000 "$src" 2>/dev/null \
                | grep -oE 'https://download[0-9]*\.mediafire\.com/[A-Za-z0-9_./%~+-]+' | head -1)"
            [[ -n "$src" ]] || { err "No encontré el enlace de descarga en la página de MediaFire."; rm -f "$raw"; return 1; }
            curl -fL --proto '=https' --max-filesize "$HCR_MAX_BIN" -o "$raw" "$src" || { rm -f "$raw"; return 1; } ;;
        https://*) curl -fL --proto '=https' --max-filesize "$HCR_MAX_BIN" -o "$raw" "$src" || { rm -f "$raw"; return 1; } ;;
        *) [[ -f "$src" && ! -L "$src" ]] || { err "No existe el archivo: $src"; rm -f "$raw"; return 1; }
           cp -- "$src" "$raw" ;;
    esac
    hcr_normalize "$raw" "$dst"; local rc=$?
    rm -f "$raw"; return "$rc"
}

# Jaula de red: el binario es cerrado y ofuscado, así que no se le permite iniciar conexiones salientes.
# Solo puede (a) hablar por loopback con SSH y (b) responder en las conexiones que los clientes le abren.
HCR_JAIL="/usr/local/sbin/${APP_SLUG}-hcr-jail"
hcr_jail_install() {
    cat > "$HCR_JAIL" <<EOF
#!/bin/sh
# on|off: bloquea conexiones nuevas salientes (no loopback) del usuario ${HCR_USER}
U="${HCR_USER}"; C="${APP_SLUG^^}-HCR-OUT"
for T in iptables ip6tables; do
    command -v "\$T" >/dev/null 2>&1 || { [ "\$T" = ip6tables ] && continue; echo "falta iptables" >&2; exit 1; }
    "\$T" -w -D OUTPUT -m owner --uid-owner "\$U" -j "\$C" 2>/dev/null
    "\$T" -w -F "\$C" 2>/dev/null; "\$T" -w -X "\$C" 2>/dev/null
    [ "\$1" = on ] || continue
    "\$T" -w -N "\$C" && "\$T" -w -A "\$C" -o lo -j RETURN \
        && "\$T" -w -A "\$C" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN \
        && "\$T" -w -A "\$C" -j REJECT \
        && "\$T" -w -I OUTPUT 1 -m owner --uid-owner "\$U" -j "\$C" || { echo "no se pudo aplicar la jaula (\$T)" >&2; exit 1; }
done
exit 0
EOF
    chmod 755 "$HCR_JAIL"
}

hcr_tls_setup() { # host -> deja $HCR_DIR/fullchain.pem y privkey.pem
    local host="$1" op c k san
    echo " 1) Generar certificado autofirmado (en la app: activá \"Permitir inseguro\")"
    echo " 2) Usar mi certificado (fullchain.pem y privkey.pem de un dominio real)"
    read -rp " Opción [1]: " op
    install -d -m 750 -o root -g "$HCR_USER" "$HCR_DIR"
    if [[ "$op" == 2 ]]; then
        read -rp "Ruta de fullchain.pem: " c; read -rp "Ruta de privkey.pem: " k
        [[ -f "$c" && -f "$k" ]] || { err "No encuentro esos archivos."; return 1; }
        [[ "$(openssl x509 -in "$c" -pubkey -noout 2>/dev/null)" == "$(openssl pkey -in "$k" -passin pass: -pubout 2>/dev/null)" \
           && -n "$(openssl x509 -in "$c" -noout -subject 2>/dev/null)" ]] \
            || { err "El certificado no se puede leer o no corresponde a la clave."; return 1; }
        install -m 640 -o root -g "$HCR_USER" "$c" "$HCR_DIR/fullchain.pem"
        install -m 640 -o root -g "$HCR_USER" "$k" "$HCR_DIR/privkey.pem"
    else
        [[ "$host" =~ ^[0-9.]+$ ]] && san="IP:$host" || san="DNS:$host"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
            -subj "/CN=${host}" -addext "subjectAltName=${san}" \
            -keyout "$HCR_DIR/privkey.pem" -out "$HCR_DIR/fullchain.pem" >/dev/null 2>&1 || { err "No se pudo generar el certificado."; return 1; }
        chown "root:$HCR_USER" "$HCR_DIR/privkey.pem" "$HCR_DIR/fullchain.pem"; chmod 640 "$HCR_DIR/privkey.pem" "$HCR_DIR/fullchain.pem"
    fi
}

install_hcr() {
    local src tmp sum want port tport choice transport tlsargs="" host ver cap=""
    echo "HCR Server: binario cerrado del ePro Dev Team (https://t.me/ePro_Dev_Team)."
    warn "Está ofuscado y comprimido con UPX: no se puede auditar. Por eso corre sin privilegios, con el sistema"
    warn "protegido y SIN permiso para abrir conexiones salientes (solo atiende clientes y habla con SSH local)."
    local bundled="${ROOT}/vendor/hcr-server-linux-amd64.tar.gz"
    if [[ -f "$bundled" ]]; then
        echo "Este panel trae incluido el paquete: hcr-server-linux-amd64.tar.gz"
        echo "  SHA-256 del paquete: $(sha256sum "$bundled" | awk '{print $1}')"
        echo "Origen: Enter = usar el incluido | ruta, URL https o la palabra TELEGRAM para otro | 0 = cancelar"
        read -rp "Origen [incluido]: " src
        [[ "$src" == 0 ]] && { info "Cancelado."; return 0; }
        [[ -n "$src" ]] || src="$bundled"
    else
        echo "Origen: ruta del .tar.gz o del binario en este VPS, una URL https, o la palabra TELEGRAM"
        echo "(TELEGRAM = lo enviás a tu propio bot y el VPS lo descarga; no hace falta otra app)."
        read -rp "Origen: " src
        [[ -n "$src" ]] || { info "Cancelado."; return 0; }
    fi
    pkg_install openssl curl iptables || return 1
    ensure_service_user "$HCR_USER"
    tmp="$(mktemp -d)"; chmod 711 "$tmp"
    hcr_get_binary "$src" "$tmp/hcr-server" || { err "No se pudo obtener el binario."; rm -rf "$tmp"; return 1; }
    sum="$(sha256sum "$tmp/hcr-server" | awk '{print $1}')"
    echo "SHA-256 del binario: $sum"
    read -rp "SHA-256 esperado (Enter = omitir la comparación): " want
    if [[ -n "$want" && "${want,,}" != "$sum" ]]; then err "El SHA-256 NO coincide. Cancelado."; rm -rf "$tmp"; return 1; fi
    confirm "¿Instalar este binario?" || { rm -rf "$tmp"; return 0; }

    chmod 755 "$tmp/hcr-server"
    # prueba de identidad ejecutando como usuario sin privilegios, con límite de tiempo
    ver="$(runuser -u "$HCR_USER" -- timeout 5 "$tmp/hcr-server" -version 2>/dev/null)" || ver=""
    if [[ ! "$ver" =~ ^hcr-server\ version\ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
        err "El binario no responde como hcr-server (-version). Cancelado."; rm -rf "$tmp"; return 1
    fi
    install -m 755 -o root -g root "$tmp/hcr-server" "$HCR_BIN"; rm -rf "$tmp"
    ok "Versión: $ver"

    port="$(ask_port "Puerto de HCR (8080/8443; con 443 hace falta que esté libre)" 8443)"
    read -rp "Destino: 1) OpenSSH ($(sshd_ports | head -1))  2) Dropbear [1]: " choice
    if [[ "$choice" == 2 ]]; then
        tport="$(conf_get DROPBEAR_PORT)"; [[ -n "$tport" ]] || { err "Instalá Dropbear primero."; return 1; }
    else
        tport="$(sshd_ports | head -1)"
    fi
    echo "Transporte: 1) auto (TLS y sin TLS)  2) solo TLS  3) solo sin TLS"
    read -rp " Opción [1]: " choice
    case "$choice" in 2) transport=tls ;; 3) transport=plain ;; *) transport=auto ;; esac
    if [[ "$transport" != plain ]]; then
        host="$(ask_host)"
        [[ "$host" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || { err "Dominio o IP inválido."; return 1; }
        hcr_tls_setup "$host" || return 1
        tlsargs=" --tls-cert ${HCR_DIR}/fullchain.pem --tls-key ${HCR_DIR}/privkey.pem"
    fi
    (( port < 1024 )) && cap="CAP_NET_BIND_SERVICE"

    hcr_jail_install
    "$HCR_JAIL" on || { err "No se pudo aplicar la jaula de red (iptables). No se instala."; return 1; }
    cat > "/etc/systemd/system/${HCR_UNIT}.service" <<EOF
[Unit]
Description=${APP_NAME} HCR relay
After=network.target

[Service]
Type=exec
User=${HCR_USER}
ExecStart=${HCR_BIN} --listen :${port} --target 127.0.0.1:${tport} --transport ${transport}${tlsargs} --max-download-frame 16384 --download-poll-timeout 8s
ExecStartPre=+${HCR_JAIL} on
ExecStopPost=+${HCR_JAIL} off
AmbientCapabilities=${cap}
CapabilityBoundingSet=${cap}
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectControlGroups=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
UMask=0077
LimitNOFILE=4096
LimitCORE=0
TasksMax=512
MemoryMax=384M
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=60
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "$HCR_UNIT"; sleep 2
    conf_set HCR_PORT "$port"; conf_set HCR_TARGET "$tport"; conf_set HCR_TRANSPORT "$transport"; conf_set HCR_SHA256 "$sum"
    ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$port/tcp" >/dev/null 2>&1
    if svc_is_active "$HCR_UNIT"; then
        ok "HCR activo en el puerto $port -> 127.0.0.1:$tport ($transport)."
        warn "Abrí el puerto $port en el firewall de la nube (NSG de Azure)."
        info "En la app: Mode = HCR, Host:puerto = ${host:-tu-ip}:${port}$([[ "$transport" != plain ]] && echo ', Activar TLS')."
    else
        err "No arrancó. Revisá: journalctl -u ${HCR_UNIT} -n 30"; return 1
    fi
}

hcr_info() {
    echo "Puerto: $(conf_get HCR_PORT) -> 127.0.0.1:$(conf_get HCR_TARGET)  transporte: $(conf_get HCR_TRANSPORT)"
    echo "SHA-256 instalado: $(conf_get HCR_SHA256)"
    echo "En la app: Mode = HCR, Host:puerto = $(server_ip):$(conf_get HCR_PORT)"
    journalctl -u "$HCR_UNIT" -n 8 --no-pager 2>/dev/null | tail -8
}

remove_hcr() {
    systemctl disable --now "$HCR_UNIT" >/dev/null 2>&1 || true
    [[ -x "$HCR_JAIL" ]] && "$HCR_JAIL" off
    rm -f "/etc/systemd/system/${HCR_UNIT}.service" "$HCR_BIN" "$HCR_JAIL"; rm -rf "$HCR_DIR"; systemctl daemon-reload
    for k in HCR_PORT HCR_TARGET HCR_TRANSPORT HCR_SHA256; do conf_set "$k" ""; done
    ok "HCR eliminado."
}
