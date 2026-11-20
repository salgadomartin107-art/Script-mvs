#!/usr/bin/env bash
# shellcheck disable=SC2034
# Pantalla "Protocolos / Herramientas" de dos columnas. shellcheck shell=bash

declare -A UNIT=(
    [1]="${APP_SLUG}-udpgw"        [2]="shadowsocks-libev"      [3]="${APP_SLUG}-wsproxy"
    [4]="${APP_SLUG}-xray"         [5]="${APP_SLUG}-stunnel"    [6]="${APP_SLUG}-dropbear"
    [7]="squid"                    [8]="openvpn-server@${APP_SLUG}" [9]="${APP_SLUG}-slowdns"
    [10]="wg-quick@${APP_SLUG}"    [11]="${APP_SLUG}-wspro"     [13]="${APP_SLUG}-hysteria"
    [14]="${APP_SLUG}-hcr"         [18]="${APP_SLUG}-udpcustom"  [21]="fail2ban"
    [36]="${APP_SLUG}-hevsocks5"  [37]="${APP_SLUG}-wstunnel"  [39]="${APP_SLUG}-mux"
    [31]="${APP_SLUG}-bot"         [33]="${APP_SLUG}-checkuser"
)

state_of() {
    case "$1" in
        30) [[ -f "/etc/cron.d/${APP_SLUG}-monitor" ]] && echo on || echo off ;;
        38) optimize_any_on && echo on || echo off ;;
        32) [[ -f "/etc/cron.d/${APP_SLUG}-notibot" ]] && echo on || echo off ;;
        12) trojan_active && echo on || echo off ;;
        34) tg_configured && echo on || echo off ;;
        15|16|17) echo na ;;
        *)  local u="${UNIT[$1]:-}"
            if [[ -n "$u" ]] && svc_is_active "$u"; then echo on; else echo off; fi ;;
    esac
}

# Uso de CPU, RAM y disco del VPS (se mide una vez por pantalla)
res_collect() {
    local u n s i w q sq st pt pi nt ni dtot didl
    R_CPU=0
    read -r _ u n s i w q sq st _ < /proc/stat 2>/dev/null || return 0
    pt=$((u + n + s + i + w + q + sq + st)); pi=$((i + w))
    sleep 0.25
    read -r _ u n s i w q sq st _ < /proc/stat
    nt=$((u + n + s + i + w + q + sq + st)); ni=$((i + w))
    dtot=$((nt - pt)); didl=$((ni - pi))
    (( dtot > 0 )) && R_CPU=$(( (100 * (dtot - didl)) / dtot ))
    R_CORES="$(nproc 2>/dev/null || echo 1)"; R_LOAD="$(cut -d' ' -f1 /proc/loadavg)"
    read -r R_MT R_MA < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} END{if(a=="") a=f+b+c; print t, a}' /proc/meminfo)
    R_MP=0; (( R_MT > 0 )) && R_MP=$(( (R_MT - R_MA) * 100 / R_MT ))
    read -r R_DT R_DU R_DP < <(df -Pk / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $2, $3, $5}')
    : "${R_DT:=0}" "${R_DU:=0}" "${R_DP:=0}"
}
res_size() { awk -v k="$1" 'BEGIN{ if (k >= 1048576) printf "%.1f GB", k/1048576; else printf "%d MB", k/1024 }'; }
res_size_c() { awk -v k="$1" 'BEGIN{ if (k >= 10485760) printf "%dG", k/1048576; else if (k >= 1048576) printf "%.1fG", k/1048576; else printf "%dM", k/1024 }'; }  # compacto: 3.7G

# Barra de uso para la pantalla clásica
res_bar() { # porcentaje [ancho]
    local p="${1:-0}" w="${2:-14}" n i out="" col="$G"
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    (( p > 100 )) && p=100
    (( p >= 70 )) && col="$Y"; (( p >= 90 )) && col="$R"
    n=$(( p * w / 100 ))
    for ((i = 0; i < w; i++)); do if (( i < n )); then out+="█"; else out+="░"; fi; done
    printf '%s%s%s %3d%%' "$col" "$out" "$N" "$p"
}

