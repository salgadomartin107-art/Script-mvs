#!/usr/bin/env bash
# Key de instalación: la firma quien tiene la clave privada (opción [R] del panel de TU VPS de administración) y el instalador
# la valida con la clave pública (config/install-pub.pem). Formato:  MVS.<hora_emision>.<azar>.<firma>
# Dura 6 horas desde que se genera. Solo se pide para instalar en una VPS nueva (no al actualizar ni al reinstalar).
# La hora se compara con el reloj de la VPS. Es un freno, no una barrera: el instalador es texto y quien lo edite puede quitar la
# validación. Para obligarla de verdad hace falta un servidor que entregue el instalador (ver README).
# shellcheck shell=bash

IKEY_TTL=21600
IKEY_PUB="${IKEY_PUB:-${SRC:-.}/config/install-pub.pem}"
IKEY_PRIV="${IKEY_PRIV:-/root/.mvs-signing/private.pem}"

ikey_b64url_decode() { # stdin: base64url sin relleno -> stdout binario
    local s; s="$(tr '_-' '/+')"
    while (( ${#s} % 4 )); do s+="="; done
    printf '%s' "$s" | base64 -d 2>/dev/null
}

# 0 = válida. 1 = formato/firma incorrectos. 2 = vencida. 3 = el reloj de esta VPS está atrasado.
ikey_verify() {
    local key="$1" iat rnd sig tmp now rc=1
    [[ "$key" =~ ^MVS\.([0-9]{9,12})\.([a-f0-9]{6})\.([A-Za-z0-9_-]{60,140})$ ]] || return 1
    iat="${BASH_REMATCH[1]}"; rnd="${BASH_REMATCH[2]}"; sig="${BASH_REMATCH[3]}"
    tmp="$(mktemp -d)"
    printf '%s' "${iat}.${rnd}" > "$tmp/data"
    printf '%s' "$sig" | ikey_b64url_decode > "$tmp/sig"
    if openssl dgst -sha256 -verify "$IKEY_PUB" -signature "$tmp/sig" "$tmp/data" 2>/dev/null | grep -q "Verified OK"; then
        now="$(date +%s)"
        if   (( now < iat - 300 )); then rc=3
        elif (( now > iat + IKEY_TTL )); then rc=2
        else rc=0; fi
    fi
    rm -rf "$tmp"
    return $rc
}

# Pide y valida la key (variable MVS_KEY o pregunta). Sale si no es válida.
installkey_require() {
    local key="${MVS_KEY:-}" tries=0 rc
    command -v openssl >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y openssl >/dev/null 2>&1; }
    command -v openssl >/dev/null 2>&1 || die "Falta openssl para validar la key (apt install openssl)."
    [[ -r "$IKEY_PUB" ]] || die "Falta config/install-pub.pem: el instalador está incompleto."
    while true; do
        if [[ -z "$key" ]]; then
            if [[ -t 0 ]]; then read -rp "Key de instalación: " key || true
            elif { : </dev/tty; } 2>/dev/null; then read -rp "Key de instalación: " key </dev/tty || true
            fi
            [[ -n "$key" ]] || die "Hace falta una key de instalación. Usá:  MVS_KEY=tu_key bash mvs.sh"
        fi
        key="${key//[[:space:]]/}"
        ikey_verify "$key" && rc=0 || rc=$?
        case $rc in
            0) say "Key válida."; return 0 ;;
            2) warn "La key venció (duran 6 horas). Pedí una nueva." ;;
            3) warn "El reloj de esta VPS está atrasado respecto de la key. Sincronizá la hora (timedatectl set-ntp true) y probá de nuevo." ;;
            *) warn "Key inválida." ;;
        esac
        key=""; tries=$((tries + 1))
        (( tries >= 3 )) && die "Sin una key válida no se instala."
    done
}

# --- Generar keys (solo funciona donde está la clave privada) ---
instkey_available() { [[ -r "$IKEY_PRIV" ]]; }

instkey_generate() {
    local iat rnd sig key
    instkey_available || { err "No está la clave privada ($IKEY_PRIV): esta VPS no puede generar keys."; return 1; }
    iat="$(date +%s)"; rnd="$(openssl rand -hex 3)"
    sig="$(printf '%s' "${iat}.${rnd}" | openssl dgst -sha256 -sign "$IKEY_PRIV" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    [[ -n "$sig" ]] || { err "No se pudo firmar la key."; return 1; }
    key="MVS.${iat}.${rnd}.${sig}"
    printf '%s' "$key"
}

# Pantalla del panel: genera una key y muestra el comando listo para pegar en la VPS nueva
instkey_screen() {
    local key iat
    title "Key de instalación (dura 6 horas)"
    key="$(instkey_generate)" || return 1
    iat="${key#MVS.}"; iat="${iat%%.*}"
    echo " Key:"; echo; echo "$key"; echo
    echo " Vence: $(date -d "@$((iat + IKEY_TTL))" '+%F %H:%M') (hora de esta VPS)"
    bar
    echo " Comando para la VPS nueva (como root):"; echo
    echo "wget -qO mvs.sh ${APP_UPDATE_URL} && MVS_KEY=${key} bash mvs.sh"
    echo
    echo " También podés ejecutar solo 'bash mvs.sh' y pegar la key cuando la pida."
}
