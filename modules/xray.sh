#!/usr/bin/env bash
# V2RAY/XRAY: varias configuraciones a la vez (VLESS, VMess, Shadowsocks, REALITY), todo desde el panel.
# Núcleo: release oficial de GitHub (XTLS/Xray-core) verificada con SHA-256.
# Trojan [T] comparte este mismo servicio (inbound con etiqueta "trojan-in").
# shellcheck shell=bash

XRAY_USER="${APP_SLUG}-xray"
XRAY_UNIT="${APP_SLUG}-xray"
XRAY_BIN="/usr/local/bin/${APP_SLUG}-xray"
XRAY_DIR="/etc/${APP_SLUG}-xray"
XRAY_CONF="${XRAY_DIR}/config.json"
XRAY_META="${XRAY_DIR}/meta.json"   # datos para los enlaces: dominio, puerto público, ruta, claves públicas
XRAY_TROJAN_TAG="trojan-in"

# ---------- utilidades ----------
xray_write_conf() { # JSON por stdin -> config.json con los permisos correctos
    local tmp; tmp="$(mktemp)"; cat > "$tmp"
    install -m 640 -o root -g "$XRAY_USER" "$tmp" "$XRAY_CONF"; rm -f "$tmp"
}
xray_write_meta() {
    local tmp; tmp="$(mktemp)"; cat > "$tmp"
    install -m 600 -o root -g root "$tmp" "$XRAY_META"; rm -f "$tmp"
}
xm() { jq -r --arg t "$1" --arg k "$2" '.[$t][$k] // empty' "$XRAY_META" 2>/dev/null; }   # xm etiqueta campo
xray_uri() { jq -rn --arg v "$1" '$v|@uri'; }
xray_uuid() { cat /proc/sys/kernel/random/uuid; }

xray_desc() {
    case "$1" in
        vless-ws)        echo "VLESS + WebSocket (sin TLS)" ;;
        vless-ws-tls)    echo "VLESS + WebSocket + TLS" ;;
        vmess-ws)        echo "VMess + WebSocket (sin TLS)" ;;
        vmess-ws-tls)    echo "VMess + WebSocket + TLS" ;;
        vmess-tcp)       echo "VMess + TCP" ;;
        vmess-kcp)       echo "VMess + mKCP (UDP)" ;;
        vless-grpc-tls)  echo "VLESS + gRPC + TLS" ;;
        ss)              echo "Shadowsocks (TCP+UDP)" ;;
        reality)         echo "VLESS + REALITY" ;;
        *)               echo "$1" ;;
    esac
}

# Mantiene en la configuración del panel los puertos que usa Xray (los lee el firewall y la pantalla).
xray_sync_conf() {
    local tcp udp
    [[ -f "$XRAY_CONF" ]] || return 0
    tcp="$(jq -r '[.inbounds[]? | select(.tag != "trojan-in") | select((.streamSettings.network // "") != "kcp") | .port] | unique | join(" ")' "$XRAY_CONF" 2>/dev/null)"
    udp="$(jq -r '[.inbounds[]? | select(.tag != "trojan-in") | select((.streamSettings.network // "") == "kcp" or .protocol == "shadowsocks") | .port] | unique | join(" ")' "$XRAY_CONF" 2>/dev/null)"
    conf_set XRAY_PORT "$tcp"; conf_set XRAY_UDP_PORTS "$udp"
}

# Aplica un config.json nuevo (por stdin): lo valida con Xray, reinicia y revierte si algo falla.
xray_apply() {
    local new old
    new="$(mktemp)"; old="$(mktemp)"; cat > "$new"
    if ! jq -e . "$new" >/dev/null 2>&1; then
        err "No se generó un JSON válido; no se cambió nada."; rm -f "$new" "$old"; return 1
    fi
    cp -a "$XRAY_CONF" "$old"
    install -m 640 -o root -g "$XRAY_USER" "$new" "$XRAY_CONF"
    if "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1 \
       && systemctl restart "$XRAY_UNIT" 2>/dev/null && sleep 1 && svc_is_active "$XRAY_UNIT"; then
        rm -f "$new" "$old"; xray_sync_conf; return 0
    fi
    install -m 640 -o root -g "$XRAY_USER" "$old" "$XRAY_CONF"; systemctl restart "$XRAY_UNIT" 2>/dev/null
    rm -f "$new" "$old"
    err "Xray rechazó la configuración (o no arrancó). Se restauró la anterior."
    return 1
}

