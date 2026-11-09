#!/usr/bin/env bash
# CHECK-USER: API HTTP de consulta (vence, días, límite, conectados) protegida por token.
# shellcheck shell=bash

CU_UNIT="${APP_SLUG}-checkuser"

install_checkuser() {
    local port host token py
    port="$(ask_port "Puerto de CHECK-USER" 8100)"
    host="$(ask_host)"
    pkg_install python3 procps || { err "No se pudo instalar python3."; return 1; }
    py="$(command -v python3)"
    token="$(openssl rand -hex 12)"
    printf 'CHECKUSER_TOKEN=%s\n' "$token" > "${DATA_DIR}/checkuser.env"; chmod 600 "${DATA_DIR}/checkuser.env"
    cat > "/etc/systemd/system/${CU_UNIT}.service" <<EOF
[Unit]
Description=${APP_NAME} CHECK-USER
After=network.target

[Service]
EnvironmentFile=${DATA_DIR}/checkuser.env
ExecStart=${py} ${ROOT}/lib/py/checkuser.py --listen 0.0.0.0:${port} --db ${USERS_DB}
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "$CU_UNIT"
    conf_set CHECKUSER_PORT "$port"; conf_set CHECKUSER_HOST "$host"; conf_set CHECKUSER_TOKEN "$token"
    ok "CHECK-USER activo en el puerto $port."
    checkuser_info
}

checkuser_info() {
    local port host token
    port="$(conf_get CHECKUSER_PORT)"; host="$(conf_get CHECKUSER_HOST)"; token="$(conf_get CHECKUSER_TOKEN)"
    [[ -n "$port" ]] || { err "No está instalado."; return 1; }
    echo "Consulta:  http://${host}:${port}/${token}/<usuario>"
    echo "Respuesta: {\"usuario\":..., \"existe\":true, \"vence\":\"AAAA-MM-DD\", \"dias\":N, \"limite\":N, \"conectados\":N}"
    echo "El token es secreto: quien lo tenga puede consultar cualquier usuario."
}

remove_checkuser() {
    systemctl disable --now "$CU_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${CU_UNIT}.service" "${DATA_DIR}/checkuser.env"; systemctl daemon-reload
    for k in CHECKUSER_PORT CHECKUSER_HOST CHECKUSER_TOKEN; do conf_set "$k" ""; done
    ok "CHECK-USER eliminado."
}
