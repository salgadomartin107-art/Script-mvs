#!/usr/bin/env bash
# Firewall del servidor con ufw. OJO: el firewall de la nube (NSG de Azure, Security Group de
# AWS, Security List de Oracle) es otro y se configura en el panel del proveedor.
# shellcheck shell=bash

fw_ports() { # imprime puerto/protocolo de los servicios del panel
    local k v p
    for v in $(dropbear_ports); do echo "$v/tcp"; done
    for k in SSL_PORT SQUID_PORT SS_PORT XRAY_PORT TROJAN_PORT WSPROXY_PORT WSPROXY_EXTRA WSPRO_PORT CHECKUSER_PORT FILESERVER_PORT HCR_PORT; do
        for p in $(conf_get "$k"); do echo "$p/tcp"; done
    done
    for k in SS_PORT HY_PORT WG_PORT XRAY_UDP_PORTS; do
        for p in $(conf_get "$k"); do echo "$p/udp"; done
    done
    v="$(conf_get OVPN_PORT)"; p="$(conf_get OVPN_PROTO)"; [[ -n "$v" && -n "$p" ]] && echo "$v/$p"
    [[ -n "$(conf_get SLOWDNS_NS)" ]] && echo "53/udp"
    return 0
}

fw_enable() {
    local p
    echo "Se permitirán: SSH ($(sshd_ports | tr '\n' ' ')) y los puertos de tus servicios:"
    fw_ports | sort -u | tr '\n' ' '; echo
    warn "Si tu VPS está en la nube, también tenés que abrir esos puertos en el firewall del proveedor."
    confirm "¿Activar el firewall?" || return 0
    pkg_install ufw || { err "No se pudo instalar ufw."; return 1; }
    ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
    for p in $(sshd_ports); do ufw allow "$p/tcp" >/dev/null; done
    while read -r p; do [[ -n "$p" ]] && ufw allow "$p" >/dev/null; done < <(fw_ports | sort -u)
    # ufw bloquea por defecto el reenvío de paquetes: sin esto OpenVPN y WireGuard dejan de enrutar.
    if [[ -n "$(conf_get OVPN_PORT)" || -n "$(conf_get WG_PORT)" ]]; then
        sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    fi
    ufw --force enable >/dev/null && ok "Firewall activo."
}

fw_disable() { command -v ufw >/dev/null 2>&1 || { info "ufw no está instalado."; return 0; }; ufw --force disable >/dev/null && ok "Firewall desactivado."; }
fw_status()  { command -v ufw >/dev/null 2>&1 && ufw status verbose || info "ufw no está instalado."; }

fw_open() {
    local p proto
    command -v ufw >/dev/null 2>&1 || { err "Instalá/activá el firewall primero."; return 1; }
    read -rp "Puerto: " p; valid_port "$p" || { err "Puerto inválido."; return 1; }
    read -rp "Protocolo (tcp/udp) [tcp]: " proto; proto="${proto:-tcp}"
    [[ "$proto" == tcp || "$proto" == udp ]] || { err "Protocolo inválido."; return 1; }
    ufw allow "$p/$proto" >/dev/null && ok "Abierto $p/$proto."
}

fw_close() {
    local p proto
    command -v ufw >/dev/null 2>&1 || { err "ufw no está instalado."; return 1; }
    read -rp "Puerto: " p; valid_port "$p" || { err "Puerto inválido."; return 1; }
    read -rp "Protocolo (tcp/udp) [tcp]: " proto; proto="${proto:-tcp}"
    [[ "$proto" == tcp || "$proto" == udp ]] || { err "Protocolo inválido."; return 1; }
    for sshp in $(sshd_ports); do
        [[ "$p" == "$sshp" && "$proto" == tcp ]] && { err "Ese es tu puerto SSH: no lo cierro."; return 1; }
    done
    ufw delete allow "$p/$proto" >/dev/null && ok "Cerrado $p/$proto."
}

firewall_menu() {
    local op
    while true; do
        title "Firewall (ufw)"
        echo " 1) Estado                 4) Abrir un puerto"
        echo " 2) Activar (con reglas)   5) Cerrar un puerto"
        echo " 3) Desactivar             0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) fw_status; pause ;;
            2) fw_enable; pause ;;
            3) fw_disable; pause ;;
            4) fw_open; pause ;;
            5) fw_close; pause ;;
            0) return ;;
        esac
    done
}