xray_installed() { [[ -x "$XRAY_BIN" && -f "$XRAY_CONF" ]]; }

# ---------- núcleo ----------
xray_fetch_core() { # descarga la release oficial, verifica SHA-256 e instala el binario
    local arch tmp base zip want got
    case "$(uname -m)" in
        x86_64)  arch=64 ;;
        aarch64) arch=arm64-v8a ;;
        *) err "Arquitectura no soportada: $(uname -m)"; return 1 ;;
    esac
    pkg_install unzip jq curl openssl || { err "Falló la instalación de dependencias."; return 1; }
    tmp="$(mktemp -d)"; zip="Xray-linux-${arch}.zip"
    base="https://github.com/XTLS/Xray-core/releases/latest/download"
    info "Descargando Xray (release oficial)..."
    if ! curl -fsSL -o "$tmp/$zip" "$base/$zip" || ! curl -fsSL -o "$tmp/$zip.dgst" "$base/$zip.dgst"; then
        err "No se pudo descargar Xray."; rm -rf "$tmp"; return 1
    fi
    want="$(grep -iE '^(sha2-256|sha256)' "$tmp/$zip.dgst" | head -1 | awk '{print $NF}')"
    got="$(sha256sum "$tmp/$zip" | awk '{print $1}')"
    if [[ -z "$want" || "$want" != "$got" ]]; then
        err "El SHA-256 no coincide. Instalación cancelada."; rm -rf "$tmp"; return 1
    fi
    unzip -qo "$tmp/$zip" xray -d "$tmp" && install -m 755 "$tmp/xray" "${XRAY_BIN}.new" && mv -f "${XRAY_BIN}.new" "$XRAY_BIN"
    rm -rf "$tmp"
}

install_xray() { # instala el núcleo y el servicio (sin configuraciones: se agregan desde el menú)
    xray_fetch_core || return 1
    ensure_service_user "$XRAY_USER"
    install -d -m 750 -o root -g "$XRAY_USER" "$XRAY_DIR"
    [[ -f "$XRAY_CONF" ]] || printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}' | xray_write_conf
    [[ -f "$XRAY_META" ]] || printf '{}\n' | xray_write_meta
    "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1 || { err "La configuración base de Xray no valida."; return 1; }

    cat > "/etc/systemd/system/${XRAY_UNIT}.service" <<EOF
[Unit]
Description=${APP_NAME} Xray
After=network.target

[Service]
User=${XRAY_USER}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LimitNOFILE=65535
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "$XRAY_UNIT"
    xray_sync_conf
    ok "Xray instalado ($("$XRAY_BIN" version 2>/dev/null | head -1 | cut -d' ' -f1-2)). Agregá configuraciones con la opción 1."
}

remove_xray() {
    systemctl disable --now "$XRAY_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${XRAY_UNIT}.service" "$XRAY_BIN"
    rm -rf "$XRAY_DIR"; systemctl daemon-reload
    for k in XRAY_PORT XRAY_UDP_PORTS XRAY_HOST TROJAN_PORT TROJAN_HOST; do conf_set "$k" ""; done
    ok "Xray eliminado (también las configuraciones y Trojan, que usa el mismo servicio)."
}

