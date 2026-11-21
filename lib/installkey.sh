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
IKEY_REPORT_FILE="${IKEY_REPORT_FILE:-/root/.mvs-signing/report}"   # una línea: TOKEN_DEL_BOT_AVISADOR ID_DE_TU_CHAT
IKEY_TG_API="${IKEY_TG_API:-https://api.telegram.org}"
IKEY_REP=""     # "token|chat" que trae la key (si fue generada con aviso)
IKEY_GATE_FILE="${IKEY_GATE_FILE:-${SRC:-.}/config/install-gate}"   # URL del Worker que impide reutilizar una key (opcional)

ikey_b64url_decode() { # stdin: base64url sin relleno -> stdout binario
    local s; s="$(tr '_-' '/+')"
    while (( ${#s} % 4 )); do s+="="; done
    printf '%s' "$s" | base64 -d 2>/dev/null
}

# 0 = válida. 1 = formato/firma incorrectos. 2 = vencida. 3 = el reloj de esta VPS está atrasado.
# Formatos:  MVS.<hora>.<azar>.<firma>   o con aviso   MVS.<hora>.<azar>.<destino>.<firma>   (el destino va firmado)
ikey_verify() {
    local key="$1" iat rnd rep="" sig tmp now rc=1 data
    local -a f
    IKEY_REP=""
    IFS=. read -ra f <<<"$key"
    case "${#f[@]}" in
        4) iat="${f[1]}"; rnd="${f[2]}"; sig="${f[3]}"; data="${iat}.${rnd}" ;;
        5) iat="${f[1]}"; rnd="${f[2]}"; rep="${f[3]}"; sig="${f[4]}"; data="${iat}.${rnd}.${rep}" ;;
        *) return 1 ;;
    esac
    [[ "${f[0]}" == MVS && "$iat" =~ ^[0-9]{9,12}$ && "$rnd" =~ ^[a-f0-9]{6}$ && "$sig" =~ ^[A-Za-z0-9_-]{60,140}$ ]] || return 1
    [[ -z "$rep" || "$rep" =~ ^[A-Za-z0-9_-]{20,200}$ ]] || return 1
    tmp="$(mktemp -d)"
    printf '%s' "$data" > "$tmp/data"
    printf '%s' "$sig" | ikey_b64url_decode > "$tmp/sig"
    if openssl dgst -sha256 -verify "$IKEY_PUB" -signature "$tmp/sig" "$tmp/data" 2>/dev/null | grep -q "Verified OK"; then
        [[ -n "$rep" ]] && IKEY_REP="$(printf '%s' "$rep" | ikey_b64url_decode)"
        now="$(date +%s)"
        if   (( now < iat - 300 )); then rc=3
        elif (( now > iat + IKEY_TTL )); then rc=2
        else rc=0; fi
    fi
    rm -rf "$tmp"
    return $rc
}

# Avisa por Telegram (bot avisador que viene dentro de la key). Nunca bloquea ni hace fallar la instalación.
# $1 = 0 usada | 2 vencida
ikey_report() {
    local rc="$1" key="$2" tok chat ip osn head text kid
    [[ -n "$IKEY_REP" ]] || return 0
    tok="${IKEY_REP%%|*}"; chat="${IKEY_REP#*|}"
    [[ -n "$tok" && "$chat" =~ ^-?[0-9]+$ ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    ip="$(curl -4 -fsS -m 5 https://api.ipify.org 2>/dev/null)"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    osn="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${ID:-?} ${VERSION_ID:-}}")"
    kid="$(cut -d. -f2,3 <<<"$key")"
    if [[ "$rc" == 0 ]]; then head="🔔 MvS: KEY USADA"; else head="⚠️ MvS: intento con una key VENCIDA"; fi
    text="${head}
Key: MVS.${kid}
IP: ${ip:-?}
Sistema: ${osn} ($(uname -m))
Hora: $(date -u '+%F %H:%M') UTC"
    printf 'url = "%s/bot%s/sendMessage"\n' "$IKEY_TG_API" "$tok" |
        curl -sS -K - --max-time 8 --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" >/dev/null 2>&1 || true
    return 0
}

ikey_gate_url() { [[ -r "$IKEY_GATE_FILE" ]] && grep -v '^#' "$IKEY_GATE_FILE" | head -1 | tr -d '[:space:]'; return 0; }

# Consulta al Worker y reclama la key (solo la primera vez da ok).  0 = ok. 1 = ya usada. 2 = no se pudo consultar. 3 = vencida/inválida.
ikey_gate_claim() { # url key
    local url="$1" key="$2" osn resp
    command -v curl >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y curl >/dev/null 2>&1; }
    command -v curl >/dev/null 2>&1 || return 2
    osn="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${ID:-?} ${VERSION_ID:-}} ($(uname -m))")"
    osn="${osn//[^A-Za-z0-9 ._()+-]/}"
    resp="$(curl -sS -m 20 -H 'content-type: application/json' -d "{\"key\":\"${key}\",\"os\":\"${osn}\"}" "${url%/}/claim" 2>/dev/null)" || return 2
    case "$resp" in
        *'"ok":true'*) return 0 ;;
        *'"reason":"used"'*) return 1 ;;
        *'"reason":"expired"'*|*'"reason":"invalid"'*|*'"reason":"early"'*) return 3 ;;
        *) return 2 ;;
    esac
}