panel_resources() {
    res_collect
    printf ' %sCPU  %s %s %s núcleo%s · carga %s%s\n' "$R" "$N" "$(res_bar "$R_CPU")" "$R_CORES" "$([[ "$R_CORES" == 1 ]] || echo s)" "$R_LOAD" "$N"
    printf ' %sRAM  %s %s %s de %s · libre %s\n' "$R" "$N" "$(res_bar "$R_MP")" "$(res_size $((R_MT - R_MA)))" "$(res_size "$R_MT")" "$(res_size "$R_MA")"
    printf ' %sDISCO%s %s %s de %s · libre %s\n' "$R" "$N" "$(res_bar "$R_DP")" "$(res_size "$R_DU")" "$(res_size "$R_DT")" "$(res_size $((R_DT - R_DU)))"
}

# Barra de la pantalla en cajas: 13 celdas, roja si el uso llega al 90 %
res_bar_box() { # porcentaje color
    local p="$1" col="$2" n i f="" e=""
    (( p > 100 )) && p=100; (( p >= 90 )) && col="$K_RED"
    n=$(( p * 13 / 100 ))
    for ((i = 0; i < 13; i++)); do if (( i < n )); then f+="█"; else e+="░"; fi; done
    printf '%s%s%s%s%s %s%3d%%%s' "$col" "$f" "$K_DIM" "$e" "$N" "$col" "$p" "$N"
}

# Datos de servicios sin pantalla propia
udpgw_info()    { echo "UDPGW escuchando en 127.0.0.1:$(conf_get UDPGW_PORT)"; }
dropbear_info() { echo "Dropbear, puertos: $(dropbear_ports)"; }
ssl_info()      { echo "SSL/TLS, puerto: $(conf_get SSL_PORT) (certificado autofirmado)"; }
squid_info()    { echo "Proxy HTTP, puerto: $(conf_get SQUID_PORT)"; }
openvpn_info()  {
    echo "Puerto: $(conf_get OVPN_PORT)/$(conf_get OVPN_PROTO)"
    echo "Archivo de cliente: $OVPN_FILE"
    echo "Para repartirlo por un enlace, usá ARCHIVO ONLINE [A]."
}

# Lista "ETIQUETA|puertos" de los servicios que tienen puerto configurado
port_specs() {
    local -a spec=(
        "DROPBEAR|$(dropbear_ports)"        "BADVPN|$(conf_get UDPGW_PORT)"
        "SSH|$(sshd_ports | tr '\n' ' ' | xargs)" "UDP|$(conf_get HY_PORT)"
        "ARCHIVOS|$(conf_get FILESERVER_PORT)" "PYTHON|$(wsproxy_ports)"
        "SSL|$(conf_get SSL_PORT)"          "WS-PRO|$(wspro_ports)"
        "SQUID|$(conf_get SQUID_PORT)"      "OPENVPN|$(conf_get OVPN_PORT)"
        "V2RAY|$(conf_get XRAY_PORT)"       "WG|$(conf_get WG_PORT)"
        "TROJAN|$(conf_get TROJAN_PORT)"    "SS|$(conf_get SS_PORT)"
        "CHECK|$(conf_get CHECKUSER_PORT)"  "HCR|$(conf_get HCR_PORT)" "UDPC|$(conf_get UDPC_PORT)"
        "SOCKS5|$(conf_get HEVS_PORT)"      "WSTUN|$(conf_get WST_PORT)"
        "NGINX|$(conf_get NGX_PORT)"        "WSFY|$(conf_get WSFY_PORT)"        "MUX|$(conf_get MUX_PORT)"
    )
    local e
    for e in "${spec[@]}"; do [[ -n "${e#*|}" ]] && printf '%s\n' "$e"; done
    return 0
}