# Configuraciones creadas con la versión anterior (sin etiqueta): se etiquetan y se registran.
xray_migrate() {
    local newconf newmeta host
    xray_installed || return 0
    jq -e '[.inbounds[]? | select(has("tag") | not)] | length > 0' "$XRAY_CONF" >/dev/null 2>&1 || return 0
    host="$(conf_get XRAY_HOST)"; host="${host:-$(server_ip)}"
    newconf="$(jq '.inbounds |= map(if has("tag") then . else . + {tag: ("vless-ws-" + (.port|tostring))} end)' "$XRAY_CONF")" || return 1
    newmeta="$(jq -n --argjson c "$newconf" --argjson m "$(cat "$XRAY_META" 2>/dev/null || echo '{}')" --arg host "$host" '
        reduce ($c.inbounds[] | select(.tag | startswith("vless-ws-"))) as $i ($m;
            if has($i.tag) then . else . + {($i.tag): {proto:"vless-ws", host:$host, pport:$i.port,
                path:($i.streamSettings.wsSettings.path // "/ws"), name:$i.tag}} end)')" || return 1
    printf '%s\n' "$newconf" | xray_write_conf
    printf '%s\n' "$newmeta" | xray_write_meta
    xray_sync_conf
}

# ---------- construcción de configuraciones ----------
xray_tls_files() { # host -> imprime "cert key" (certificado autofirmado, 10 años)
    local h="$1" d="$XRAY_DIR/tls" san
    [[ "$h" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || return 1
    install -d -m 750 -o root -g "$XRAY_USER" "$d"
    if [[ ! -s "$d/$h.key" ]]; then
        [[ "$h" =~ ^[0-9.]+$ ]] && san="IP:$h" || san="DNS:$h"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
            -subj "/CN=${h}" -addext "subjectAltName=${san}" -keyout "$d/$h.key" -out "$d/$h.crt" >/dev/null 2>&1 || return 1
        chgrp "$XRAY_USER" "$d/$h.key" "$d/$h.crt"; chmod 640 "$d/$h.key" "$d/$h.crt"
    fi
    echo "$d/$h.crt $d/$h.key"
}

# xray_build protocolo etiqueta puerto id ruta cert key  (extras por variables XB_*)
xray_build() {
    local proto="$1" tag="$2" port="$3" id="$4" path="$5" cert="$6" key="$7"
    case "$proto" in
        vless-ws|vless-ws-tls)
            jq -n --arg tag "$tag" --argjson port "$port" --arg id "$id" --arg path "$path" --arg cert "$cert" --arg key "$key" --arg name "$XB_NAME" '
                {tag:$tag, port:$port, listen:"0.0.0.0", protocol:"vless",
                 settings:{clients:[{id:$id, email:$name}], decryption:"none"},
                 streamSettings:({network:"ws", wsSettings:{path:$path}} +
                    (if $cert != "" then {security:"tls", tlsSettings:{certificates:[{certificateFile:$cert, keyFile:$key}]}} else {} end))}' ;;
        vmess-ws|vmess-ws-tls)
            jq -n --arg tag "$tag" --argjson port "$port" --arg id "$id" --arg path "$path" --arg cert "$cert" --arg key "$key" --arg name "$XB_NAME" '
                {tag:$tag, port:$port, listen:"0.0.0.0", protocol:"vmess",
                 settings:{clients:[{id:$id, email:$name}]},
                 streamSettings:({network:"ws", wsSettings:{path:$path}} +
                    (if $cert != "" then {security:"tls", tlsSettings:{certificates:[{certificateFile:$cert, keyFile:$key}]}} else {} end))}' ;;
        vmess-tcp)
            jq -n --arg tag "$tag" --argjson port "$port" --arg id "$id" --arg name "$XB_NAME" '
                {tag:$tag, port:$port, listen:"0.0.0.0", protocol:"vmess",
                 settings:{clients:[{id:$id, email:$name}]}, streamSettings:{network:"tcp"}}' ;;
        vmess-kcp)
            jq -n --arg tag "$tag" --argjson port "$port" --arg id "$id" --arg seed "$path" --arg name "$XB_NAME" '
                {tag:$tag, port:$port, listen:"0.0.0.0", protocol:"vmess",
                 settings:{clients:[{id:$id, email:$name}]},
                 streamSettings:{network:"kcp", kcpSettings:{header:{type:"none"}, seed:$seed}}}' ;;
        vless-grpc-tls)
            jq -n --arg tag "$tag" --argjson port "$port" --arg id "$id" --arg svc "$path" --arg cert "$cert" --arg key "$key" --arg name "$XB_NAME" '
                {tag:$tag, port:$port, listen:"0.0.0.0", protocol:"vless",
                 settings:{clients:[{id:$id, email:$name}], decryption:"none"},
                 streamSettings:{network:"grpc", grpcSettings:{serviceName:$svc},
                    security:"tls", tlsSettings:{certificates:[{certificateFile:$cert, keyFile:$key}]}}}' ;;
        ss)
            jq -n --arg tag "$tag" --argjson port "$port" --arg pw "$id" --arg method "$XB_METHOD" '
                {tag:$tag, port:$port, listen:"0.0.0.0", protocol:"shadowsocks",
                 settings:{method:$method, password:$pw, network:"tcp,udp"}}' ;;
        reality)
            jq -n --arg tag "$tag" --argjson port "$port" --arg id "$id" --arg sni "$XB_SNI" --arg priv "$XB_PRIV" --arg sid "$XB_SID" --arg name "$XB_NAME" '
                {tag:$tag, port:$port, listen:"0.0.0.0", protocol:"vless",
                 settings:{clients:[{id:$id, email:$name, flow:"xtls-rprx-vision"}], decryption:"none"},
                 streamSettings:{network:"tcp", security:"reality",
                    realitySettings:{show:false, dest:($sni + ":443"), xver:0, serverNames:[$sni], privateKey:$priv, shortIds:[$sid]}}}' ;;
        *) return 1 ;;
    esac
}

