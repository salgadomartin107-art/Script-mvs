#!/usr/bin/env bash
# Trojan sobre TLS, servido por Xray (trojan-go está archivado). Requiere el módulo xray.
# shellcheck shell=bash

TROJAN_TAG="trojan-in"

trojan_active() {
    command -v jq >/dev/null 2>&1 && [[ -f "$XRAY_CONF" ]] \
        && jq -e --arg t "$TROJAN_TAG" '.inbounds[]? | select(.tag == $t)' "$XRAY_CONF" >/dev/null 2>&1 \
        && svc_is_active "${APP_SLUG}-xray"
}

trojan_apply() { # lee el JSON nuevo por stdin; valida y revierte si falla
    local tmp; tmp="$(mktemp)"; cp -a "$XRAY_CONF" "$tmp"
    xray_write_conf
    if "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1; then
        systemctl restart "${APP_SLUG}-xray"; rm -f "$tmp"; return 0
    fi
    install -m 640 -o root -g "$XRAY_USER" "$tmp" "$XRAY_CONF"; rm -f "$tmp"
    err "Xray rechazó la configuración; se restauró la anterior."; return 1
}

install_trojan() {
    local port host pass cert key
    if [[ ! -f "$XRAY_CONF" ]]; then
        info "Xray no está instalado: se instala primero."
        install_xray || return 1
    fi
    jq -e --arg t "$TROJAN_TAG" '.inbounds[]? | select(.tag == $t)' "$XRAY_CONF" >/dev/null 2>&1 \
        && { err "Trojan ya está instalado."; return 1; }
    port="$(ask_port "Puerto de Trojan (TLS)" 2053)"
    host="$(ask_host)"
    cert="$XRAY_DIR/trojan.crt"; key="$XRAY_DIR/trojan.key"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
        -subj "/CN=${host}" -keyout "$key" -out "$cert" >/dev/null 2>&1 || { err "No se pudo generar el certificado."; return 1; }
    chgrp "$XRAY_USER" "$key" "$cert"; chmod 640 "$key" "$cert"
    pass="$(rand_pass)"
    jq --argjson port "$port" --arg pw "$pass" --arg cert "$cert" --arg key "$key" --arg tag "$TROJAN_TAG" \
        '.inbounds += [{tag:$tag, port:$port, listen:"0.0.0.0", protocol:"trojan",
           settings:{clients:[{password:$pw, email:"default"}]},
           streamSettings:{network:"tcp", security:"tls",
             tlsSettings:{certificates:[{certificateFile:$cert, keyFile:$key}]}}}]' "$XRAY_CONF" | trojan_apply || return 1
    conf_set TROJAN_PORT "$port"; conf_set TROJAN_HOST "$host"
    ok "Trojan activo en el puerto $port (TLS, certificado autofirmado)."
    trojan_list
}

trojan_list() {
    local port host
    trojan_active || { err "Trojan no está activo."; return 1; }
    port="$(conf_get TROJAN_PORT)"; host="$(conf_get TROJAN_HOST)"
    jq -r --arg t "$TROJAN_TAG" '.inbounds[] | select(.tag == $t) | .settings.clients[] | "\(.email) \(.password)"' "$XRAY_CONF" |
        while read -r n pw; do
            echo "$n: trojan://${pw}@${host}:${port}?security=tls&sni=${host}&allowInsecure=1#${n}"
        done
}

trojan_add_client() { # nombre
    local name="${1:-}" pw
    trojan_active || { err "Trojan no está activo."; return 1; }
    [[ -n "$name" ]] || read -rp "Nombre del cliente: " name
    [[ "$name" =~ ^[A-Za-z0-9_-]{2,32}$ ]] || { err "Nombre inválido."; return 1; }
    jq -e --arg t "$TROJAN_TAG" --arg n "$name" '.inbounds[] | select(.tag == $t) | .settings.clients[] | select(.email == $n)' \
        "$XRAY_CONF" >/dev/null 2>&1 && { err "Ya existe."; return 1; }
    pw="$(rand_pass)"
    jq --arg t "$TROJAN_TAG" --arg n "$name" --arg pw "$pw" \
        '(.inbounds[] | select(.tag == $t) | .settings.clients) += [{password:$pw, email:$n}]' "$XRAY_CONF" | trojan_apply \
        && ok "Cliente $name agregado." && trojan_list | grep "^${name}:"
}

trojan_del_client() {
    local name; trojan_active || { err "Trojan no está activo."; return 1; }
    read -rp "Cliente a eliminar: " name
    [[ "$name" != default ]] || { err "No se puede borrar 'default'."; return 1; }
    jq --arg t "$TROJAN_TAG" --arg n "$name" \
        '(.inbounds[] | select(.tag == $t) | .settings.clients) |= map(select(.email != $n))' "$XRAY_CONF" | trojan_apply \
        && ok "Cliente $name eliminado."
}

remove_trojan() {
    [[ -f "$XRAY_CONF" ]] || { conf_set TROJAN_PORT ""; return 0; }
    jq --arg t "$TROJAN_TAG" '.inbounds |= map(select(.tag != $t))' "$XRAY_CONF" | trojan_apply || return 1
    rm -f "$XRAY_DIR/trojan.crt" "$XRAY_DIR/trojan.key"
    conf_set TROJAN_PORT ""; conf_set TROJAN_HOST ""
    ok "Trojan eliminado."
}

trojan_menu() {
    local op
    while true; do
        title "Trojan (Xray + TLS)"
        echo " 1) Instalar            4) Eliminar cliente"
        echo " 2) Agregar cliente     5) Quitar Trojan"
        echo " 3) Listar clientes     0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) install_trojan; pause ;;
            2) trojan_add_client; pause ;;
            3) trojan_list; pause ;;
            4) trojan_del_client; pause ;;
            5) confirm "¿Quitar Trojan?" && remove_trojan; pause ;;
            0) return ;;
        esac
    done
}