# Pide y valida la key (variable MVS_KEY o pregunta). Sale si no es válida.
installkey_require() {
    local key="${MVS_KEY:-}" tries=0 rc g gate; gate="$(ikey_gate_url)"
    command -v openssl >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y openssl >/dev/null 2>&1; }
    command -v openssl >/dev/null 2>&1 || die "Falta openssl para validar la key (apt install openssl)."
    [[ -r "$IKEY_PUB" ]] || die "Falta config/install-pub.pem: el instalador está incompleto."
    while true; do
        if [[ -z "$key" ]]; then
            if [[ -t 0 ]]; then read -rp "Key de instalación: " key || true
            elif { : </dev/tty; } 2>/dev/null; then read -rp "Key de instalación: " key </dev/tty || true
            fi
            [[ -n "$key" ]] || { (( tries > 0 )) && die "Sin una key válida no se instala."; die "Hace falta una key de instalación. Usá:  MVS_KEY=tu_key bash mvs.sh"; }
        fi
        key="${key//[[:space:]]/}"
        ikey_verify "$key" && rc=0 || rc=$?
        case $rc in
            0) if [[ -n "$gate" ]]; then
                   ikey_gate_claim "$gate" "$key" && g=0 || g=$?
                   case $g in
                       0) say "Key válida (queda usada: sirve una sola vez)."; return 0 ;;
                       1) warn "Esa key ya fue usada. Cada key sirve una sola vez: pedí una nueva." ;;
                       2) warn "No se pudo verificar la key por internet. Revisá la conexión de la VPS y probá de nuevo." ;;
                       *) warn "La key no es válida o venció." ;;
                   esac
               else say "Key válida."; ikey_report 0 "$key"; return 0; fi ;;
            2) warn "La key venció (duran 6 horas). Pedí una nueva."; [[ -n "$gate" ]] || ikey_report 2 "$key" ;;
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
    local iat rnd sig rep="" tok chat data
    instkey_available || { err "No está la clave privada ($IKEY_PRIV): esta VPS no puede generar keys."; return 1; }
    if [[ -r "$IKEY_REPORT_FILE" ]]; then
        read -r tok chat < "$IKEY_REPORT_FILE" || true
        [[ -n "${tok:-}" && "${chat:-}" =~ ^-?[0-9]+$ ]] && rep="$(printf '%s|%s' "$tok" "$chat" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    fi
    iat="$(date +%s)"; rnd="$(openssl rand -hex 3)"
    data="${iat}.${rnd}${rep:+.$rep}"
    sig="$(printf '%s' "$data" | openssl dgst -sha256 -sign "$IKEY_PRIV" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    [[ -n "$sig" ]] || { err "No se pudo firmar la key."; return 1; }
    printf 'MVS.%s.%s.%s%s' "$iat" "$rnd" "${rep:+$rep.}" "$sig"
}

# Pantalla del panel: genera una key y muestra el comando listo para pegar en la VPS nueva
instkey_screen() {
    local key iat
    title "Key de instalación (dura 6 horas)"
    key="$(instkey_generate)" || return 1
    iat="${key#MVS.}"; iat="${iat%%.*}"
    echo " Key:"; echo; echo "$key"; echo
    echo " Vence: $(date -d "@$((iat + IKEY_TTL))" '+%F %H:%M') (hora de esta VPS)"
    if [[ "$key" == *.*.*.*.* ]]; then echo " Aviso: activado (te llega un mensaje por Telegram cuando se use)"
    else echo " Aviso: desactivado (falta $IKEY_REPORT_FILE)"; fi
    bar
    echo " Comando para la VPS nueva (como root):"; echo
    echo "wget -qO mvs.sh ${APP_UPDATE_URL} && MVS_KEY=${key} bash mvs.sh"
    echo
    echo " También podés ejecutar solo 'bash mvs.sh' y pegar la key cuando la pida."
}