# ---------- enlaces ----------
xray_emails() { # etiqueta -> usuarios de esa configuración
    jq -r --arg t "$1" '.inbounds[] | select(.tag == $t) | (.settings.clients // [])[] | .email' "$XRAY_CONF"
}

xray_link() { # etiqueta usuario -> enlace de importación
    local tag="$1" email="$2" proto host pport path sni pbk sid id frag p tls=""
    proto="$(xm "$tag" proto)"; host="$(xm "$tag" host)"; pport="$(xm "$tag" pport)"
    path="$(xm "$tag" path)"; sni="$(xm "$tag" sni)"; pbk="$(xm "$tag" pbk)"; sid="$(xm "$tag" sid)"
    id="$(jq -r --arg t "$tag" --arg e "$email" '.inbounds[] | select(.tag == $t) | (.settings.clients // [])[] | select(.email == $e) | .id' "$XRAY_CONF")"
    frag="$(xray_uri "$email")"; p="$(xray_uri "$path")"
    case "$proto" in
        vless-ws)       echo "vless://${id}@${host}:${pport}?encryption=none&security=none&type=ws&host=${host}&path=${p}#${frag}" ;;
        vless-ws-tls)   echo "vless://${id}@${host}:${pport}?encryption=none&security=tls&sni=${host}&allowInsecure=1&type=ws&host=${host}&path=${p}#${frag}" ;;
        vless-grpc-tls) echo "vless://${id}@${host}:${pport}?encryption=none&security=tls&sni=${host}&allowInsecure=1&type=grpc&serviceName=${p}&mode=gun#${frag}" ;;
        reality)        echo "vless://${id}@${host}:${pport}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp&headerType=none#${frag}" ;;
        vmess-ws|vmess-ws-tls|vmess-tcp|vmess-kcp)
            local net=tcp whost=""
            case "$proto" in
                vmess-ws*) net=ws; whost="$host" ;;
                vmess-kcp) net=kcp ;;
            esac
            [[ "$proto" == vmess-ws-tls ]] && tls=tls
            [[ "$proto" == vmess-tcp ]] && path=""
            printf 'vmess://%s\n' "$(jq -nc --arg ps "$email" --arg add "$host" --arg port "$pport" --arg id "$id" --arg net "$net" \
                --arg host "$whost" --arg path "$path" --arg tls "$tls" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:$net, type:"none", host:$host, path:$path, tls:$tls, sni:$host}' | base64 -w0)" ;;
        ss)
            local method pw
            method="$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.method' "$XRAY_CONF")"
            pw="$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.password' "$XRAY_CONF")"
            echo "ss://$(printf '%s:%s' "$method" "$pw" | base64 -w0 | tr '+/' '-_' | tr -d '=')@${host}:${pport}#${frag}" ;;
        *) return 1 ;;
    esac
}

xray_tags() { jq -r '.inbounds[]? | select(.tag != "trojan-in") | .tag' "$XRAY_CONF"; }

xray_show_tag() { # etiqueta
    local tag="$1" proto e
    proto="$(xm "$tag" proto)"
    echo "${C}● ${tag}${N}  $(xray_desc "$proto")"
    echo "  Puerto del servidor: $(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port' "$XRAY_CONF")   Puerto del cliente: $(xm "$tag" pport)   Dominio/IP: $(xm "$tag" host)"
    if [[ "$proto" == ss ]]; then
        echo "  $(xray_link "$tag" "$(xm "$tag" name)")"
    else
        while read -r e; do [[ -n "$e" ]] && echo "  [${e}] $(xray_link "$tag" "$e")"; done < <(xray_emails "$tag")
    fi
    case "$proto" in
        *-tls) echo "  ${Y}Nota:${N} el certificado es autofirmado. Detrás de Cloudflare (modo Full) no hay problema;" \
                    "si te conectás directo, el cliente debe permitir certificado inseguro." ;;
        vmess-kcp) echo "  ${Y}Nota:${N} mKCP usa UDP: abrí ese puerto UDP en el firewall de la nube." ;;
    esac
    echo
}

