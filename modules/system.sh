#!/usr/bin/env bash
# Herramientas del sistema: información, BBR, DNS, RAM y escáner de subdominios.
# shellcheck shell=bash

# ---- Información ----
sysinfo() {
    local os cpu cores conns
    os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-desconocido}")"
    cpu="$(awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)"
    cores="$(nproc 2>/dev/null)"
    conns="$(ss -tn state established 2>/dev/null | awk 'NR>1' | wc -l)"
    echo "Sistema:    $os"
    echo "Kernel:     $(uname -r)  ($(uname -m))"
    echo "CPU:        ${cpu:-?} x${cores:-?}"
    echo "RAM:        $(free -h | awk '/^Mem:/{print $3 " usados de " $2}')"
    echo "Swap:       $(free -h | awk '/^Swap:/{print $3 " usados de " $2}')"
    echo "Disco /:    $(df -h / | awk 'NR==2{print $3 " usados de " $2 " (" $5 ")"}')"
    echo "Uptime:     $(uptime -p)"
    echo "Carga:      $(cut -d' ' -f1-3 /proc/loadavg)"
    echo "IP local:   $(server_ip)"
    echo "Conexiones: $conns TCP establecidas"
    echo "Usuarios:   $(wc -l < "$USERS_DB" 2>/dev/null || echo 0) en el panel"
}

# ---- TCP BBR ----
bbr_status() { echo "Control de congestión: $(sysctl -n net.ipv4.tcp_congestion_control)   Cola: $(sysctl -n net.core.default_qdisc)"; }

bbr_menu() {
    local op f="/etc/sysctl.d/98-${APP_SLUG}-bbr.conf"
    while true; do
        title "TCP BBR"; bbr_status; bar
        echo " 1) Activar BBR   2) Desactivar (volver a cubic)   0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1)
                modprobe tcp_bbr 2>/dev/null || true
                if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
                    err "Tu kernel no ofrece BBR."
                else
                    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > "$f"
                    sysctl -q -p "$f" >/dev/null 2>&1; bbr_status
                    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] && ok "BBR activo." || warn "No se aplicó."
                fi; pause ;;
            2) rm -f "$f"; sysctl -q -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1; bbr_status; pause ;;
            0) return ;;
        esac
    done
}

# ---- DNS del servidor (systemd-resolved) ----
dns_menu() {
    local op list f=/etc/systemd/resolved.conf.d/${APP_SLUG}.conf ip ok_ips=()
    while true; do
        title "DNS del servidor"
        resolvectl status 2>/dev/null | grep -E 'DNS Servers|Current DNS' | head -3
        bar
        echo " 1) Cloudflare (1.1.1.1)   3) Quad9 (9.9.9.9)    5) Restaurar original"
        echo " 2) Google (8.8.8.8)       4) Personalizado      0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) list="1.1.1.1 1.0.0.1" ;;
            2) list="8.8.8.8 8.8.4.4" ;;
            3) list="9.9.9.9 149.112.112.112" ;;
            4) read -rp "IPv4 de los DNS separadas por espacio: " list ;;
            5) rm -f "$f"; systemctl restart systemd-resolved 2>/dev/null; ok "Restaurado."; pause; continue ;;
            0) return ;;
            *) continue ;;
        esac
        systemctl is-active --quiet systemd-resolved || { err "systemd-resolved no está activo en este sistema."; pause; continue; }
        ok_ips=()
        for ip in $list; do
            [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ok_ips+=("$ip") || warn "Se ignora: $ip"
        done
        (( ${#ok_ips[@]} )) || { err "Ninguna IP válida."; pause; continue; }
        install -d /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNS=%s\n' "${ok_ips[*]}" > "$f"
        systemctl restart systemd-resolved && ok "DNS aplicado: ${ok_ips[*]}"; pause
    done
}

# ---- Liberar RAM ----
ram_free() {
    echo "Antes:";   free -h | awk 'NR<=2'
    sync; echo 3 > /proc/sys/vm/drop_caches
    echo; echo "Después:"; free -h | awk 'NR<=2'
    info "Solo se libera caché; Linux la vuelve a usar cuando la necesita."
}

# ---- Escáner de subdominios (registros públicos de certificados, crt.sh) ----
subdomain_scan() {
    local d json names n=0 name ip
    read -rp "Dominio (ej: ejemplo.com): " d
    [[ "$d" =~ ^([a-z0-9-]+\.)+[a-z]{2,}$ ]] || { err "Dominio inválido."; return 1; }
    command -v jq >/dev/null 2>&1 || pkg_install jq || { err "Falta jq."; return 1; }
    info "Consultando crt.sh (se le envía el dominio)..."
    json="$(curl -fsS --max-time 40 "https://crt.sh/?q=%25.${d}&output=json")" || { err "crt.sh no respondió."; return 1; }
    names="$(jq -r '.[].name_value' <<<"$json" 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/^\*\.//' | grep -E "(^|\.)${d//./\\.}$" | sort -u | head -300)"
    [[ -n "$names" ]] || { info "Sin resultados."; return 0; }
    while read -r name; do
        ip="$(getent ahostsv4 "$name" 2>/dev/null | awk 'NR==1{print $1}')"
        printf '%-45s %s\n' "$name" "${ip:--}"; n=$((n + 1))
    done <<<"$names"
    ok "$n subdominios."
}
