#!/usr/bin/env bash
# Hysteria2 (UDP/QUIC). Binario oficial de apernet/hysteria con verificación SHA-256.
# shellcheck shell=bash

HY_USER="${APP_SLUG}-hysteria"
HY_BIN="/usr/local/bin/${APP_SLUG}-hysteria"
HY_DIR="/etc/${APP_SLUG}-hysteria"

install_hysteria() {
    local port host arch tmp base name want got pass
    port="$(ask_port "Puerto UDP de Hysteria2" 36712)"
    host="$(ask_host)"
    case "$(uname -m)" in
        x86_64)  arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) err "Arquitectura no soportada: $(uname -m)"; return 1 ;;
    esac
    pkg_install curl openssl || { err "Falló la instalación de dependencias."; return 1; }

    tmp="$(mktemp -d)"; name="hysteria-linux-${arch}"
    base="https://github.com/apernet/hysteria/releases/latest/download"
    info "Descargando Hysteria2 (release oficial)..."
    if ! curl -fsSL -o "$tmp/$name" "$base/$name" || ! curl -fsSL -o "$tmp/hashes.txt" "$base/hashes.txt"; then
        err "No se pudo descargar Hysteria2."; rm -rf "$tmp"; return 1
    fi
    want="$(awk -v n="$name" '{f=$2; sub(".*/","",f); if (f==n) print $1}' "$tmp/hashes.txt" | head -1)"
    got="$(sha256sum "$tmp/$name" | awk '{print $1}')"
    if [[ -z "$want" || "$want" != "$got" ]]; then
        err "El SHA-256 no coincide. Instalación cancelada."; rm -rf "$tmp"; return 1
    fi
    install -m 755 "$tmp/$name" "$HY_BIN"; rm -rf "$tmp"

    ensure_service_user "$HY_USER"
    install -d -m 750 -o root -g "$HY_USER" "$HY_DIR"
    if [[ ! -s "$HY_DIR/server.crt" ]]; then
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
            -subj "/CN=${host}" -keyout "$HY_DIR/server.key" -out "$HY_DIR/server.crt" >/dev/null 2>&1
    fi
    chgrp "$HY_USER" "$HY_DIR/server.key" "$HY_DIR/server.crt"; chmod 640 "$HY_DIR/server.key" "$HY_DIR/server.crt"
    pass="$(rand_pass)"
    cat > "$HY_DIR/config.yaml" <<EOF
listen: :${port}
tls:
  cert: ${HY_DIR}/server.crt
  key: ${HY_DIR}/server.key
auth:
  type: password
  password: ${pass}
EOF
    chgrp "$HY_USER" "$HY_DIR/config.yaml"; chmod 640 "$HY_DIR/config.yaml"

    cat > "/etc/systemd/system/${HY_USER}.service" <<EOF
[Unit]
Description=${APP_NAME} Hysteria2
After=network.target

[Service]
User=${HY_USER}
ExecStart=${HY_BIN} server -c ${HY_DIR}/config.yaml
NoNewPrivileges=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "$HY_USER"
    conf_set HY_PORT "$port"; conf_set HY_HOST "$host"; conf_set HY_PASS "$pass"
    svc_is_active "$HY_USER" && ok "Hysteria2 activo en UDP/$port." \
        || warn "No arrancó. Revisá: journalctl -u ${HY_USER} -n 30"
    hysteria_info
}

hysteria_info() {
    local port host pass fp
    port="$(conf_get HY_PORT)"; host="$(conf_get HY_HOST)"; pass="$(conf_get HY_PASS)"
    [[ -n "$port" ]] || { err "Hysteria2 no está instalado."; return 1; }
    fp="$(openssl x509 -in "$HY_DIR/server.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
    echo "Servidor: $host   Puerto UDP: $port"
    echo "Clave:    $pass"
    echo "URI:      hysteria2://${pass}@${host}:${port}/?insecure=1#${APP_NAME}"
    echo "Huella del certificado (SHA-256): $fp"
    echo "(El certificado es autofirmado: el cliente debe permitir 'insecure' o fijar la huella.)"
}

remove_hysteria() {
    systemctl disable --now "$HY_USER" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${HY_USER}.service" "$HY_BIN"; rm -rf "$HY_DIR"; systemctl daemon-reload
    for k in HY_PORT HY_HOST HY_PASS; do conf_set "$k" ""; done
    ok "Hysteria2 eliminado."
}