xray_show() {
    local t any=0
    while read -r t; do [[ -n "$t" ]] || continue; any=1; xray_show_tag "$t"; done < <(xray_tags)
    (( any )) || info "Todavía no hay configuraciones. Agregá una con la opción 1."
    if jq -e --arg t "$XRAY_TROJAN_TAG" '.inbounds[]? | select(.tag == $t)' "$XRAY_CONF" >/dev/null 2>&1; then
        info "Además hay un Trojan activo: se administra desde [T] en el panel."
    fi
}

xray_pick() { # menú numerado -> deja la etiqueta elegida en XPICK
    local -a tags=(); local i op t
    XPICK=""
    mapfile -t tags < <(xray_tags)
    (( ${#tags[@]} )) || { err "No hay configuraciones. Agregá una con la opción 1."; return 1; }
    for i in "${!tags[@]}"; do t="${tags[$i]}"; printf ' %d) %s  (%s)\n' "$((i + 1))" "$t" "$(xray_desc "$(xm "$t" proto)")"; done
    read -rp "Número de configuración (0 = cancelar): " op
    [[ "$op" =~ ^[0-9]+$ && "$op" -ge 1 && "$op" -le ${#tags[@]} ]] || return 1
    XPICK="${tags[$((op - 1))]}"
}

# ---------- operaciones del menú ----------
xray_add() {
    local op proto defport port pport host path="" name id tag cert="" key="" files keys meta
    xray_installed || { err "Xray no está instalado."; return 1; }
    title "Agregar configuración"
    echo " 1) VLESS-WS            sin TLS (Cloudflare / CDN)"
    echo " 2) VLESS-WS-TLS        TLS autofirmado (Cloudflare Full)"
    echo " 3) VMess-WS            sin TLS (Cloudflare / CDN)"
    echo " 4) VMess-WS-TLS        TLS autofirmado (Cloudflare Full)"
    echo " 5) VMess-TCP           simple"
    echo " 6) VMess-mKCP          UDP"
    echo " 7) VLESS-gRPC-TLS      TLS autofirmado (Cloudflare Full)"
    echo " 8) Shadowsocks         TCP + UDP"
    echo " 9) VLESS-REALITY       sin dominio ni certificado"
    echo " 0) Volver"
    echo " (Trojan: usá la opción [T] del panel.)"
    bar; read -rp " Opción: " op
    case "$op" in
        1) proto=vless-ws;       defport=8880 ;;
        2) proto=vless-ws-tls;   defport=2053 ;;
        3) proto=vmess-ws;       defport=2082 ;;
        4) proto=vmess-ws-tls;   defport=2083 ;;
        5) proto=vmess-tcp;      defport=10086 ;;
        6) proto=vmess-kcp;      defport=10010 ;;
        7) proto=vless-grpc-tls; defport=2096 ;;
        8) proto=ss;             defport=8388 ;;
        9) proto=reality;        defport=443 ;;
        *) return 0 ;;
    esac

    port="$(ask_port "Puerto de escucha del servidor" "$defport")"
    host="$(ask_host)"
    [[ "$host" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || { err "Dominio o IP inválido."; return 1; }
    read -rp "Puerto que usará el cliente (Enter = $port; con Cloudflare: 80/8080 sin TLS o 443 con TLS): " pport
    pport="${pport:-$port}"; valid_port "$pport" || { err "Puerto inválido."; return 1; }
    read -rp "Nombre de la configuración [$proto]: " name; name="${name:-$proto}"
    [[ "$name" =~ ^[A-Za-z0-9_-]{2,32}$ ]] || { err "Nombre inválido (letras, números, _ y -)."; return 1; }

    XB_NAME="$name"; id="$(xray_uuid)"; tag="${proto}-${port}"
    xray_tags | grep -qx "$tag" && { err "Ya existe una configuración con esa etiqueta."; return 1; }

    case "$proto" in
        vless-ws|vless-ws-tls|vmess-ws|vmess-ws-tls)
            read -rp "Ruta WebSocket [/$(openssl rand -hex 3)]: " path; path="${path:-/$(openssl rand -hex 3)}"
            [[ "$path" =~ ^/[A-Za-z0-9._/-]{1,64}$ ]] || { err "Ruta inválida (debe empezar con / y usar letras, números . _ - /)."; return 1; } ;;
        vless-grpc-tls)
            read -rp "Nombre del servicio gRPC [$(openssl rand -hex 3)]: " path; path="${path:-$(openssl rand -hex 3)}"
            [[ "$path" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { err "Nombre de servicio inválido."; return 1; } ;;
        vmess-kcp)
            path="$(openssl rand -hex 6)" ;;   # seed de mKCP
    esac

    case "$proto" in
        *-tls)
            files="$(xray_tls_files "$host")" || { err "No se pudo generar el certificado para $host."; return 1; }
            read -r cert key <<<"$files" ;;
    esac

    XB_SNI=""; XB_PRIV=""; XB_SID=""; XB_METHOD=""; local pbk="" sni=""
    case "$proto" in
        reality)
            read -rp "Sitio que se imita (SNI, debe soportar TLS 1.3) [www.microsoft.com]: " sni; sni="${sni:-www.microsoft.com}"
            [[ "$sni" =~ ^[A-Za-z0-9.-]{3,253}$ ]] || { err "Dominio inválido."; return 1; }
            keys="$("$XRAY_BIN" x25519 2>/dev/null)"
            XB_PRIV="$(awk -F': *' 'NR==1{print $2}' <<<"$keys")"; pbk="$(awk -F': *' 'NR==2{print $2}' <<<"$keys")"
            [[ ${#XB_PRIV} -ge 40 && ${#pbk} -ge 40 ]] || { err "No se pudieron generar las claves REALITY."; return 1; }
            XB_SID="$(openssl rand -hex 8)"; XB_SNI="$sni" ;;
        ss)
            XB_METHOD="chacha20-ietf-poly1305"; id="$(rand_pass)" ;;   # en Shadowsocks "id" es la clave
    esac

    local inbound
    inbound="$(xray_build "$proto" "$tag" "$port" "$id" "$path" "$cert" "$key")" || { err "No se pudo armar la configuración."; return 1; }
    jq --argjson i "$inbound" '.inbounds += [$i]' "$XRAY_CONF" | xray_apply || return 1

    meta="$(jq -nc --arg proto "$proto" --arg host "$host" --argjson pport "$pport" --arg path "$path" --arg sni "$sni" \
        --arg pbk "$pbk" --arg sid "$XB_SID" --arg name "$name" '{proto:$proto, host:$host, pport:$pport, path:$path, sni:$sni, pbk:$pbk, sid:$sid, name:$name}')"
    jq --arg t "$tag" --argjson m "$meta" '. + {($t): $m}' "$XRAY_META" | xray_write_meta
    ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$port" >/dev/null 2>&1
    ok "Configuración $tag creada y activa."
    echo; xray_show_tag "$tag"
    warn "Abrí el puerto $port (y el $pport si usás otro) en el firewall de tu nube (NSG de Azure)."
}

xray_delete() {
    xray_pick || return 0
    confirm "¿Eliminar la configuración $XPICK?" || return 0
    jq --arg t "$XPICK" '.inbounds |= map(select(.tag != $t))' "$XRAY_CONF" | xray_apply || return 1
    jq --arg t "$XPICK" 'del(.[$t])' "$XRAY_META" | xray_write_meta
    ok "Configuración $XPICK eliminada."
}

xray_users() {
    local tag proto op name id n
    xray_pick || return 0; tag="$XPICK"; proto="$(xm "$tag" proto)"
    [[ "$proto" == ss ]] && { info "Shadowsocks usa una sola clave. Para otra clave, agregá otra configuración."; return 0; }
    echo "Usuarios actuales: $(xray_emails "$tag" | xargs)"
    echo " 1) Agregar usuario   2) Quitar usuario   0) Volver"
    read -rp " Opción: " op
    case "$op" in
        1) read -rp "Nombre del usuario nuevo: " name
           [[ "$name" =~ ^[A-Za-z0-9_-]{2,32}$ ]] || { err "Nombre inválido."; return 1; }
           xray_emails "$tag" | grep -qx "$name" && { err "Ya existe ese usuario."; return 1; }
           id="$(xray_uuid)"
           jq --arg t "$tag" --arg n "$name" --arg id "$id" \
               '(.inbounds[] | select(.tag == $t) | .settings.clients) |= (. + [(.[0] | .id = $id | .email = $n)])' "$XRAY_CONF" | xray_apply || return 1
           ok "Usuario $name agregado."; echo "  $(xray_link "$tag" "$name")" ;;
        2) read -rp "Usuario a quitar: " name
           n="$(xray_emails "$tag" | wc -l)"
           (( n > 1 )) || { err "No se puede quitar el único usuario; eliminá la configuración."; return 1; }
           xray_emails "$tag" | grep -qx "$name" || { err "Ese usuario no existe."; return 1; }
           jq --arg t "$tag" --arg n "$name" '(.inbounds[] | select(.tag == $t) | .settings.clients) |= map(select(.email != $n))' "$XRAY_CONF" | xray_apply \
               && ok "Usuario $name quitado." ;;
    esac
}

