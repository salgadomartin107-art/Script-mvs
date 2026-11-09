#!/usr/bin/env bash
# Herramientas básicas. shellcheck shell=bash

AUTO_RC="/root/.bashrc"
AUTO_BEGIN="# >>> ${APP_SLUG} autostart >>>"
AUTO_END="# <<< ${APP_SLUG} autostart <<<"

autostart_on() { grep -qF "$AUTO_BEGIN" "$AUTO_RC" 2>/dev/null; }

# Abre el panel al entrar por SSH como root. Solo en sesiones interactivas con terminal:
# scp, sftp y comandos remotos (ssh host cmd) no se ven afectados. Al salir del panel queda la consola normal.
autostart_enable() {
    autostart_on && { info "Ya está activado."; return 0; }
    touch "$AUTO_RC"
    {
        echo
        echo "$AUTO_BEGIN"
        echo 'if [ "$(id -u)" = 0 ] && [ -n "${SSH_TTY:-}" ] && [ -z "${MVS_AUTOSTART:-}" ] && command -v menu >/dev/null 2>&1; then'
        echo '    export MVS_AUTOSTART=1'
        echo '    menu'
        echo 'fi'
        echo "$AUTO_END"
    } >> "$AUTO_RC"
    ok "Activado: el panel se abrirá al entrar como root por SSH."
}

autostart_disable() {
    autostart_on || { info "No estaba activado."; return 0; }
    sed -i "\|^${AUTO_BEGIN}\$|,\|^${AUTO_END}\$|d" "$AUTO_RC"
    ok "Desactivado."
}

autostart_toggle() {
    echo "Inicio automático del panel: $(autostart_on && echo ACTIVADO || echo DESACTIVADO)"
    if autostart_on; then confirm "¿Desactivarlo?" && autostart_disable
    else confirm "¿Activarlo?" && autostart_enable; fi
}

basics_menu() {
    local op tz hn
    while true; do
        title "Herramientas básicas"
        echo " 1) Backup: crear              6) Cambiar hostname"
        echo " 2) Backup: listar             7) Reiniciar servicios del panel"
        echo " 3) Backup: restaurar          8) Puertos en escucha"
        echo " 4) Zona horaria               9) Reiniciar el VPS"
        echo " 5) Actualizar el sistema      A) Inicio automático del panel"
        echo " B) Banner de login SSH"
        echo " 0) Volver"
        bar; read -rp " Opción: " op
        case "${op^^}" in
            1) backup_create; pause ;;
            2) backup_list; pause ;;
            3) backup_restore; pause ;;
            4) echo "Actual: $(timedatectl show -p Timezone --value 2>/dev/null)"
               read -rp "Nueva zona (ej: America/Argentina/Buenos_Aires): " tz
               [[ "$tz" =~ ^[A-Za-z_/+-]+$ ]] && timedatectl set-timezone "$tz" 2>/dev/null && ok "Zona: $tz" || err "Zona inválida."; pause ;;
            5) confirm "¿Actualizar paquetes ahora?" && { apt-get update -y >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >/dev/null && ok "Sistema actualizado."; }; pause ;;
            6) read -rp "Nuevo hostname: " hn
               [[ "$hn" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] && hostnamectl set-hostname "$hn" && ok "Hostname: $hn" || err "Hostname inválido."; pause ;;
            7) for u in "${MVS_UNITS[@]}"; do
                   systemctl is-enabled --quiet "$u" 2>/dev/null && systemctl restart "$u" 2>/dev/null && echo "reiniciado: $u"
               done; pause ;;
            8) ss -ltunp 2>/dev/null | awk 'NR==1 || /LISTEN|UNCONN/'; pause ;;
            9) confirm "¿Reiniciar el VPS ahora?" && systemctl reboot ;;
            A) autostart_toggle; pause ;;
            B) banner_menu ;;
            0) return ;;
        esac
    done
}
