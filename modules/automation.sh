#!/usr/bin/env bash
# MONITOR, NOTI-BOT y BOT TELEGRAM (instalación/baja). shellcheck shell=bash

# ---- MONITOR ----
install_monitor() {
    printf '*/2 * * * * root %s/bin/monitor\n' "$ROOT" > "/etc/cron.d/${APP_SLUG}-monitor"
    chmod 644 "/etc/cron.d/${APP_SLUG}-monitor"
    ok "Monitor activo: cada 2 min reinicia servicios caídos y avisa por Telegram (si está configurado)."
    tg_configured || warn "Telegram no está configurado: reiniciará servicios pero no te avisará."
}
remove_monitor() { rm -f "/etc/cron.d/${APP_SLUG}-monitor"; ok "Monitor desactivado."; }
monitor_info() {
    echo "Vigila: ${MVS_UNITS[*]}"
    echo "Alertas: disco >= 90% y RAM >= 95% (máx. una cada 6 h)."
}

# ---- NOTI-BOT ----
install_notibot() {
    tg_configured || { warn "Primero configurá Telegram."; tg_configure || return 1; tg_configured || return 1; }
    printf '0 9 * * * root %s/bin/notibot --daily\n' "$ROOT" > "/etc/cron.d/${APP_SLUG}-notibot"
    chmod 644 "/etc/cron.d/${APP_SLUG}-notibot"
    cat > "/etc/systemd/system/${APP_SLUG}-notibot-boot.service" <<EOF
[Unit]
Description=${APP_NAME} aviso de arranque
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${ROOT}/bin/notibot --boot

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable "${APP_SLUG}-notibot-boot" >/dev/null 2>&1
    ok "NOTI-BOT activo: aviso al arrancar el VPS y resumen diario a las 9:00 (hora del servidor)."
}
remove_notibot() {
    rm -f "/etc/cron.d/${APP_SLUG}-notibot"
    systemctl disable "${APP_SLUG}-notibot-boot" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${APP_SLUG}-notibot-boot.service"; systemctl daemon-reload
    ok "NOTI-BOT desactivado."
}
notibot_info() { echo "Aviso al arrancar el VPS + resumen diario (vencimientos próximos y conexiones) a las 9:00."; }

# ---- BOT TELEGRAM ----
install_bot() {
    tg_configured || { warn "Primero configurá Telegram."; tg_configure || return 1; tg_configured || return 1; }
    pkg_install jq curl || { err "No se pudo instalar jq."; return 1; }
    cat > "/etc/systemd/system/${APP_SLUG}-bot.service" <<EOF
[Unit]
Description=${APP_NAME} bot de Telegram
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${ROOT}/bin/bot
Restart=always
RestartSec=5
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "${APP_SLUG}-bot"
    ok "Bot activo. Escribile /ayuda a tu bot desde tu cuenta personal."
}
remove_bot() {
    systemctl disable --now "${APP_SLUG}-bot" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${APP_SLUG}-bot.service"; systemctl daemon-reload
    ok "Bot desactivado."
}
bot_info() {
    echo "Comandos: /estado /usuarios /crear /renovar /limite /borrar /ayuda"
    echo "Solo responde a tu id personal (TG_CHAT); los demás mensajes se ignoran."
}
