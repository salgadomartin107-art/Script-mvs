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

# ---------------------------------------------------------------------------
# Diseño en cajas redondeadas (panel principal, v1.17).
# Todo se coloca con posiciones absolutas de columna (\e[nG): así los bordes
# quedan derechos aunque la fuente mida distinto los símbolos. Ancho total: 57.
# ---------------------------------------------------------------------------
_rep() { local s="" i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }
RULE26="$(_rep ─ 26)"; RULE55="$(_rep ─ 55)"
K_BLUE=$'\e[38;5;39m';  K_PURP=$'\e[38;5;135m'
K_YEL=$'\e[1;38;5;226m'; K_GRN=$'\e[1;38;5;46m'; K_CYA=$'\e[1;38;5;51m'; K_MAG=$'\e[1;38;5;201m'
K_RED=$'\e[1;38;5;196m'; K_DIM=$'\e[38;5;240m'
BG_BLU=$'\e[1;97;48;5;27m'; BG_RD=$'\e[1;97;48;5;160m'

box_edge1() { printf '\e[1G%s%s%s%s%s\n' "$1" "$2" "$RULE55" "$3" "$N"; }            # color ╭ ╮
box_edge2() { printf '\e[1G%s%s%s%s\e[30G%s%s%s%s%s\n' "$3" "$1" "$RULE26" "$2" "$4" "$1" "$RULE26" "$2" "$N"; } # ╭ ╮ colorIzq colorDer
box_row1()  { printf '\e[1G%s│%s%s\e[57G%s│%s\n' "$1" "$N" "$2" "$1" "$N"; }          # color contenido
box_row2()  { printf '\e[1G%s│%s%s\e[28G%s│\e[30G%s│%s%s\e[57G%s│%s\n' "$1" "$N" "$3" "$1" "$2" "$N" "$4" "$2" "$N"; } # cI cD contIzq contDer

banner2() { # texto_izq texto_der
    local a="$1" b="$2" la lb
    la=$(( (28 - ${#a}) / 2 )); lb=$(( (28 - ${#b}) / 2 ))
    printf '\e[1G%s%*s%-*s%s\e[30G%s%*s%-*s%s\n' "$BG_BLU" "$la" "" $((28 - la)) "$a" "$N" "$BG_RD" "$lb" "" $((28 - lb)) "$b" "$N"
}

item_cell() { # desplazamiento clave etiqueta estado
    local o="$1" key="$2" label="$3" st="${4:-}" tag="" tc="" kc="$K_CYA" w=18
    [[ "$key" == [ZX] ]] && kc="$K_RED"
    case "$st" in
        on)  tag="[ON]";  tc="$K_GRN" ;;
        off) tag="[OFF]"; tc="$K_RED" ;;
        na)  tag="[N/D]"; tc="$K_CYA" ;;
    esac
    [[ -n "$tag" ]] && w=12
    printf '\e[%dG%s[%s]\e[%dG%s►%s\e[%dG%s%.*s%s' \
        $((o + 5 - ${#key})) "$kc" "$key" $((o + 7)) "$K_RED" "$N" $((o + 9)) "$WH" "$w" "$label" "$N"
    [[ -n "$tag" ]] && printf '\e[%dG%s%s%s' $((o + 27 - ${#tag})) "$tc" "$tag" "$N"
    return 0
}

item_from() { # desplazamiento "clave|etiqueta|estado"
    local k l s
    [[ -n "${2:-}" ]] || return 0
    IFS='|' read -r k l s <<<"$2"
    item_cell "$1" "$k" "$l" "$s"
}

port_cell() { # desplazamiento índice etiqueta puertos
    local -a cols=("$K_YEL" "$K_GRN" "$K_CYA" "$K_MAG")
    printf '\e[%dG%s%-9s%s\e[%dG%s%.14s%s' $(( $1 + 3 )) "${cols[$(( $2 % 4 ))]}" "$3:" "$N" $(( $1 + 13 )) "$WH" "$4" "$N"
}
