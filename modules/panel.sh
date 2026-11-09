#!/usr/bin/env bash
# shellcheck disable=SC2034
# Pantalla "Protocolos / Herramientas" de dos columnas. shellcheck shell=bash

declare -A UNIT=(
    [1]="${APP_SLUG}-udpgw"        [2]="shadowsocks-libev"      [3]="${APP_SLUG}-wsproxy"
    [4]="${APP_SLUG}-xray"         [5]="${APP_SLUG}-stunnel"    [6]="${APP_SLUG}-dropbear"
    [7]="squid"                    [8]="openvpn-server@${APP_SLUG}" [9]="${APP_SLUG}-slowdns"
    [10]="wg-quick@${APP_SLUG}"    [11]="${APP_SLUG}-wspro"     [13]="${APP_SLUG}-hysteria"
    [14]="${APP_SLUG}-hcr"         [18]="${APP_SLUG}-udpcustom"  [21]="fail2ban"
    [31]="${APP_SLUG}-bot"         [33]="${APP_SLUG}-checkuser"
)

state_of() {
    case "$1" in
        30) [[ -f "/etc/cron.d/${APP_SLUG}-monitor" ]] && echo on || echo off ;;
        32) [[ -f "/etc/cron.d/${APP_SLUG}-notibot" ]] && echo on || echo off ;;
        12) trojan_active && echo on || echo off ;;
        34) tg_configured && echo on || echo off ;;
        15|16|17) echo na ;;
        *)  local u="${UNIT[$1]:-}"
            if [[ -n "$u" ]] && svc_is_active "$u"; then echo on; else echo off; fi ;;
    esac
}

# Datos de servicios sin pantalla propia
udpgw_info()    { echo "UDPGW escuchando en 127.0.0.1:$(conf_get UDPGW_PORT)"; }
dropbear_info() { echo "Dropbear, puertos: $(dropbear_ports)"; }
ssl_info()      { echo "SSL/TLS, puerto: $(conf_get SSL_PORT) (certificado autofirmado)"; }
squid_info()    { echo "Proxy HTTP, puerto: $(conf_get SQUID_PORT)"; }
openvpn_info()  {
    echo "Puerto: $(conf_get OVPN_PORT)/$(conf_get OVPN_PROTO)"
    echo "Archivo de cliente: $OVPN_FILE"
    echo "Para repartirlo por un enlace, usá ARCHIVO ONLINE [19]."
}

panel_ports() {
    local -a items=() spec=(
        "DROPBEAR|$(dropbear_ports)"        "BADVPN|$(conf_get UDPGW_PORT)"
        "SSH|$(sshd_ports | tr '\n' ' ' | xargs)" "UDP|$(conf_get HY_PORT)"
        "ARCHIVOS|$(conf_get FILESERVER_PORT)" "PYTHON|$(wsproxy_ports)"
        "SSL|$(conf_get SSL_PORT)"          "WS-PRO|$(conf_get WSPRO_PORT)"
        "SQUID|$(conf_get SQUID_PORT)"      "OPENVPN|$(conf_get OVPN_PORT)"
        "V2RAY|$(conf_get XRAY_PORT)"       "WG|$(conf_get WG_PORT)"
        "TROJAN|$(conf_get TROJAN_PORT)"    "SS|$(conf_get SS_PORT)"
        "CHECK|$(conf_get CHECKUSER_PORT)" "HCR|$(conf_get HCR_PORT)" "UDPC|$(conf_get UDPC_PORT)"
    )
    local e i
    for e in "${spec[@]}"; do
        [[ -n "${e#*|}" ]] && items+=("$(kv "${e%%|*}" "${e#*|}")")
    done
    for ((i = 0; i < ${#items[@]}; i += 2)); do
        printf ' %s  %s\n' "${items[$i]}" "${items[$((i + 1))]:-}"
    done
}

panel_screen() {
    local -a P1 T1
    # Izquierda: PROTOCOLOS (solo números). Derecha: HERRAMIENTAS (lo demás; Z y X con letra roja).
    P1=( "1|BADVPN|$(state_of 1)" "2|SOCKS LIBEV|$(state_of 2)" "3|SOCKS PYTHON|$(state_of 3)"
         "4|V2RAY/XRAY|$(state_of 4)" "5|SSL/TLS|$(state_of 5)" "6|DROPBEAR|$(state_of 6)"
         "7|SQUID|$(state_of 7)" "8|OPENVPN|$(state_of 8)" "9|SLOWDNS|$(state_of 9)"
         "10|WIREGUARD|$(state_of 10)" "11|WS-PRO|$(state_of 11)" "12|TROJAN|$(state_of 12)"
         "13|HYSTERIA2|$(state_of 13)" "14|HCR|$(state_of 14)" "15|PSIPHON|na"
         "16|UDP-ZIVPN|na" "17|UDPs Request|na" "18|UDP-CUSTOM|$(state_of 18)" )
    T1=( "19|ARCHIVO ONLINE|" "20|FIREWALL|" "21|FAIL2BAN PROTECCION|" "22|DETALLES DE SISTEMA|"
         "23|TCP BBR|" "24|DNS SERVIDOR|" "25|LIBERAR RAM|" "26|SCANNER SUBDOMINIO|"
         "27|PRUEBA DE VELOCIDAD|" "28|FIX ORACLE/AWS/AZR|" "29|HERRAMIENTAS BASICOS|"
         "30|MONITOR|$(state_of 30)" "31|BOT TELEGRAM|$(state_of 31)" "32|NOTI-BOT|$(state_of 32)"
         "33|CHECK-USER|$(state_of 33)" "34|TELEGRAM|$(state_of 34)" "35|USUARIOS SSH|"
         "Z|ACTUALIZAR SCRIPT|" "X|DESINSTALAR|" "0|◄ SALIR|" )

    clear
    hline ═
    printf ' %s ❯❯❯❯❯❯ SCRIPT %s ❮❮❮❮❮❮ %s %s[Version %s]%s\n' "$BGY" "$APP_NAME" "$N" "$G" "${APP_VERSION:-1.0}" "$N"
    hline ═
    panel_ports
    hline ─
    printf ' %s%s%s      %s%s%s\n' "$BGG" "      PROTOCOLOS      " "$N" "$BGR" "      HERRAMIENTAS      " "$N"
    hline ─
    print_rows P1 T1
    hline ─
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
        read -rp "${C}▸${N} Seleccioná una opción: " op || return   # sin terminal (EOF): salir, no girar
        case "${op^^}" in
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
            11) manage 11 WS-PRO        install_wspro       wspro_info        remove_wspro ;;
            12) trojan_menu ;;
            13) manage 13 HYSTERIA2     install_hysteria    hysteria_info     remove_hysteria ;;
            14) manage 14 HCR           install_hcr         hcr_info          remove_hcr ;;
            15|16|17) not_available "${op}" ;;
            18) manage 18 UDP-CUSTOM    install_udpcustom   udpcustom_info    remove_udpcustom ;;
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
            30) manage 30 MONITOR       install_monitor     monitor_info      remove_monitor ;;
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
