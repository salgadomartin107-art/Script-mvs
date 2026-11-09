#!/usr/bin/env bash
# BadVPN udpgw (UDP sobre SSH), escuchando solo en localhost.
# Si la distro no trae el paquete (Ubuntu 24.04), se compila el tag oficial de
# https://github.com/ambrop72/badvpn y se verifica que el commit sea el esperado.
# shellcheck shell=bash

BADVPN_REPO="https://github.com/ambrop72/badvpn.git"
BADVPN_TAG="1.999.130"
BADVPN_COMMIT="752c6b492bc6866e8af8313a6e348d5e0370fe1f"
BADVPN_BIN="/usr/local/bin/${APP_SLUG}-badvpn-udpgw"

# Deja el binario en $BADVPN_BIN (paquete de la distro o compilado desde el código fuente).
badvpn_get_binary() {
    local pkgbin tmp
    [[ -x "$BADVPN_BIN" ]] && return 0

    if apt-cache show badvpn >/dev/null 2>&1 && pkg_install badvpn; then
        pkgbin="$(command -v badvpn-udpgw)" && install -m 755 "$pkgbin" "$BADVPN_BIN" && return 0
    fi

    info "Tu distribución no trae badvpn: se compila desde el repositorio oficial (${BADVPN_TAG})..."
    pkg_install git cmake build-essential || { err "No se pudieron instalar git, cmake y el compilador."; return 1; }
    tmp="$(mktemp -d)"
    if ! git clone -q --depth 1 --branch "$BADVPN_TAG" "$BADVPN_REPO" "$tmp/src" 2>/dev/null; then
        err "No se pudo descargar badvpn desde GitHub."; rm -rf "$tmp"; return 1
    fi
    if [[ "$(git -C "$tmp/src" rev-parse HEAD)" != "$BADVPN_COMMIT" ]]; then
        err "El commit descargado no coincide con el esperado. Instalación cancelada."; rm -rf "$tmp"; return 1
    fi
    mkdir "$tmp/build"
    if ! ( cd "$tmp/build" \
           && cmake ../src -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_BUILD_TYPE=Release >/dev/null \
           && make -j"$(nproc)" >/dev/null ); then
        err "Falló la compilación de badvpn."; rm -rf "$tmp"; return 1
    fi
    install -m 755 "$tmp/build/udpgw/badvpn-udpgw" "$BADVPN_BIN"
    rm -rf "$tmp"
}

install_badvpn() {
    local port; port="$(ask_port "Puerto UDPGW (solo localhost)" 7300)"
    badvpn_get_binary || return 1

    cat > "/etc/systemd/system/${APP_SLUG}-udpgw.service" <<EOF
[Unit]
Description=${APP_NAME} UDPGW
After=network.target

[Service]
ExecStart=${BADVPN_BIN} --listen-addr 127.0.0.1:${port} --max-clients 500 --max-connections-for-client 20
Restart=on-failure
DynamicUser=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "${APP_SLUG}-udpgw"
    conf_set UDPGW_PORT "$port"
    if svc_is_active "${APP_SLUG}-udpgw"; then
        ok "UDPGW activo en 127.0.0.1:$port."
        info "En HTTP Custom: activá UDPGW y poné 127.0.0.1:$port."
    else
        warn "No arrancó. Revisá: journalctl -u ${APP_SLUG}-udpgw -n 30"
    fi
}

remove_badvpn() {
    systemctl disable --now "${APP_SLUG}-udpgw" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${APP_SLUG}-udpgw.service" "$BADVPN_BIN"
    systemctl daemon-reload; conf_set UDPGW_PORT ""
    ok "UDPGW eliminado."
}
