#!/usr/bin/env bash
# Arreglos para VPS en la nube (Oracle / AWS / Azure). shellcheck shell=bash

cloud_provider() {
    local v="" tag=""
    v="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
    tag="$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)"
    case "$v $tag" in
        *Microsoft*|*7783-7084*) echo "Azure" ;;
        *Amazon*)                echo "AWS" ;;
        *OracleCloud*|*Oracle*)  echo "Oracle Cloud" ;;
        *) echo "desconocido (${v:-?})" ;;
    esac
}

cloud_diag() {
    echo "Proveedor detectado: $(cloud_provider)"
    echo
    echo "Reglas iptables INPUT:"; iptables -S INPUT 2>/dev/null | head -20
    echo
    echo "sshd - PasswordAuthentication efectivo (global): $(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
    [[ -f "/etc/ssh/sshd_config.d/90-${APP_SLUG}.conf" ]] \
        && echo "Usuarios del panel (grupo ${USERS_GROUP}): login por clave HABILITADO" \
        || echo "Usuarios del panel: login por clave aún no habilitado (se habilita al crear el primer usuario)"
    echo; echo "Puertos en escucha:"; ss -ltun 2>/dev/null | awk 'NR==1 || /LISTEN|UNCONN/' | head -25
}

cloud_fix_iptables() {
    local chain rule n=0
    echo "Oracle Cloud trae una regla REJECT en iptables que bloquea los puertos nuevos."
    echo "Se van a borrar solo las reglas '-j REJECT' de INPUT y FORWARD."
    confirm "¿Continuar?" || return 0
    for chain in INPUT FORWARD; do
        while read -r rule; do
            [[ "$rule" == "-A $chain "*"-j REJECT"* ]] || continue
            read -ra parts <<<"${rule/-A/-D}"
            iptables "${parts[@]}" 2>/dev/null && n=$((n + 1))
        done < <(iptables -S "$chain" 2>/dev/null)
    done
    ok "$n reglas REJECT eliminadas."
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && ok "Cambios guardados."
    else
        warn "Sin iptables-persistent los cambios se pierden al reiniciar."
        if confirm "¿Instalar iptables-persistent para guardarlos?"; then
            pkg_install iptables-persistent && netfilter-persistent save >/dev/null 2>&1 && ok "Guardado."
        fi
    fi
}

cloud_ports_help() {
    echo "Abrí estos puertos en el firewall de TU PROVEEDOR (no alcanza con el del servidor):"
    fw_ports | sort -u | sed 's/^/  - /'
    echo
    echo "Azure:  VM > Redes > Reglas de puerto de entrada (NSG) > Agregar regla."
    echo "AWS:    EC2 > Grupos de seguridad > Reglas de entrada."
    echo "Oracle: Red virtual en la nube > Lista de seguridad > Reglas de entrada."
    echo "        (y, en la VM, la opción 2 de este menú)"
}

ROOT_DROPIN="/etc/ssh/sshd_config.d/00-${APP_SLUG}-root.conf"

ssh_reload() { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; }

# Deja entrar por SSH como root con contraseña (típico en Azure/AWS/Oracle, que lo traen desactivado).
cloud_root_login() {
    local p1 p2 bak
    echo "Esto habilita SSH como root con contraseña en TODO el servidor."
    warn "Es práctico para tu VPS de pruebas, pero queda expuesto a ataques de fuerza bruta."
    warn "Usá una contraseña larga (12+ caracteres) y activá FAIL2BAN [21]."
    confirm "¿Continuar?" || return 0
    read -rsp "Contraseña nueva de root: " p1; echo
    read -rsp "Repetila: " p2; echo
    [[ -n "$p1" && "$p1" == "$p2" ]] || { err "Las contraseñas no coinciden o están vacías."; return 1; }
    (( ${#p1} >= 8 )) || { err "Mínimo 8 caracteres."; return 1; }
    echo "root:${p1}" | chpasswd || { err "No se pudo cambiar la contraseña."; return 1; }
    passwd -u root >/dev/null 2>&1 || true
    install -d -m 755 /etc/ssh/sshd_config.d
    bak="$(mktemp)"; [[ -f "$ROOT_DROPIN" ]] && cp -a "$ROOT_DROPIN" "$bak" || : > "$bak"
    # 00- se lee primero y en sshd gana la primera directiva (pisa 50-cloud-init.conf)
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "$ROOT_DROPIN"
    if ! sshd -t 2>/dev/null; then
        err "sshd rechazó la configuración; se revierte."
        if [[ -s "$bak" ]]; then cp -a "$bak" "$ROOT_DROPIN"; else rm -f "$ROOT_DROPIN"; fi
        rm -f "$bak"; return 1
    fi
    rm -f "$bak"
    if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
        warn "Tu sshd_config no incluye sshd_config.d: agregando la directiva al archivo principal."
        sed -i '1i PermitRootLogin yes\nPasswordAuthentication yes' /etc/ssh/sshd_config
        sshd -t 2>/dev/null || { err "Configuración inválida."; return 1; }
    fi
    ssh_reload
    ok "Listo. Efectivo: PermitRootLogin=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2}') PasswordAuthentication=$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}')"
    info "Probá desde otra sesión: ssh root@$(server_ip)  (no cierres esta hasta confirmar)."
    warn "En Azure/AWS/Oracle el puerto SSH ya está abierto; no hace falta tocar el NSG."
}

cloud_root_login_off() {
    confirm "¿Volver a bloquear el login de root con contraseña?" || return 0
    rm -f "$ROOT_DROPIN"; sshd -t 2>/dev/null && ssh_reload
    ok "Quitado. Efectivo: PermitRootLogin=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2}')"
}

cloudfix_menu() {
    local op
    while true; do
        title "Fix para VPS en la nube"
        echo " 1) Diagnóstico"
        echo " 2) Oracle: quitar reglas REJECT de iptables"
        echo " 3) Habilitar login por clave para los usuarios del panel (OpenSSH)"
        echo " 4) Qué puertos abrir en el firewall del proveedor"
        echo " 5) Configurar VPS: acceso root con contraseña"
        echo " 6) Quitar el acceso root con contraseña"
        echo " 0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) cloud_diag; pause ;;
            2) cloud_fix_iptables; pause ;;
            3) rm -f "/etc/ssh/sshd_config.d/90-${APP_SLUG}.conf"; ssh_tunnel_auth_ensure; pause ;;
            4) cloud_ports_help; pause ;;
            5) cloud_root_login; pause ;;
            6) cloud_root_login_off; pause ;;
            0) return ;;
        esac
    done
}