panel_ports() { # pantalla clásica
    local -a items=()
    local e i
    while IFS= read -r e; do items+=("$(kv "${e%%|*}" "${e#*|}")"); done < <(port_specs)
    for ((i = 0; i < ${#items[@]}; i += 2)); do
        printf ' %s  %s\n' "${items[$i]}" "${items[$((i + 1))]:-}"
    done
}

# Listas de PROTOCOLOS (solo números) y HERRAMIENTAS (letras A, B, C…; Z y X en rojo).
# El "id" interno de cada herramienta no cambia: panel_menu traduce la tecla.
panel_lists() {
    P1=( "1|BADVPN|$(state_of 1)" "2|SOCKS LIBEV|$(state_of 2)" "3|SOCKS PYTHON|$(state_of 3)"
         "4|V2RAY/XRAY|$(state_of 4)" "5|SSL/TLS|$(state_of 5)" "6|DROPBEAR|$(state_of 6)"
         "7|SQUID|$(state_of 7)" "8|OPENVPN|$(state_of 8)" "9|SLOWDNS|$(state_of 9)"
         "10|WIREGUARD|$(state_of 10)" "11|WS-PRO|$(state_of 11)" "12|TROJAN|$(state_of 12)"
         "13|HYSTERIA2|$(state_of 13)" "14|HCR|$(state_of 14)" "15|PSIPHON|na"
         "16|UDP-ZIVPN|na" "17|UDPs Request|na" "18|UDP-CUSTOM|$(state_of 18)" "19|SOCKS5 + UDP|$(state_of 36)" "20|WSTUNNEL|$(state_of 37)"
         "21|MULTIPLEXOR|$(state_of 39)" )
    T1=( "A|ARCHIVO ONLINE|" "B|FIREWALL|" "C|FAIL2BAN (PROTEC.)|" "D|DETALLES SISTEMA|"
         "E|TCP BBR|" "F|DNS SERVIDOR|" "G|LIBERAR RAM|" "H|SCANNER SUBDOMINIO|"
         "I|TEST DE VELOCIDAD|" "J|FIX ORACLE/AWS/AZR|" "K|HERRAM. BASICAS|"
         "L|BOT TELEGRAM|$(state_of 31)" "M|NOTI-BOT|$(state_of 32)"
         "N|CHECK-USER|$(state_of 33)" "O|TELEGRAM|$(state_of 34)" "P|USUARIOS SSH|" "Q|OPTIMIZAR|$(state_of 38)"
         "Z|ACTUALIZAR SCRIPT|" "X|DESINSTALAR|" "0|◄ SALIR|" )
}

# La pantalla en cajas necesita una terminal real de al menos 57 columnas
panel_boxed_ok() { [[ -t 1 ]] && (( $(tput cols 2>/dev/null || echo 0) >= 57 )); }

panel_screen_classic() {
    local -a P1 T1
    panel_lists
    clear
    hline ═
    printf ' %s ❯❯❯❯❯❯ SCRIPT %s ❮❮❮❮❮❮ %s %s[Version %s]%s\n' "$BGY" "$APP_NAME" "$N" "$G" "${APP_VERSION:-1.0}" "$N"
    hline ═
    panel_resources
    hline ─
    panel_ports
    hline ─
    printf ' %s%s%s      %s%s%s\n' "$BGG" "      PROTOCOLOS      " "$N" "$BGR" "      HERRAMIENTAS      " "$N"
    hline ─
    print_rows P1 T1
    hline ─
}

panel_screen_boxed() {
    local -a P1 T1 ports=() L=() Rr=()
    local e i n half cores_s title ver c
    panel_lists
    res_collect
    clear
    # --- cabecera ---
    ver="[Version ${APP_VERSION:-1.0}]"
    n=$(( 5 + 1 + 6 + 1 + ${#APP_NAME} + 1 + 5 + 2 + ${#ver} ))
    c=$(( (57 - n) / 2 + 1 ))
    box_edge1 "$K_BLUE" ╭ ╮
    box_row1  "$K_BLUE" "$(printf '\e[%dG%s❯❯❯❯❯ SCRIPT %s%s %s❮❮❮❮❮  %s%s%s' "$c" "$K_YEL" "$K_RED" "$APP_NAME" "$K_YEL" "$K_CYA" "$ver" "$N")"
    box_edge1 "$K_BLUE" ╰ ╯
    # --- recursos ---
    [[ "$R_CORES" == 1 ]] && cores_s="núcleo" || cores_s="núcleos"
    box_edge2 ╭ ╮ "$K_BLUE" "$K_BLUE"
    box_row2 "$K_BLUE" "$K_BLUE" \
        "$(printf '\e[3G%sCPU\e[9G%s' "$K_YEL" "$(res_bar_box "$R_CPU" "$K_YEL")")" \
        "$(printf '\e[32G%s%s %s · carga %s%s%s' "$WH" "$R_CORES" "$cores_s" "$K_YEL" "$R_LOAD" "$N")"
    box_row2 "$K_BLUE" "$K_BLUE" \
        "$(printf '\e[3G%sRAM\e[9G%s' "$K_GRN" "$(res_bar_box "$R_MP" "$K_GRN")")" \
        "$(printf '\e[32G%s%.26s%s' "$WH" "$(res_size_c $((R_MT - R_MA)))/$(res_size_c "$R_MT") · libre $(res_size_c "$R_MA")" "$N")"
    box_row2 "$K_BLUE" "$K_BLUE" \
        "$(printf '\e[3G%sDISCO\e[9G%s' "$K_CYA" "$(res_bar_box "$R_DP" "$K_CYA")")" \
        "$(printf '\e[32G%s%.26s%s' "$WH" "$(res_size_c "$R_DU")/$(res_size_c "$R_DT") · libre $(res_size_c $((R_DT - R_DU)))" "$N")"
    box_edge2 ╰ ╯ "$K_BLUE" "$K_BLUE"
    # --- puertos (dos cajas moradas, se reparten por mitades) ---
    while IFS= read -r e; do ports+=("$e"); done < <(port_specs)
    n=${#ports[@]}; half=$(( (n + 1) / 2 ))
    if (( n > 0 )); then
        box_edge2 ╭ ╮ "$K_PURP" "$K_PURP"
        for ((i = 0; i < half; i++)); do
            L[i]=""; Rr[i]=""
            L[i]="$(port_cell 0 "$i" "${ports[$i]%%|*}" "${ports[$i]#*|}")"
            (( i + half < n )) && Rr[i]="$(port_cell 29 "$i" "${ports[$((i + half))]%%|*}" "${ports[$((i + half))]#*|}")"
            box_row2 "$K_PURP" "$K_PURP" "${L[$i]}" "${Rr[$i]}"
        done
        box_edge2 ╰ ╯ "$K_PURP" "$K_PURP"
    fi
    # --- banners y listas ---
    banner2 "PROTOCOLOS" "HERRAMIENTAS"
    box_edge2 ╭ ╮ "$K_BLUE" "$K_BLUE"
    n=${#P1[@]}; (( ${#T1[@]} > n )) && n=${#T1[@]}
    for ((i = 0; i < n; i++)); do
        box_row2 "$K_BLUE" "$K_BLUE" "$(item_from 0 "${P1[$i]:-}")" "$(item_from 29 "${T1[$i]:-}")"
    done
    box_edge2 ╰ ╯ "$K_BLUE" "$K_BLUE"
    # --- prompt en caja: el cursor queda dentro ---
    box_edge1 "$K_BLUE" ╭ ╮
    box_row1  "$K_BLUE" "$(printf '\e[3G%s▶\e[5G%sSeleccioná una opción:%s' "$K_CYA" "$K_YEL" "$N")"
    printf '\e[1G%s╰%s╯%s\e[1A\e[29G' "$K_BLUE" "$RULE55" "$N"
}

panel_screen() {
    if panel_boxed_ok; then PANEL_BOXED=1; panel_screen_boxed; else PANEL_BOXED=0; panel_screen_classic; fi
}

not_available() {
    title "No disponible"
    case "$1" in
        15) echo "Psiphon es una red operada por Psiphon Inc.: no existe un servidor propio que se pueda instalar." ;;
        *)  echo "ZIVPN y UDPs Request dependen de binarios cerrados que no se pueden auditar,"
            echo "y este panel no instala software que no pueda verificarse." ;;
    esac
    echo
    echo "Alternativas abiertas incluidas: HYSTERIA2 [13] (UDP/QUIC) y BADVPN [1] (UDP sobre SSH)."
    pause
}

# Alta / gestión genérica de un servicio
manage() { # clave etiqueta fn_instalar fn_datos fn_quitar
    local k="$1" label="$2" inst="$3" info="$4" rem="$5" op unit="${UNIT[$1]:-}"
    if [[ "$(state_of "$k")" != on ]]; then "$inst"; pause; return; fi
    while true; do
        title "$label"
        echo " Estado: ${G}ACTIVO${N}"; bar
        echo " 1) Ver datos"
        echo " 2) Reinstalar / cambiar puerto"
        echo " 3) Quitar"
        echo " 0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) "$info"; pause ;;
            2) [[ -n "$unit" ]] && systemctl stop "$unit" 2>/dev/null
               "$inst" || { [[ -n "$unit" ]] && systemctl start "$unit" 2>/dev/null; }
               pause ;;
            3) confirm "¿Quitar $label?" && "$rem"; pause; return ;;
            0) return ;;
        esac
    done
}

panel_menu() {
    local op
    while true; do
        panel_screen
        PANEL_PROMPT=1
        if (( PANEL_BOXED )); then read -r op || { PANEL_PROMPT=0; return; }; printf '\n'      # el cursor ya está dentro de la caja
        else read -rp "${C}▸${N} Seleccioná una opción: " op || { PANEL_PROMPT=0; return; }; fi   # sin terminal (EOF): salir, no girar
        PANEL_PROMPT=0
        local k="${op^^}" id
        case "$k" in      # tecla del panel -> id interno
            0|[1-9]|1[0-8]|Z|X) id="$k" ;;
            19) id=36 ;; 20) id=37 ;; 21) id=39 ;;
            A) id=19 ;; B) id=20 ;; C) id=21 ;; D) id=22 ;; E) id=23 ;; F) id=24 ;; G) id=25 ;; H) id=26 ;;
            I) id=27 ;; J) id=28 ;; K) id=29 ;; L) id=31 ;; M) id=32 ;; N) id=33 ;; O) id=34 ;; P) id=35 ;; Q) id=38 ;;
            *) continue ;;
        esac
        case "$id" in
            1)  manage 1  BADVPN        install_badvpn      udpgw_info        remove_badvpn ;;
            2)  manage 2  SHADOWSOCKS   install_shadowsocks shadowsocks_info  remove_shadowsocks ;;
            3)  wsproxy_menu ;;
            4)  xray_menu ;;
            5)  manage 5  "SSL/TLS"     install_stunnel     ssl_info          remove_stunnel ;;
            6)  dropbear_menu ;;
            7)  manage 7  SQUID         install_squid       squid_info        remove_squid ;;
            8)  manage 8  OPENVPN       install_openvpn     openvpn_info      remove_openvpn ;;
            9)  manage 9  SLOWDNS       install_slowdns     slowdns_info      remove_slowdns ;;
            10) wireguard_menu ;;
            11) wspro_menu ;;
            12) trojan_menu ;;
            13) manage 13 HYSTERIA2     install_hysteria    hysteria_info     remove_hysteria ;;
            14) manage 14 HCR           install_hcr         hcr_info          remove_hcr ;;
            15|16|17) not_available "${id}" ;;
            18) manage 18 UDP-CUSTOM    install_udpcustom   udpcustom_info    remove_udpcustom ;;
            36) hevsocks_menu ;;
            37) wstunnel_menu ;;
            39) manage 39 MULTIPLEXOR   install_mux         mux_info          remove_mux ;;
            38) optimize_menu ;;
            19) fileserver_menu ;;
            20) firewall_menu ;;
            21) manage 21 FAIL2BAN      install_fail2ban    fail2ban_status   remove_fail2ban ;;
            22) title "Información del sistema"; sysinfo; pause ;;
            23) bbr_menu ;;
            24) dns_menu ;;
            25) title "Liberar RAM"; ram_free; pause ;;
            26) title "Escáner de subdominios"; subdomain_scan; pause ;;
            27) title "Test de velocidad"; run_speedtest; pause ;;
            28) cloudfix_menu ;;
            29) basics_menu ;;
            31) manage 31 "BOT TELEGRAM" install_bot        bot_info          remove_bot ;;
            32) manage 32 NOTI-BOT      install_notibot     notibot_info      remove_notibot ;;
            33) manage 33 CHECK-USER    install_checkuser   checkuser_info    remove_checkuser ;;
            34) title "Telegram"; tg_configure; pause ;;
            35) menu_users ;;
            Z)  update_script; pause ;;
            X)  uninstall_all ;;
            0)  return ;;
        esac
    done
}
