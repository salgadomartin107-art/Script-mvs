#!/usr/bin/env bash
# Dropbear (SSH alternativo) con unidad systemd propia (no depende del servicio del paquete).
# Admite varios puertos: el primero es el "principal" (destino de SSL, SlowDNS y los proxies).
# shellcheck shell=bash

DB_UNIT="${APP_SLUG}-dropbear"

# Todos los puertos configurados, separados por espacio.
dropbear_ports() {
    printf '%s %s' "$(conf_get DROPBEAR_PORT)" "$(conf_get DROPBEAR_EXTRA)" | xargs
}

install_dropbear() {
    local ports p bin args="" main extra
    read -rp "Puertos de Dropbear separados por espacio [444]: " ports
    ports="${ports:-444}"
    for p in $ports; do
        valid_port "$p" || { err "Puerto inválido: $p"; return 1; }
        port_in_use "$p" && { err "El puerto $p ya está en uso."; return 1; }
    done

    info "Instalando dropbear..."
    pkg_install dropbear-bin || pkg_install dropbear || { err "Falló la instalación de dropbear."; return 1; }
    # Si el paquete trajo su propio servicio se desactiva: usamos el nuestro.
    systemctl disable --now dropbear >/dev/null 2>&1 || true
    bin="$(command -v dropbear)" || { err "No se encontró el binario de dropbear."; return 1; }

    ensure_false_shell
    mkdir -p /etc/dropbear
    [[ -e "${BANNER_FILE:-/etc/${APP_SLUG}-banner.txt}" ]] || install -m 644 /dev/null "${BANNER_FILE:-/etc/${APP_SLUG}-banner.txt}"
    for p in $ports; do args+=" -p $p"; done
    main="${ports%% *}"; extra="${ports#"$main"}"; extra="${extra# }"

    # -R crea las claves de host si faltan, -E registra en el journal, -F foreground, -w sin login de root
    cat > "/etc/systemd/system/${DB_UNIT}.service" <<EOF
[Unit]
Description=${APP_NAME} Dropbear
After=network.target

[Service]
ExecStart=${bin} -R -E -F -b ${BANNER_FILE:-/etc/${APP_SLUG}-banner.txt} -w${args}
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    svc_enable_restart "$DB_UNIT"
    conf_set DROPBEAR_PORT "$main"; conf_set DROPBEAR_EXTRA "$extra"
    if svc_is_active "$DB_UNIT"; then
        ok "Dropbear activo en los puertos: $ports"
    else
        warn "No arrancó. Revisá: journalctl -u ${DB_UNIT} -n 30"
    fi
}

remove_dropbear() {
    systemctl disable --now "$DB_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${DB_UNIT}.service"; systemctl daemon-reload
    DEBIAN_FRONTEND=noninteractive apt-get remove -y dropbear-bin dropbear >/dev/null 2>&1 || true
    conf_set DROPBEAR_PORT ""; conf_set DROPBEAR_EXTRA ""
    ok "Dropbear eliminado."
}

# Reescribe los -p de la unidad con la lista dada (el primero es el principal) y reinicia.
# KillMode=process: las sesiones abiertas sobreviven al reinicio.
dropbear_set_ports() { # "p1 p2 ..."
    local f="/etc/systemd/system/${DB_UNIT}.service" p main extra list="$*" args=""
    [[ -f "$f" ]] || { err "Dropbear no está instalado."; return 1; }
    for p in $list; do args+=" -p $p"; done
    sed -i -E "/^ExecStart=/{s/ -p [0-9]+//g; s|\$|${args}|}" "$f"
    grep -q '^KillMode=' "$f" || sed -i '/^\[Service\]/a KillMode=process' "$f"
    systemctl daemon-reload; systemctl restart "$DB_UNIT" 2>/dev/null; sleep 1
    if ! svc_is_active "$DB_UNIT"; then warn "No arrancó. Revisá: journalctl -u ${DB_UNIT} -n 30"; return 1; fi
    main="${list%% *}"; extra="${list#"$main"}"; extra="${extra# }"
    conf_set DROPBEAR_PORT "$main"; conf_set DROPBEAR_EXTRA "$extra"
}

dropbear_add_ports() {
    local cur new p added=""
    cur="$(dropbear_ports)"; echo "Puertos actuales: $cur"
    read -rp "Puertos nuevos separados por espacio (ej: 443 8443): " new
    [[ -n "$new" ]] || return 0
    for p in $new; do
        valid_port "$p" || { err "Puerto inválido: $p"; return 1; }
        [[ " $cur " == *" $p "* ]] && { err "El $p ya es de Dropbear."; return 1; }
        port_in_use "$p" && { err "El puerto $p ya está en uso."; return 1; }
        added+=" $p"
    done
    dropbear_set_ports "$cur$added" || return 1
    for p in $added; do ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$p/tcp" >/dev/null 2>&1; done
    ok "Puertos de Dropbear: $(dropbear_ports)"
    warn "Si estás en la nube, abrí también $added en el firewall del proveedor (NSG de Azure)."
}

dropbear_del_port() {
    local cur main p keep=""
    cur="$(dropbear_ports)"; main="${cur%% *}"; echo "Puertos actuales: $cur   (el principal $main no se puede quitar)"
    read -rp "Puerto a quitar: " p
    [[ " $cur " == *" $p "* ]] || { err "Ese puerto no es de Dropbear."; return 1; }
    [[ "$p" == "$main" ]] && { err "Es el principal (lo usan SSL, SlowDNS y los proxies). Para cambiarlo, reinstalá."; return 1; }
    for x in $cur; do [[ "$x" == "$p" ]] || keep+="$x "; done
    dropbear_set_ports "${keep% }" && ok "Puerto $p quitado. Quedan: $(dropbear_ports)"
}

dropbear_menu() {
    local op
    if [[ "$(state_of 6)" != on ]]; then install_dropbear; pause; return; fi
    while true; do
        title "DROPBEAR"
        echo " Estado: ${G}ACTIVO${N}  Puertos: $(dropbear_ports)"; bar
        echo " 1) Ver datos"
        echo " 2) Agregar puertos (sin borrar los actuales)"
        echo " 3) Quitar un puerto"
        echo " 4) Reinstalar / cambiar puerto principal"
        echo " 5) Quitar Dropbear"
        echo " 0) Volver"
        bar; read -rp " Opción: " op
        case "$op" in
            1) dropbear_info; pause ;;
            2) dropbear_add_ports; pause ;;
            3) dropbear_del_port; pause ;;
            4) systemctl stop "$DB_UNIT" 2>/dev/null; install_dropbear || systemctl start "$DB_UNIT" 2>/dev/null; pause ;;
            5) confirm "¿Quitar Dropbear?" && remove_dropbear; pause; return ;;
            0) return ;;
        esac
    done
}
