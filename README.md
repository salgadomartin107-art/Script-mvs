# MvS

Panel en bash para gestionar usuarios SSH y túneles en un VPS Debian/Ubuntu.
Base limpia: sin keys, sin tokens ajenos, sin descargas de terceros.

## Instalar (un solo archivo)

    bash mvs-install.sh      # generado con tools/build-single.sh; trae todo el panel adentro

Sistemas: Ubuntu 18.04–24.04 (x64 y ARM64) y Debian 8–12 (x64). Verifica el sistema, repara los
repositorios de Debian viejo (archive.debian.org) y adapta las unidades de systemd a la versión instalada.
Limitaciones conocidas en Debian 8: sin gestor de Xray (jq 1.4) y servicios con puertos < 1024 como root.

## Desinstalar (deja el VPS limpio)

    menu  →  [X] DESINSTALAR          o bien:   bash mvs-install.sh --uninstall   /   menu --uninstall

Pide escribir DESINSTALAR. Quita servicios, binarios, configuración, claves, tareas programadas, banner SSH,
inicio automático, reglas de iptables propias y el comando `menu`; opcionalmente los usuarios SSH creados,
los paquetes de apt y los backups. Al final verifica que no quede nada.

## Instalar desde el repo

    git clone <tu-repo> && cd mvs
    sudo ./install.sh
    menu

## Estructura

    config/app.conf     nombre del script (APP_NAME, APP_SLUG)
    lib/common.sh       utilidades
    lib/users.sh        crear/borrar/renovar/limitar usuarios
    lib/notify.sh       Telegram con tu propio bot
    lib/ui.sh           pantalla de dos columnas
    lib/py/*.py         proxy WS/HTTP, CHECK-USER, servidor de archivos (Python, solo stdlib)
    modules/*.sh        dropbear, stunnel (SSL), squid (proxy restringido), badvpn (UDPGW),
                        openvpn (login con usuarios SSH vía PAM), xray (varias configuraciones: VLESS/VMess/WS/TLS/gRPC/mKCP/Shadowsocks/REALITY),
                        shadowsocks (shadowsocks-libev), slowdns (dnstt)
    bin/menu            panel interactivo
    bin/limiter         cron: límite de conexiones y vencimientos

## Cambiar el nombre

Editá `config/app.conf` antes de instalar.

## Origen del software

- OpenVPN, easy-rsa, shadowsocks-libev, stunnel, squid, dropbear, badvpn: paquetes apt.
- Xray: release oficial de GitHub (XTLS/Xray-core) con verificación SHA-256.
- SlowDNS: dnstt compilado desde https://www.bamsoftware.com/git/dnstt.git.

## Herramientas

- Backup: usuarios (con sus hashes), configuración y PKI en `/root/<slug>-backups/` (se conservan los últimos 10).
- Fail2ban para OpenSSH y Dropbear.
- Test de velocidad (speedtest-cli).

## Pantalla de protocolos

`menu` abre directamente la pantalla de dos columnas (ON/OFF por servicio); `[35]` administra usuarios SSH y `[34]` configura Telegram. Cada número instala el
servicio si está apagado, o abre ver datos / reinstalar / quitar si está activo.

Incluye también: PYTHON-WS (HTTP 101 a SSH), WS-PRO (WebSocket real), WireGuard, Hysteria2,
Trojan (vía Xray), monitor con reinicio automático, bot y NOTI-BOT de Telegram, CHECK-USER,
ARCHIVO ONLINE, firewall (ufw), BBR, DNS, escáner de subdominios y fixes para VPS en la nube.

UDP-CUSTOM [18] usa el binario oficial del ePro Dev Team (descarga fijada por SHA-256, corre como root limitado por systemd; ver el aviso al instalar). No incluidos a propósito: ZIVPN, UDPs Request (binarios cerrados) y Psiphon.

## V2RAY/XRAY (opción 4)

Gestor de varias configuraciones a la vez, en español: agregar, ver enlaces, cambiar puerto/UUID/ruta/dominio,
eliminar, usuarios, QR, estado y actualizar el núcleo (descarga oficial verificada con SHA-256).
Cada cambio se valida con `xray run -test` y se revierte solo si falla. Los certificados TLS son autofirmados
(usalos detrás de Cloudflare en modo Full). No incluye QUIC/H2 ni TLS automático con Let's Encrypt.

## Importante en la nube

El firewall del proveedor (NSG de Azure, Security Group de AWS, Security List de Oracle) es
independiente: hay que abrir allí los puertos que elijas. Ver menú > 28 > opción 4.
