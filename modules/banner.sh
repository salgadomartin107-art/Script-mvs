#!/usr/bin/env bash
# Banner de login SSH: el texto que HTTP Custom / HTTP Injector / NetMod muestran en su registro al conectar.
# Lo envía el servidor SSH (OpenSSH y Dropbear) antes de pedir la contraseña, así que funciona con
# cualquier método (directo, SSL, proxy Python, WS-PRO, detrás de Cloudflare).
# shellcheck shell=bash

BANNER_FILE="/etc/${APP_SLUG}-banner.txt"   # fuera de /etc/${APP_SLUG} (modo 700): lo deben poder leer sshd y dropbear
BANNER_DROPIN="/etc/ssh/sshd_config.d/91-${APP_SLUG}-banner.conf"
BANNER_MAX=1500                              # dropbear ignora banners de más de 2000 bytes

banner_on() { [[ -s "$BANNER_FILE" ]]; }

banner_dropbear_sync() { # deja a dropbear apuntando al archivo (una sola vez por unidad)
    local f="/etc/systemd/system/${APP_SLUG}-dropbear.service"
    [[ -f "$f" ]] || return 0
    grep -q -- " -b ${BANNER_FILE}" "$f" && return 0
    sed -i "s|^ExecStart=\(.*\) -F |ExecStart=\1 -F -b ${BANNER_FILE} |" "$f"
    grep -q '^KillMode=' "$f" || sed -i '/^\[Service\]/a KillMode=process' "$f"
    systemctl daemon-reload
    systemctl restart "${APP_SLUG}-dropbear" 2>/dev/null
    info "Dropbear reiniciado una vez para leer el banner."
}

banner_apply() { # texto por stdin
    local tmp; tmp="$(mktemp)"
    # solo texto: se descartan secuencias de escape y otros caracteres de control
    head -c "$BANNER_MAX" | tr -d '\000-\010\013-\037\177' > "$tmp"
    [[ -s "$tmp" && "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]] && printf '\n' >> "$tmp"
    install -m 644 "$tmp" "$BANNER_FILE"; rm -f "$tmp"
    if [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
        printf 'Banner %s\n' "$BANNER_FILE" > "$BANNER_DROPIN"
    else
        grep -q "^Banner ${BANNER_FILE}" /etc/ssh/sshd_config 2>/dev/null || printf '\nBanner %s\n' "$BANNER_FILE" >> /etc/ssh/sshd_config
    fi
    if sshd -t 2>/dev/null; then ssh_reload; else err "sshd rechazó la configuración del banner."; rm -f "$BANNER_DROPIN"; return 1; fi
    banner_dropbear_sync
}

banner_set() {
    local line text="" n=0
    echo "Escribí el banner línea por línea. Línea vacía = terminar. Máx. 12 líneas."
    echo "Ejemplo:  ${APP_NAME} VPN  /  Soporte: @tu_usuario  /  Vence: 30 dias"
    while (( n < 12 )); do
        read -rp "> " line
        [[ -z "$line" ]] && break
        text+="${line}"$'\n'; n=$((n + 1))
    done
    [[ -n "$text" ]] || { info "Sin cambios."; return 0; }
    printf '%s' "$text" | banner_apply && ok "Banner guardado. Se muestra en la próxima conexión (sin reiniciar nada que corte sesiones)."
}

banner_menu() {
    local op
    while true; do
        title "Banner de login SSH"
        if banner_on; then echo " Estado: ${G}ACTIVO${N}"; bar; sed 's/^/   | /' "$BANNER_FILE"; else echo " Estado: ${Y}sin banner${N}"; fi
        bar
        echo " 1) Escribir / cambiar banner"
        echo " 2) Quitar banner"
        echo " 0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) banner_set; pause ;;
            2) printf '' | banner_apply && ok "Banner quitado."; pause ;;
            0) return ;;
        esac
    done
}
