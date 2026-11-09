#!/usr/bin/env bash
# shellcheck disable=SC2034
# Piezas de la pantalla de dos columnas. shellcheck shell=bash

LINE_W=57
WH=$'\e[1;37m'
BGY=$'\e[1;30;43m'   # texto negro sobre amarillo
BGG=$'\e[1;30;47m'   # texto negro sobre gris
BGR=$'\e[1;37;41m'   # texto blanco sobre rojo

hline() { printf '%s' "$R"; printf '%.0s'"$1" $(seq 1 "$LINE_W"); printf '%s\n' "$N"; }

# Celda de ancho fijo (27 columnas): [clave]→ ETIQUETA  [ON]
cell() { # clave etiqueta estado(on|off|na|vacío)
    local key="$1" label="$2" st="${3:-}" tag="" col="$N" lw kc="$G"
    [[ "$key" == [ZX] ]] && kc="$R"
    lw=$(( 27 - ${#key} - 4 ))
    case "$st" in
        on)  tag="[ON]";  col="$G" ;;
        off) tag="[OFF]"; col="$R" ;;
        na)  tag="[N/D]"; col="$Y" ;;
    esac
    [[ -n "$tag" ]] && lw=$(( lw - 6 ))
    printf '%s[%s%s%s]%s→%s %s%-*.*s%s' "$Y" "$kc" "$key" "$Y" "$R" "$N" "$WH" "$lw" "$lw" "$label" "$N"
    [[ -n "$tag" ]] && printf ' %s%-5s%s' "$col" "$tag" "$N"
    return 0
}

cell_from() { # "clave|etiqueta|estado"
    local k l s
    [[ -n "${1:-}" ]] || { printf '%27s' ''; return; }
    IFS='|' read -r k l s <<<"$1"
    cell "$k" "$l" "$s"
}

print_rows() { # nombre_array_izq nombre_array_der
    local -n _a="$1" _b="$2"
    local n=${#_a[@]} i
    (( ${#_b[@]} > n )) && n=${#_b[@]}
    for ((i = 0; i < n; i++)); do
        printf '%s   %s\n' "$(cell_from "${_a[$i]:-}")" "$(cell_from "${_b[$i]:-}")"
    done
}

kv() { printf '%s%-9s%s %s%-15s%s' "$R" "$1:" "$N" "$G" "${2:--}" "$N"; }