xray_change() {
    local tag proto op val cur name cert key files
    xray_pick || return 0; tag="$XPICK"; proto="$(xm "$tag" proto)"
    echo " 1) Puerto del servidor       4) Dominio o IP"
    echo " 2) UUID / clave              5) Puerto del cliente"
    echo " 3) Ruta (WebSocket/gRPC)     0) Volver"
    read -rp " Opción: " op
    case "$op" in
        1) cur="$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port' "$XRAY_CONF")"
           read -rp "Puerto nuevo (actual $cur): " val
           valid_port "$val" || { err "Puerto inválido."; return 1; }
           [[ "$val" == "$cur" ]] && { info "Es el mismo puerto."; return 0; }
           port_in_use "$val" && { err "El puerto $val ya está en uso."; return 1; }
           jq --arg t "$tag" --argjson p "$val" '(.inbounds[] | select(.tag == $t) | .port) = $p' "$XRAY_CONF" | xray_apply || return 1
           [[ "$(xm "$tag" pport)" == "$cur" ]] && jq --arg t "$tag" --argjson p "$val" '.[$t].pport = $p' "$XRAY_META" | xray_write_meta
           ok "Puerto cambiado a $val. Acordate de abrirlo en el firewall de la nube." ;;
        2) if [[ "$proto" == ss ]]; then
               val="$(rand_pass)"
               jq --arg t "$tag" --arg v "$val" '(.inbounds[] | select(.tag == $t) | .settings.password) = $v' "$XRAY_CONF" | xray_apply || return 1
           else
               echo "Usuarios: $(xray_emails "$tag" | xargs)"; read -rp "Usuario: " name
               xray_emails "$tag" | grep -qx "$name" || { err "Ese usuario no existe."; return 1; }
               val="$(xray_uuid)"
               jq --arg t "$tag" --arg n "$name" --arg v "$val" \
                   '(.inbounds[] | select(.tag == $t) | .settings.clients[] | select(.email == $n) | .id) = $v' "$XRAY_CONF" | xray_apply || return 1
           fi
           ok "Credencial regenerada. Nuevo enlace:"; xray_show_tag "$tag" ;;
        3) case "$proto" in
               vless-ws|vless-ws-tls|vmess-ws|vmess-ws-tls)
                   read -rp "Ruta nueva (ej: /abc123): " val
                   [[ "$val" =~ ^/[A-Za-z0-9._/-]{1,64}$ ]] || { err "Ruta inválida."; return 1; }
                   jq --arg t "$tag" --arg v "$val" '(.inbounds[] | select(.tag == $t) | .streamSettings.wsSettings.path) = $v' "$XRAY_CONF" | xray_apply || return 1 ;;
               vless-grpc-tls)
                   read -rp "Nombre de servicio nuevo: " val
                   [[ "$val" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { err "Nombre inválido."; return 1; }
                   jq --arg t "$tag" --arg v "$val" '(.inbounds[] | select(.tag == $t) | .streamSettings.grpcSettings.serviceName) = $v' "$XRAY_CONF" | xray_apply || return 1 ;;
               *) info "Este protocolo no usa ruta."; return 0 ;;
           esac
           jq --arg t "$tag" --arg v "$val" '.[$t].path = $v' "$XRAY_META" | xray_write_meta
           ok "Ruta actualizada."; xray_show_tag "$tag" ;;
        4) read -rp "Dominio o IP nuevo: " val
           [[ "$val" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || { err "Dominio o IP inválido."; return 1; }
           if [[ "$proto" == *-tls ]]; then
               files="$(xray_tls_files "$val")" || { err "No se pudo generar el certificado."; return 1; }
               read -r cert key <<<"$files"
               jq --arg t "$tag" --arg c "$cert" --arg k "$key" \
                   '(.inbounds[] | select(.tag == $t) | .streamSettings.tlsSettings.certificates[0]) = {certificateFile:$c, keyFile:$k}' "$XRAY_CONF" | xray_apply || return 1
           fi
           jq --arg t "$tag" --arg v "$val" '.[$t].host = $v' "$XRAY_META" | xray_write_meta
           ok "Dominio actualizado."; xray_show_tag "$tag" ;;
        5) read -rp "Puerto que usará el cliente: " val
           valid_port "$val" || { err "Puerto inválido."; return 1; }
           jq --arg t "$tag" --argjson p "$val" '.[$t].pport = $p' "$XRAY_META" | xray_write_meta
           ok "Puerto del cliente actualizado."; xray_show_tag "$tag" ;;
    esac
}

