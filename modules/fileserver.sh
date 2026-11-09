#!/usr/bin/env bash
# ARCHIVO ONLINE: publica archivos sueltos (p. ej. el .ovpn) en un enlace con token aleatorio.
# shellcheck shell=bash

FS_DIR="/var/lib/${APP_SLUG}/www"
FS_UNIT="${APP_SLUG}-fileserver"

install_fileserver() {
    local port host token py
    port="$(ask_port "Puerto del servidor de archivos" 81)"
    host="$(ask_host)"
    pkg_install python3 || { err "No se pudo instalar python3."; return 1; }
    py="$(command -v python3)"
    ensure_service_user "$FS_UNIT"
    install -d -m 755 "$FS_DIR"
    token="$(openssl rand -hex 12)"
    printf 'FILESERVER_TOKEN=%s\n' "$token" > "${DATA_DIR}/fileserver.env"; chmod 600 "${DATA_DIR}/fileserver.env"
    cat > "/etc/systemd/system/${FS_UNIT}.service" <<EOF
[Unit]
Description=${APP_NAME} archivos online
After=network.target

[Service]
User=${FS_UNIT}
EnvironmentFile=${DATA_DIR}/fileserver.env
ExecStart=${py} ${ROOT}/lib/py/fileserver.py --listen 0.0.0.0:${port} --root ${FS_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "$FS_UNIT"
    conf_set FILESERVER_PORT "$port"; conf_set FILESERVER_HOST "$host"; conf_set FILESERVER_TOKEN "$token"
    ok "Servidor de archivos activo en el puerto $port."
}

fileserver_ready() { [[ -n "$(conf_get FILESERVER_PORT)" ]] || { err "Primero instalá el servidor (opción 1)."; return 1; }; }

fileserver_publish() {
    local src name
    fileserver_ready || return 1
    echo "Archivos sugeridos: ${OVPN_FILE:-}"
    read -rp "Ruta del archivo a publicar [${OVPN_FILE:-}]: " src; src="${src:-${OVPN_FILE:-}}"
    [[ -f "$src" ]] || { err "No existe: $src"; return 1; }
    name="$(basename "$src")"
    [[ "$name" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || { err "Nombre de archivo no permitido (usá letras, números . _ -)."; return 1; }
    install -m 644 "$src" "$FS_DIR/$name"
    ok "Publicado:"; fileserver_links | grep -F "/$name"
}

fileserver_links() {
    local f host port token
    host="$(conf_get FILESERVER_HOST)"; port="$(conf_get FILESERVER_PORT)"; token="$(conf_get FILESERVER_TOKEN)"
    [[ -n "$port" ]] || { err "No está instalado."; return 1; }
    shopt -s nullglob
    for f in "$FS_DIR"/*; do echo "http://${host}:${port}/${token}/$(basename "$f")"; done
    shopt -u nullglob
}

fileserver_unpublish() {
    local name; fileserver_ready || return 1
    read -rp "Archivo a quitar: " name
    [[ "$name" =~ ^[A-Za-z0-9._-]{1,80}$ && -f "$FS_DIR/$name" ]] || { err "No existe."; return 1; }
    rm -f "$FS_DIR/$name"; ok "Quitado."
}

remove_fileserver() {
    systemctl disable --now "$FS_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${FS_UNIT}.service" "${DATA_DIR}/fileserver.env"; rm -rf "$FS_DIR"; systemctl daemon-reload
    for k in FILESERVER_PORT FILESERVER_HOST FILESERVER_TOKEN; do conf_set "$k" ""; done
    ok "Servidor de archivos eliminado."
}

fileserver_menu() {
    local op
    while true; do
        title "Archivo online"
        echo " 1) Instalar servidor      4) Quitar archivo"
        echo " 2) Publicar archivo       5) Quitar servidor"
        echo " 3) Ver enlaces            0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) install_fileserver; pause ;;
            2) fileserver_publish; pause ;;
            3) fileserver_links; pause ;;
            4) fileserver_unpublish; pause ;;
            5) confirm "¿Quitar el servidor?" && remove_fileserver; pause ;;
            0) return ;;
        esac
    done
}
