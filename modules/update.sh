#!/usr/bin/env bash
# Actualización del script desde tu repositorio de GitHub. Conserva usuarios, claves y ajustes (/etc/mvs).
# shellcheck shell=bash

update_version_of() { # instalador -> APP_VERSION que trae adentro
    sed '1,/^__MVS_PAYLOAD__$/d' "$1" 2>/dev/null | base64 -d 2>/dev/null \
        | tar -xzO "mvs/config/app.conf" 2>/dev/null | sed -n 's/^APP_VERSION="\([^"]*\)".*/\1/p' | head -1
}

update_script() {
    local tmp new_ver sum bak
    title "Actualizar ${APP_NAME}"
    command -v curl >/dev/null 2>&1 || { err "Falta curl (apt install curl)."; return 1; }
    echo "Origen: ${APP_UPDATE_URL}"
    echo "Versión instalada: ${APP_VERSION}"
    tmp="$(mktemp -d /var/tmp/mvs-update.XXXXXX)"; chmod 700 "$tmp"
    info "Descargando..."
    if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 300 --max-filesize $((64*1024*1024)) \
            -o "$tmp/mvs-install.sh" "$APP_UPDATE_URL"; then
        err "No se pudo descargar la actualización (revisá la conexión)."; rm -rf "$tmp"; return 1
    fi
    if [[ "$(head -c 2 "$tmp/mvs-install.sh")" != '#!' ]] || ! grep -q '^__MVS_PAYLOAD__$' "$tmp/mvs-install.sh"; then
        err "El archivo descargado no es un instalador de ${APP_NAME}."; rm -rf "$tmp"; return 1
    fi
    new_ver="$(update_version_of "$tmp/mvs-install.sh")"
    if [[ -z "$new_ver" ]]; then
        err "El instalador descargado está incompleto o dañado."; rm -rf "$tmp"; return 1
    fi
    sum="$(sha256sum "$tmp/mvs-install.sh" | awk '{print $1}')"
    echo "Versión disponible: ${new_ver}"
    echo "SHA-256: ${sum}"
    [[ "$new_ver" == "$APP_VERSION" ]] && info "Es la misma versión; se reinstalan los archivos del panel igualmente."
    echo "Se conservan: usuarios, claves, puertos y servicios. Se reemplaza solo el panel en /opt/${APP_SLUG}."
    confirm "¿Actualizar ahora?" || { rm -rf "$tmp"; info "Cancelado."; return 0; }

    bak="/root/${APP_SLUG}-backups"; mkdir -p "$bak"; chmod 700 "$bak"
    tar -czf "$bak/antes-de-actualizar-$(date +%Y%m%d-%H%M%S).tgz" -C / "etc/${APP_SLUG}" 2>/dev/null \
        && ok "Copia de seguridad de tu configuración en $bak"
    if ! bash "$tmp/mvs-install.sh"; then
        err "La actualización falló. Tu configuración está intacta; el panel anterior puede haber quedado a medias: volvé a ejecutar la actualización."
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    ok "Panel actualizado a la versión ${new_ver}."
    if confirm "¿Reiniciar ahora los servicios del panel para que usen el código nuevo?"; then
        local u
        for u in /etc/systemd/system/${APP_SLUG}-*.service; do
            [[ -e "$u" ]] || continue
            u="$(basename "$u" .service)"
            svc_is_active "$u" && systemctl restart "$u" >/dev/null 2>&1 || true
        done
        ok "Servicios reiniciados."
    fi
    info "Abriendo el panel actualizado..."
    exec "/usr/local/bin/menu"
}