xray_qr() {
    local tag name link
    xray_pick || return 0; tag="$XPICK"
    if [[ "$(xm "$tag" proto)" == ss ]]; then name="$(xm "$tag" name)"
    else
        echo "Usuarios: $(xray_emails "$tag" | xargs)"; read -rp "Usuario: " name
        xray_emails "$tag" | grep -qx "$name" || { err "Ese usuario no existe."; return 1; }
    fi
    command -v qrencode >/dev/null 2>&1 || { info "Instalando qrencode..."; pkg_install qrencode || { err "No se pudo instalar qrencode."; return 1; }; }
    link="$(xray_link "$tag" "$name")"
    qrencode -t ansiutf8 "$link"; echo "$link"
}

xray_status() {
    systemctl status "$XRAY_UNIT" --no-pager -l 2>&1 | head -12
    echo "--- últimas líneas del registro:"
    journalctl -u "$XRAY_UNIT" -n 15 --no-pager 2>&1 | tail -15
}

xray_update_core() {
    xray_fetch_core || return 1
    systemctl restart "$XRAY_UNIT" 2>/dev/null
    if svc_is_active "$XRAY_UNIT"; then ok "Xray actualizado: $("$XRAY_BIN" version 2>/dev/null | head -1 | cut -d' ' -f1-2)"
    else warn "Se actualizó el binario pero el servicio no arrancó. Revisá el estado (opción 7)."; fi
}

