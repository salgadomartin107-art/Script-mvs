#!/usr/bin/env bash
# Telegram con TU propio bot (token y chat id en config.conf).
# shellcheck shell=bash

# Llama a la API. El token viaja por stdin (-K -) para que no aparezca en la lista de procesos.
tg_api() { # metodo [argumentos de curl...]
    local token m="$1"; shift
    token="$(conf_get TG_TOKEN)"; [[ -n "$token" ]] || return 1
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$m" |
        curl -sS -K - --max-time 70 "$@"
}

tg_reply() { # chat texto
    tg_api sendMessage --data-urlencode "chat_id=$1" --data-urlencode "text=$2" >/dev/null 2>&1 || true
}

tg_send() { # texto -> al chat configurado, con prefijo del script
    local chat; chat="$(conf_get TG_CHAT)"
    [[ -n "$(conf_get TG_TOKEN)" && -n "$chat" ]] || return 0
    tg_reply "$chat" "[${APP_NAME}] $1"
}

tg_configured() { [[ -n "$(conf_get TG_TOKEN)" && -n "$(conf_get TG_CHAT)" ]]; }

tg_configure() {
    local token chat
    echo "Creá un bot con @BotFather y pegá su token. Tu chat id (personal) lo ves con @userinfobot."
    read -rp "Token del bot (vacío = desactivar): " token
    if [[ -z "$token" ]]; then
        conf_set TG_TOKEN ""; conf_set TG_CHAT ""; ok "Telegram desactivado."; return
    fi
    read -rp "Chat id: " chat
    [[ "$chat" =~ ^[0-9]+$ ]] || { err "Chat id inválido (usá tu id personal, solo números)."; return 1; }
    conf_set TG_TOKEN "$token"; conf_set TG_CHAT "$chat"
    tg_send "Notificaciones activadas en $(hostname)"
    ok "Guardado. Si no te llegó el mensaje de prueba, revisá token y chat id."
}
