#!/usr/bin/env bash
# Backups de usuarios y configuración. El archivo contiene hashes de claves, el token de
# Telegram y la PKI de OpenVPN: se guarda con permisos 600 en un directorio 700.
# shellcheck shell=bash

BACKUP_DIR="/root/${APP_SLUG}-backups"
BACKUP_KEEP=10

backup_create() {
    local ts f tmp u
    ts="$(date +%Y%m%d-%H%M%S)"; f="${BACKUP_DIR}/${APP_SLUG}-${ts}.tar.gz"
    install -d -m 700 "$BACKUP_DIR"
    tmp="$(mktemp -d)"
    cp -a "$DATA_DIR" "$tmp/data"
    : > "$tmp/shadow.txt"
    while IFS='|' read -r u _; do
        [[ -n "$u" ]] && getent shadow "$u" | awk -F: '{print $1 ":" $2}' >> "$tmp/shadow.txt"
    done < "$USERS_DB"
    tar -czf "$f" -C "$tmp" . && chmod 600 "$f"
    rm -rf "$tmp"
    # Rotación: conserva los últimos $BACKUP_KEEP
    find "$BACKUP_DIR" -maxdepth 1 -name "${APP_SLUG}-*.tar.gz" -printf '%T@ %p\n' \
        | sort -rn | tail -n +"$((BACKUP_KEEP + 1))" | cut -d' ' -f2- | xargs -r rm -f --
    ok "Backup creado: $f"
}

backup_list() {
    [[ -d "$BACKUP_DIR" ]] || { info "Todavía no hay backups."; return 1; }
    mapfile -t BACKUP_FILES < <(find "$BACKUP_DIR" -maxdepth 1 -name "${APP_SLUG}-*.tar.gz" | sort -r)
    (( ${#BACKUP_FILES[@]} )) || { info "Todavía no hay backups."; return 1; }
    local i
    for i in "${!BACKUP_FILES[@]}"; do
        printf '%2d) %s (%s)\n' "$((i + 1))" "$(basename "${BACKUP_FILES[$i]}")" "$(du -h "${BACKUP_FILES[$i]}" | cut -f1)"
    done
}

backup_restore() {
    local n f tmp u e c hash bad
    backup_list || return 1
    read -rp "Número de backup a restaurar: " n
    [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le ${#BACKUP_FILES[@]} ]] || { err "Número inválido."; return 1; }
    f="${BACKUP_FILES[$((n - 1))]}"

    # Rechaza archivos con rutas absolutas o '..'
    bad="$(tar -tzf "$f" | grep -E '(^/|(^|/)\.\.(/|$))' || true)"
    [[ -z "$bad" ]] || { err "El archivo contiene rutas peligrosas. Cancelado."; return 1; }

    read -rp "Esto sobrescribe usuarios y configuración actuales. ¿Continuar? (s/N): " c
    [[ "$c" == [sS] ]] || { info "Cancelado."; return 0; }

    tmp="$(mktemp -d)"
    tar -xzf "$f" -C "$tmp" --no-same-owner
    [[ -f "$tmp/data/users.db" ]] || { err "Backup inválido (falta users.db)."; rm -rf "$tmp"; return 1; }

    cp -a "$tmp/data/." "$DATA_DIR/"
    chmod 700 "$DATA_DIR"; chmod 600 "$USERS_DB" "$CONF" 2>/dev/null || true

    while IFS='|' read -r u e _; do
        user_valid "$u" || { warn "Se omite usuario inválido: $u"; continue; }
        [[ "$e" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { warn "Fecha inválida para $u, se omite."; continue; }
        if ! user_exists "$u"; then
            user_add_system "$u" "$e"
        fi
        hash="$(awk -F: -v u="$u" '$1 == u {print $2}' "$tmp/shadow.txt")"
        # chpasswd -e recibe el hash por stdin (no queda en la lista de procesos)
        [[ -n "$hash" && "$hash" != "!"* && "$hash" != "*" ]] && printf '%s:%s\n' "$u" "$hash" | chpasswd -e
        chage -E "$e" "$u" 2>/dev/null || true
    done < "$USERS_DB"
    rm -rf "$tmp"
    ok "Usuarios y configuración restaurados."
    warn "Los servicios (OpenVPN, Xray, etc.) no se reinstalan solos: instalalos desde el menú."
}
