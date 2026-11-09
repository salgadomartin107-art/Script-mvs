#!/usr/bin/env bash
# Test de velocidad con speedtest-cli (paquete apt). shellcheck shell=bash

run_speedtest() {
    command -v speedtest-cli >/dev/null 2>&1 || {
        info "Instalando speedtest-cli..."
        pkg_install speedtest-cli || { err "No se pudo instalar speedtest-cli."; return 1; }
    }
    info "Midiendo (puede tardar ~30 s)..."
    speedtest-cli --simple || err "El test falló (¿sin salida a internet?)."
}
