#!/usr/bin/env bash
# Gestión de usuarios SSH. Base de datos: $USERS_DB con líneas usuario|vence|limite|creado
# shellcheck shell=bash

user_valid()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]{2,30}$ ]]; }
user_exists() { id "$1" >/dev/null 2>&1; }
db_has()      { user_valid "$1" && awk -F'|' -v u="$1" '$1 == u {f = 1} END {exit !f}' "$USERS_DB"; }

# Permite login por clave SOLO a los usuarios del grupo del panel (el admin sigue solo con llave).
ssh_tunnel_auth_ensure() {
    local f="/etc/ssh/sshd_config.d/90-${APP_SLUG}.conf" svc=ssh
    [[ -f "$f" ]] && return 0
    grep -qs '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config || {
        warn "Tu sshd_config no incluye sshd_config.d: los usuarios del panel solo servirán por Dropbear/otros túneles."; return 0; }
    cat > "$f" <<EOF
Match Group ${USERS_GROUP}
    PasswordAuthentication yes
    AllowTcpForwarding yes
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
EOF
    if sshd -t 2>/dev/null; then
        systemctl cat ssh >/dev/null 2>&1 || svc=sshd
        systemctl reload "$svc" 2>/dev/null || true
        info "OpenSSH: login por clave habilitado solo para el grupo ${USERS_GROUP}."
    else
        rm -f "$f"; warn "No se pudo validar sshd_config; no se cambió OpenSSH."
    fi
}

user_add_system() { # nombre vence
    ensure_false_shell
    groupadd -f "$USERS_GROUP"
    useradd -M -s /bin/false -G "$USERS_GROUP" -e "$2" "$1"
    ssh_tunnel_auth_ensure
}

