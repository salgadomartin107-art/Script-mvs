#!/usr/bin/env bash
# Fail2ban para OpenSSH y Dropbear. shellcheck shell=bash

install_fail2ban() {
    local dbport
    info "Instalando fail2ban..."
    pkg_install fail2ban || { err "Falló la instalación de fail2ban."; return 1; }
    dbport="$(printf "%s %s" "$(conf_get DROPBEAR_PORT)" "$(conf_get DROPBEAR_EXTRA)" | xargs | tr " " ",")"

    {
        cat <<EOF
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
EOF
        if [[ -n "$dbport" ]]; then
            cat <<EOF

[dropbear]
enabled      = true
port         = ${dbport}
journalmatch = _SYSTEMD_UNIT=${APP_SLUG}-dropbear.service
EOF
        fi
    } > "/etc/fail2ban/jail.d/${APP_SLUG}.local"

    if ! fail2ban-client -t >/dev/null 2>&1; then
        err "La configuración de fail2ban no valida; se quita nuestro archivo."
        rm -f "/etc/fail2ban/jail.d/${APP_SLUG}.local"; return 1
    fi
    svc_enable_restart fail2ban
    ok "Fail2ban activo: 5 intentos fallidos en 10 min = bloqueo de 1 hora."
    [[ -n "$dbport" ]] || info "Si instalás Dropbear después, volvé a instalar fail2ban para cubrirlo."
}

fail2ban_status() {
    systemctl is-active --quiet fail2ban || { err "Fail2ban no está activo."; return 1; }
    fail2ban-client status
    fail2ban-client status sshd 2>/dev/null || true
}

remove_fail2ban() {
    systemctl disable --now fail2ban >/dev/null 2>&1 || true
    rm -f "/etc/fail2ban/jail.d/${APP_SLUG}.local"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y fail2ban >/dev/null 2>&1 || true
    ok "Fail2ban eliminado."
}