xray_menu() {
    local op
    if ! jq_ok; then err "Tu jq es muy viejo (< 1.5, típico de Debian 8): el gestor de Xray no funciona en este sistema."; pause; return 1; fi
    if ! xray_installed; then
        title "V2RAY / XRAY"
        info "El núcleo de Xray todavía no está instalado."
        confirm "¿Instalarlo ahora?" || return 0
        install_xray || { pause; return 1; }
        pause
    fi
    jq_ok || { err "Tu jq es muy viejo (< 1.5, típico de Debian 8): el gestor de Xray no funciona en este sistema."; pause; return 1; }
    xray_migrate
    while true; do
        title "V2RAY / XRAY"
        echo " 1) Agregar configuración"
        echo " 2) Ver configuraciones y enlaces"
        echo " 3) Cambiar puerto / UUID / ruta / dominio"
        echo " 4) Eliminar configuración"
        echo " 5) Agregar o quitar usuarios"
        echo " 6) Código QR"
        echo " 7) Estado y registro"
        echo " 8) Actualizar núcleo Xray"
        echo " 9) Desinstalar Xray"
        echo " 0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) xray_add; pause ;;
            2) xray_show; pause ;;
            3) xray_change; pause ;;
            4) xray_delete; pause ;;
            5) xray_users; pause ;;
            6) xray_qr; pause ;;
            7) xray_status; pause ;;
            8) xray_update_core; pause ;;
            9) confirm "¿Desinstalar Xray y borrar TODAS sus configuraciones (incluido Trojan)?" && remove_xray; pause; xray_installed || return 0 ;;
            0) return ;;
        esac
    done
}