user_create() { # nombre clave dias limite
    local name="$1" pass="$2" days="$3" limit="$4" exp
    user_valid "$name"        || { err "Nombre inválido (a-z, 0-9, _ o -, 3 a 31 caracteres)."; return 1; }
    user_exists "$name"       && { err "Ese usuario ya existe en el sistema."; return 1; }
    [[ ${#pass} -ge 4 ]]      || { err "La clave debe tener al menos 4 caracteres."; return 1; }
    [[ "$pass" != *:* && "$pass" != *$'\n'* ]] || { err "La clave no puede contener ':' ni saltos de línea."; return 1; }
    [[ "$days" =~ ^[0-9]+$ && "$days" -ge 1 ]] || { err "Días inválidos."; return 1; }
    [[ "$limit" =~ ^[0-9]+$ ]] || { err "Límite inválido (0 = sin límite)."; return 1; }

    exp="$(date -d "+${days} days" +%F)"
    user_add_system "$name" "$exp"
    printf '%s:%s\n' "$name" "$pass" | chpasswd
    printf '%s|%s|%s|%s\n' "$name" "$exp" "$limit" "$(date +%F)" >> "$USERS_DB"
    ok "Usuario $name creado. Vence: $exp. Límite de conexiones: $limit"
    tg_send "Usuario creado: $name (vence $exp, límite $limit)"
}

# Crea un usuario SSH preguntando los datos y muestra su ficha (la usan [P] y los menús de los túneles)
user_create_prompt() {
    local name pass days limit
    read -rp "Usuario: " name; read -rp "Clave (se ve al escribir): " pass
    read -rp "Días de validez [30]: " days; read -rp "Límite de conexiones (0 = sin límite) [1]: " limit
    if user_create "$name" "$pass" "${days:-30}" "${limit:-1}"; then
        user_card "$name" "$pass" "${days:-30}" "${limit:-1}"
    fi
}

# Ficha del usuario recién creado (con la clave a la vista, para copiarla y pasarla al cliente)
user_card() { # nombre clave dias limite
    local name="$1" pass="$2" days="$3" limit="$4" exp ip
    exp="$(date -d "+${days} days" +%F)"
    # IP pública (en Azure/Oracle la de la interfaz es privada); si no responde se usa la local
    ip="$(curl -4 -fsS -m 4 https://api.ipify.org 2>/dev/null)"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ip="$(server_ip 2>/dev/null)"
    echo
    bar
    printf ' %sUsuario :%s %s\n' "$Y" "$N" "$name"
    printf ' %sClave   :%s %s\n' "$Y" "$N" "$pass"
    printf ' %sIP      :%s %s\n' "$Y" "$N" "$ip"
    printf ' %sVence   :%s %s (%s días)\n' "$Y" "$N" "$exp" "$days"
    if [[ "$limit" == 0 ]]; then printf ' %sLímite  :%s sin límite\n' "$Y" "$N"
    else printf ' %sLímite  :%s %s conexión(es)\n' "$Y" "$N" "$limit"; fi
    bar
}

user_delete() {
    local name="$1"
    db_has "$name" || { err "Ese usuario no está gestionado por ${APP_NAME}."; return 1; }
    pkill -KILL -u "$name" 2>/dev/null || true
    userdel -f "$name" 2>/dev/null || true
    awk -F'|' -v u="$name" '$1 != u' "$USERS_DB" > "$USERS_DB.tmp" \
        && install -m 600 "$USERS_DB.tmp" "$USERS_DB"
    rm -f "$USERS_DB.tmp"
    ok "Usuario $name eliminado."
    tg_send "Usuario eliminado: $name"
}

user_renew() { # nombre dias
    local name="$1" days="$2" exp
    db_has "$name" || { err "Usuario no gestionado."; return 1; }
    [[ "$days" =~ ^[0-9]+$ && "$days" -ge 1 ]] || { err "Días inválidos."; return 1; }
    exp="$(date -d "+${days} days" +%F)"
    chage -E "$exp" "$name"; usermod -U "$name" 2>/dev/null || true
    awk -F'|' -v OFS='|' -v u="$name" -v e="$exp" '$1==u{$2=e}1' "$USERS_DB" > "$USERS_DB.tmp" \
        && install -m 600 "$USERS_DB.tmp" "$USERS_DB" && rm -f "$USERS_DB.tmp"
    ok "Usuario $name renovado hasta $exp."
}

user_set_limit() { # nombre limite
    local name="$1" limit="$2"
    db_has "$name" || { err "Usuario no gestionado."; return 1; }
    [[ "$limit" =~ ^[0-9]+$ ]] || { err "Límite inválido."; return 1; }
    awk -F'|' -v OFS='|' -v u="$name" -v l="$limit" '$1==u{$3=l}1' "$USERS_DB" > "$USERS_DB.tmp" \
        && install -m 600 "$USERS_DB.tmp" "$USERS_DB" && rm -f "$USERS_DB.tmp"
    ok "Límite de $name: $limit"
}


# Conexiones abiertas por usuario, en una sola pasada. Llena ONLINE_OF[usuario]=n y ONLINE_PIDS[usuario]="pid pid".
#  - OpenSSH: el proceso de la sesión corre como el usuario y se llama "sshd" (o "sshd-session" desde OpenSSH 9.8 / Ubuntu 25.04+).
#  - Dropbear: cuando solo hace de túnel NO cambia de usuario, así que se lee el journal ("auth succeeded for 'usuario'")
#    y se cuentan los procesos dropbear de esas sesiones que siguen vivos.
users_online_load() {
    local pid u c
    local -A alive=()
    declare -gA ONLINE_OF=() ONLINE_PIDS=()
    while read -r pid u c; do
        [[ "$c" == dropbear ]] && alive[$pid]=1
        [[ "$c" == sshd || "$c" == sshd-session ]] && [[ "$u" != root ]] || continue
        ONLINE_OF["$u"]=$(( ${ONLINE_OF["$u"]:-0} + 1 )); ONLINE_PIDS["$u"]+="$pid "
    done < <(ps -eo pid=,user:32=,comm= 2>/dev/null)
    if (( ${#alive[@]} > 0 )); then
        while read -r pid u; do
            [[ -n "${alive[$pid]:-}" ]] || continue
            ONLINE_OF["$u"]=$(( ${ONLINE_OF["$u"]:-0} + 1 )); ONLINE_PIDS["$u"]+="$pid "
            unset 'alive[$pid]'
        done < <(journalctl -u "${APP_SLUG}-dropbear" -o short --no-pager -q --since "30 days ago" 2>/dev/null \
                 | sed -nE "s/.*dropbear\[([0-9]+)\]: .*auth succeeded for '([^']+)'.*/\1 \2/p" | tac)
    fi
    return 0
}

# Días que le quedan a una cuenta (negativo = vencida)
user_days_left() { # AAAA-MM-DD
    local t e
    e="$(date -d "$1" +%s 2>/dev/null)" || { echo 0; return; }
    t="$(date -d "$(date +%F)" +%s)"
    echo $(( (e - t) / 86400 ))
}

# Resumen de una línea para el menú de usuarios
users_summary() {
    local u tot=0 conn=0 on=0 n
    [[ -s "$USERS_DB" ]] || { echo " Usuarios: 0"; return; }
    users_online_load
    while IFS='|' read -r u _; do
        [[ -n "$u" ]] || continue
        tot=$((tot + 1)); n="${ONLINE_OF[$u]:-0}"
        if (( n > 0 )); then on=$((on + 1)); conn=$((conn + n)); fi
    done < "$USERS_DB"
    printf ' %sUsuarios:%s %s   %sEn línea:%s %s   %sConexiones:%s %s\n' "$Y" "$N" "$tot" "$G" "$N" "$on" "$C" "$N" "$conn"
}

# Lista de usuarios: vence, días que quedan, cupo (para cuántas conexiones se creó la cuenta) y conectados ahora.
user_list() { # [solo_conectados]
    local only="${1:-}" u e l d n cupo dtxt dcol ocol tot=0 conn=0 on=0 shown=0 exp_n=0
    [[ -s "$USERS_DB" ]] || { info "No hay usuarios creados."; return; }
    users_online_load
    printf ' %s%-15s %-10s %-7s %-9s %s%s\n' "$WH" USUARIO VENCE QUEDAN CUPO ONLINE "$N"
    while IFS='|' read -r u e l _; do
        [[ -n "$u" ]] || continue
        tot=$((tot + 1)); n="${ONLINE_OF[$u]:-0}"
        (( n > 0 )) && { on=$((on + 1)); conn=$((conn + n)); }
        [[ -n "$only" && "$n" -eq 0 ]] && continue
        d="$(user_days_left "$e")"
        if (( d < 0 )); then dtxt="VENCIDA"; dcol="$R"; exp_n=$((exp_n + 1))
        elif (( d <= 3 )); then dtxt="${d} d"; dcol="$Y"
        else dtxt="${d} d"; dcol="$N"; fi
        if [[ "$l" == 0 || -z "$l" ]]; then cupo="ilimitado"; else cupo="para $l"; fi
        ocol="$N"; (( n > 0 )) && ocol="$G"
        printf ' %-15.15s %-10s %s%-7s%s %-9s %s%s%s\n' "$u" "$e" "$dcol" "$dtxt" "$N" "$cupo" "$ocol" "$n" "$N"
        shown=$((shown + 1))
    done < "$USERS_DB"
    (( shown == 0 )) && echo " Nadie conectado en este momento."
    echo
    printf ' %sUsuarios:%s %s   %sEn línea:%s %s   %sConexiones:%s %s' "$Y" "$N" "$tot" "$G" "$N" "$on" "$C" "$N" "$conn"
    (( exp_n > 0 )) && printf '   %sVencidas:%s %s' "$R" "$N" "$exp_n"
    echo
    echo " CUPO = para cuántas conexiones a la vez es la cuenta."
    echo " ONLINE = conexiones abiertas ahora."
}

user_online() { users_online_load; echo "${ONLINE_OF[$1]:-0}"; }

# Elimina usuarios vencidos
users_expire_sweep() {
    local today u e; today="$(date +%F)"
    while IFS='|' read -r u e _; do
        [[ -n "$u" && "$e" < "$today" ]] && user_delete "$u"
    done < <(cat "$USERS_DB")
}

# Corta conexiones que superen el límite de cada usuario
users_enforce_limits() {
    local u l n pids p i
    users_online_load
    while IFS='|' read -r u _ l _; do
        [[ -n "$u" && "$l" =~ ^[0-9]+$ && "$l" -gt 0 ]] || continue
        n="${ONLINE_OF[$u]:-0}"
        if (( n > l )); then
            # corta las sesiones más nuevas (pid mayor) hasta quedar en el límite
            pids="$(printf '%s\n' ${ONLINE_PIDS[$u]} | sort -n | tail -n $((n - l)))"
            for p in $pids; do kill -KILL "$p" 2>/dev/null || true; done
            tg_send "Límite excedido: $u tenía $n conexiones (máx $l)"
        fi
    done < <(cat "$USERS_DB")
}
