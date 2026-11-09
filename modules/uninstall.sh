#!/usr/bin/env bash
# Desinstalación completa: deja el VPS sin rastros del panel y de lo que instaló.
# shellcheck shell=bash

# Paquetes que el panel instala por apt. Nunca se tocan curl, openssl, python3, jq, cron, iproute2.
UNINSTALL_PKGS="dropbear-bin dropbear stunnel4 squid openvpn easy-rsa shadowsocks-libev wireguard wireguard-tools fail2ban ufw qrencode speedtest-cli iptables-persistent badvpn"

uninstall_summary() {
    echo "Se va a eliminar de este VPS:"
    echo "  - Todos los servicios del panel (${APP_SLUG}-*, OpenVPN, WireGuard, Xray, Trojan, Hysteria2, HCR, etc.)"
    echo "  - Binarios (/usr/local/bin/${APP_SLUG}-*), configuración (/etc/${APP_SLUG}*), certificados y claves"
    echo "  - Tareas programadas, el banner SSH, el inicio automático del panel y los ajustes de sysctl/DNS"
    echo "  - El comando 'menu' y la carpeta /opt/${APP_SLUG}"
}

uninstall_all() {
    local del_users=n purge=n del_bak=n n_users confirm_txt p
    title "Desinstalar ${APP_NAME}"
    uninstall_summary
    echo
    n_users="$(awk -F'|' 'NF>=2' "$USERS_DB" 2>/dev/null | wc -l)"
    warn "Esto no se puede deshacer. Hacé un backup antes si querés conservar usuarios o claves."
    read -rp "Escribí DESINSTALAR para continuar: " confirm_txt
    [[ "$confirm_txt" == DESINSTALAR ]] || { info "Cancelado."; return 0; }

    confirm "¿Eliminar también los ${n_users} usuarios SSH creados con el panel (y cerrar sus sesiones)?" && del_users=y
    echo "Paquetes que el panel pudo instalar: ${UNINSTALL_PKGS}"
    echo "(no se tocan curl, openssl, python3, jq, cron ni iproute2)"
    confirm "¿Quitar también esos paquetes (purge)? Si alguno ya lo usabas antes, también se va." && purge=y
    [[ -d "/root/${APP_SLUG}-backups" ]] && { confirm "¿Borrar también los backups de /root/${APP_SLUG}-backups?" && del_bak=y; }

    # --- 1. cerrar en ufw los puertos que abrió el panel (nunca los de SSH) ---
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Cerrando en ufw los puertos del panel..."
        local ssh_ports; ssh_ports=" $(sshd_ports | tr '\n' ' ') "
        while read -r p; do
            [[ -n "$p" && "$ssh_ports" != *" ${p%%/*} "* ]] && ufw delete allow "$p" >/dev/null 2>&1 || true
        done < <(fw_ports 2>/dev/null | sort -u)
    fi

    # --- 2. quitar cada servicio con su propia rutina ---
    info "Quitando servicios..."
    local fn
    for fn in remove_monitor remove_notibot remove_bot remove_badvpn remove_checkuser remove_dropbear remove_fileserver \
              remove_hcr remove_hysteria remove_openvpn remove_shadowsocks remove_slowdns remove_squid remove_stunnel \
              remove_trojan remove_wireguard remove_wsproxy remove_wspro remove_xray; do
        declare -F "$fn" >/dev/null && "$fn" >/dev/null 2>&1 || true
    done

    # --- 3. barrido de lo que pudo quedar ---
    info "Barrido final de unidades, binarios y archivos..."
    local u
    for u in /etc/systemd/system/${APP_SLUG}-*.service; do
        [[ -e "$u" ]] || continue
        u="$(basename "$u" .service)"; systemctl disable --now "$u" >/dev/null 2>&1 || true
    done
    systemctl disable --now "wg-quick@${APP_SLUG}" "openvpn-server@${APP_SLUG}" >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/${APP_SLUG}-*.service
    rm -rf /etc/systemd/system/multi-user.target.wants/${APP_SLUG}-*
    systemctl daemon-reload; systemctl reset-failed >/dev/null 2>&1 || true
    rm -f /usr/local/bin/${APP_SLUG}-* /usr/local/sbin/${APP_SLUG}-*
    rm -rf /etc/${APP_SLUG}-* /etc/${APP_SLUG}-*.txt /etc/${APP_SLUG}-*.status
    rm -f /etc/cron.d/${APP_SLUG} /etc/cron.d/${APP_SLUG}-*
    rm -f /etc/sysctl.d/*-${APP_SLUG}-*.conf /etc/fail2ban/jail.d/${APP_SLUG}.local "/etc/pam.d/${APP_SLUG}-openvpn"
    rm -f "/etc/systemd/resolved.conf.d/${APP_SLUG}.conf" "/etc/apt/apt.conf.d/99${APP_SLUG}-archive"
    rm -rf "/etc/openvpn/server/${APP_SLUG}" "/etc/openvpn/server/${APP_SLUG}.conf" "/etc/wireguard/${APP_SLUG}.conf"
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    # reglas de iptables propias (jaula de HCR)
    local t
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        while "$t" -w -D OUTPUT -m owner --uid-owner "${APP_SLUG}-hcr" -j "${APP_SLUG^^}-HCR-OUT" 2>/dev/null; do :; done
        "$t" -w -F "${APP_SLUG^^}-HCR-OUT" 2>/dev/null; "$t" -w -X "${APP_SLUG^^}-HCR-OUT" 2>/dev/null
    done
    # inicio automático del panel en el .bashrc de root
    if [[ -f /root/.bashrc ]] && grep -qF "# >>> ${APP_SLUG} autostart >>>" /root/.bashrc; then
        sed -i "\\|^# >>> ${APP_SLUG} autostart >>>\$|,\\|^# <<< ${APP_SLUG} autostart <<<\$|d" /root/.bashrc
    fi
    # OpenSSH: se quitan los archivos del panel (banner, grupo de túnel, acceso root) y se recarga
    rm -f "/etc/ssh/sshd_config.d/90-${APP_SLUG}.conf" "/etc/ssh/sshd_config.d/91-${APP_SLUG}-banner.conf" "/etc/ssh/sshd_config.d/00-${APP_SLUG}-root.conf"
    sed -i "\\|^Banner /etc/${APP_SLUG}-banner.txt\$|d" /etc/ssh/sshd_config 2>/dev/null || true
    if ! command -v sshd >/dev/null 2>&1 || sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    else
        warn "sshd no valida su configuración: revisá /etc/ssh/sshd_config antes de cerrar esta sesión."
    fi

    # --- 4. usuarios ---
    if [[ "$del_users" == y && -s "$USERS_DB" ]]; then
        info "Eliminando usuarios SSH del panel..."
        local name
        while IFS='|' read -r name _; do
            [[ -n "$name" ]] || continue
            pkill -KILL -u "$name" 2>/dev/null || true
            userdel -f "$name" 2>/dev/null || true
        done < "$USERS_DB"
    fi
    for u in $(getent passwd | awk -F: -v p="^${APP_SLUG}-" '$1 ~ p {print $1}'); do userdel "$u" >/dev/null 2>&1 || true; done
    getent group "$USERS_GROUP" >/dev/null 2>&1 && groupdel "$USERS_GROUP" 2>/dev/null || true

    # --- 5. paquetes ---
    if [[ "$purge" == y ]]; then
        info "Quitando paquetes (puede tardar)..."
        local inst=""
        for p in $UNINSTALL_PKGS; do dpkg -s "$p" >/dev/null 2>&1 && inst+=" $p"; done
        # shellcheck disable=SC2086
        [[ -z "$inst" ]] || DEBIAN_FRONTEND=noninteractive apt-get purge -y $inst >/dev/null 2>&1 || warn "No se pudieron quitar algunos paquetes."
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
    fi
    [[ "$del_bak" == y ]] && rm -rf "/root/${APP_SLUG}-backups"

    rm -rf "$DATA_DIR"

    # --- 6. verificación ---
    local left=""
    left+="$(ls /etc/systemd/system/${APP_SLUG}-*.service 2>/dev/null)"
    left+="$(ls -d /etc/${APP_SLUG}* /usr/local/bin/${APP_SLUG}-* /etc/cron.d/${APP_SLUG}* 2>/dev/null)"
    if [[ -z "$left" ]]; then ok "Verificación: no quedan archivos del panel."
    else warn "Quedaron estos archivos:"; echo "$left"; fi
    [[ "$purge" != y ]] && info "Los paquetes de apt se conservaron. Para quitarlos: apt purge ${UNINSTALL_PKGS}"
    [[ -d "/root/${APP_SLUG}-backups" ]] && info "Se conservaron los backups en /root/${APP_SLUG}-backups."
    warn "Si abriste puertos en el firewall de la nube (NSG de Azure, etc.), cerralos desde allí."

    # --- 7. el panel mismo (último, porque este script vive en /opt) ---
    rm -f /usr/local/bin/menu "/usr/local/bin/${APP_SLUG}"
    rm -rf "/opt/${APP_SLUG}"
    ok "${APP_NAME} desinstalado. El VPS quedó limpio."
    exit 0
}
