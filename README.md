# MvS

Panel en bash para gestionar usuarios SSH y túneles en un VPS Debian/Ubuntu.
Base limpia: sin keys, sin tokens ajenos, sin descargas de terceros.

## Instalar (un solo archivo)

    bash mvs-install.sh      # generado con tools/build-single.sh; trae todo el panel adentro

Sistemas: Ubuntu 18.04–26.04 (x64 y ARM64) y Debian 8–12 (x64). Verifica el sistema, repara los
repositorios de Debian viejo (archive.debian.org) y adapta las unidades de systemd a la versión instalada.
Limitaciones conocidas en Debian 8: sin gestor de Xray (jq 1.4) y servicios con puertos < 1024 como root.

## SOCKS5 + UDP [19] (HevSocks5Server)

Servidor SOCKS5 de código abierto (heiher/hev-socks5-server, MIT) que acompaña al "motor SOCKS" HevSocks5Tunnel de las apps.
Soporta CONNECT, UDP ASSOCIATE y UDP-en-TCP, con varios usuarios y clave. Se compila en el VPS desde el tag fijado y se
verifica el commit. Corre sin privilegios y con la unidad endurecida. Modo **local** (127.0.0.1, para usarlo detrás de
SSL/TLS, SSH o PYTHON con "Destino" = su puerto, recomendado) o **público** (la clave SOCKS5 viaja sin cifrar).
El servidor sin la sección `auth` es un proxy abierto: el panel siempre la escribe y, al instalar, comprueba que rechace
conexiones sin credenciales (si no las rechaza, se desinstala solo). Requiere IPv6 habilitado en el kernel.

## WSTUNNEL [20]

Túnel TCP/UDP sobre WebSocket/HTTP2 (erebe/wstunnel, BSD-3). Se baja el binario oficial de la release fijada (v11.1.0) y se
verifica su SHA-256 contra `checksums.txt` de la release. El servidor se instala siempre con `--restrict-to` (solo reenvía
a UN puerto local elegido: nadie puede usarlo como proxy abierto ni abrir túneles inversos) y con un prefijo de ruta secreto
que hace de contraseña. El prefijo va en un archivo de entorno (no aparece en `ps` ni en la unidad) y el certificado TLS es
propio, no el embebido en el binario. Al instalar se comprueba con el propio cliente que un prefijo incorrecto sea rechazado;
si no, se desinstala solo. Modos: `wss` (TLS) o `ws` (detrás de un CDN o de otro túnel).

**Frente 101 (solo modo `ws`, opcional):** wstunnel contesta `400` a cualquier petición que no sea de su propio cliente.
Con el frente activo (`lib/py/wstfront.py`, unidad `mvs-wstunnel-front`) el puerto público contesta
`101 Switching Protocols` (o `200 Connection established` a un CONNECT) a los payloads de HTTP Custom / HTTP Injector y los
conecta directo con el destino fijo (SSH/Dropbear); el cliente wstunnel real pasa al wstunnel interno (127.0.0.1) con su
prefijo secreto. La vía de payload no usa el prefijo: la protege el usuario/clave SSH.
Un payload con varias peticiones HTTP seguidas (bloques `[split]`, por ejemplo `MKCOL … [split] GET … Upgrade: websocket`) recibe un 101 por cada una; al llegar SSH o el handshake de wstunnel se decide el destino. También sirve para perfiles de la app en modo SSH + payload apuntando a ese puerto.

## OPTIMIZAR [Q]

Tres ajustes que se activan y desactivan de a uno (el menú muestra `[ON]`/`[OFF]`). Lo que se instala con apt se instala
sin arrancar solo, la configuración se valida antes de arrancar y si algo falla se deshace. Al desactivar solo se quita
lo que instaló el panel. Si venís de la v1.15, al abrir este menú se quitan solos los ajustes que ya no existen (SSH keepalive,
monitoreo e Unbound) y se devuelve el DNS del servidor a como estaba.

1. **Ping WebSocket cada 25 s**: `--websocket-ping-frequency` en WSTUNNEL, `--ping` en WS-PRO (no cuenta como actividad para el tiempo de inactividad) y `--heartbeat` en Websockify. Se reaplica solo cuando reinstalás esos servicios.
2. **Nginx sin buffering**: proxy WebSocket (`proxy_buffering off`, `proxy_request_buffering off`, timeouts de 1 h) en un puerto público hacia WS-PRO, WSTUNNEL, Websockify u otro puerto local. Sirve para clientes con `Upgrade`; un payload sin Upgrade no atraviesa Nginx.
3. **Websockify**: WebSocket (RFC 6455) a TCP hacia un único puerto local, con usuario propio y servicio endurecido.

## WS-PRO y el 101

El puerto de WS-PRO acepta WebSocket real (con `Sec-WebSocket-Key`, framing y ping). Cualquier otra petición, como el payload de
HTTP Custom / HTTP Injector, recibe igual `101 Switching Protocols` (o `200 Connection established` a un CONNECT) y sigue como flujo
crudo hacia el destino fijo. Un payload con varias peticiones (`[split]`) recibe una respuesta por cada una.

Desde la v1.18 el menú de WS-PRO [11] permite agregar puertos sin borrar los actuales, quitarlos y **cambiar la respuesta de cada
puerto** (101 Switching Protocols o 200 Connection established) para los clientes con payload. Un cliente WebSocket real recibe siempre el 101
de WebSocket.

## Key de instalación (6 horas)

Para instalar en una VPS nueva el instalador pide una key y solo la acepta durante **6 horas** desde que se generó. Se genera con
`[R] KEY INSTALACION`, que **solo aparece en tu VPS de administración**, la que tiene la clave privada en `/root/.mvs-signing/private.pem`
(permisos 600; no la subas nunca al repo). La pantalla muestra la key, cuándo vence y el comando listo para pegar:

    wget -qO mvs.sh <URL del instalador> && MVS_KEY=<la key> bash mvs.sh

También se puede ejecutar `bash mvs.sh` y pegar la key cuando la pida. Actualizar con `[Z]` o reinstalar donde ya está instalado no pide key.
Se valida sin servidor, con una firma ECDSA (clave pública en `config/install-pub.pem`) y la hora de la VPS nueva.
**Es un freno, no una barrera:** el instalador es texto y quien lo edite puede quitar la validación. Para obligarla de verdad hace falta
que el instalador se entregue desde un servidor que compruebe la key.

### Key de un solo uso (compuerta en Cloudflare)

Para que una key sirva **una sola vez** hace falta que algo recuerde cuáles ya se usaron, y una VPS nueva no recuerda nada. Eso lo hace un
Worker de Cloudflare (plan gratis) con el código de `tools/keygate-worker.js`: el instalador le pregunta antes de instalar, el Worker
comprueba la firma, la hora y si la key ya se usó, y avisa a tu Telegram (uso, intento de reutilizarla, intento con key vencida).
Si el Worker no responde, **no se instala** (si no, bastaría con cortar internet para saltarse el control).

1. Cloudflare → Workers & Pages → Create → Worker → pegá el código de `tools/keygate-worker.js` → Deploy.
2. Storage & Databases → KV → crear un namespace → en el Worker, Settings → Bindings → KV namespace con el nombre `KEYS`.
3. Settings → Variables and Secrets (tipo secret): `ADMIN_TOKEN` (una clave larga que inventes), `TG_TOKEN` y `TG_CHAT` (bot que te avisa y tu id).
4. Poné la dirección del Worker (`https://....workers.dev`) en `config/install-gate`, publicá, y en `~/.mvs-keybot.conf` agregá
   `GATE_URL=` (la misma dirección) y `GATE_ADMIN=` (el ADMIN_TOKEN). El bot responde a `/keys` con el estado de las keys recientes.

Con `config/install-gate` vacío el instalador funciona como antes (6 horas, sin control de reutilización). Una key reclamada se recuerda 8 horas.
El almacén KV es eventualmente consistente: dos usos en el mismo segundo desde distintos lugares podrían pasar los dos; copiar una key y usarla después se bloquea.

### Aviso cuando se usa una key

Si al generar la key hay un bot avisador configurado (`REPORT_TOKEN=` en `~/.mvs-keybot.conf`, o el archivo `/root/.mvs-signing/report`
con `TOKEN ID_DE_TU_CHAT`), la key lleva ese destino adentro (firmado) y el instalador manda un mensaje a tu Telegram cuando se usa:
key, IP pública y sistema de la VPS, y también si alguien intenta con una key vencida. Conviene que sea un **segundo bot**, distinto del que
genera las keys, porque su token queda a la vista de quien reciba una key. No se guarda en el repo. Abrí ese bot y tocá Start una vez
para que pueda escribirte. Es un aviso, no un bloqueo: una key puede usarse varias veces dentro de sus 6 horas y cada uso te avisa.

### Bot de Telegram para generar keys

`lib/py/keybot.py` es un bot que responde solo a tu id de Telegram y, al escribirle `/key`, te devuelve una key nueva y el comando de
instalación. Corre donde tengas `python3` y `openssl` (Termux en el celular, otra VPS, una PC) con `~/.mvs-keybot.conf`
(`TOKEN=`, `CHAT=`, `PRIV=` ruta de private.pem). Si la VPS tiene la clave privada, el bot del panel [L] también responde a `/key`.

#### Bot de keys dentro del Worker (sin Termux ni otra máquina)

El mismo Worker puede hacer de bot (`/key` y `/keys`) por webhook, 24 horas y gratis. Secretos extra en Cloudflare:
`BOT_TOKEN` (bot que genera keys) y `SIGN_KEY` (la clave privada en PKCS8: `openssl pkcs8 -topk8 -nocrypt -in ~/private.pem | grep -v -- ----- | tr -d '\n'`).
Opcionales: `BOT_CHAT` (si falta usa `TG_CHAT`), `INSTALL_URL`, `WEBHOOK_SECRET`. Se activa una vez abriendo
`https://api.telegram.org/bot<BOT_TOKEN>/setWebhook?url=https://<tu-worker>.workers.dev/tg` (con `&secret_token=...` si usás `WEBHOOK_SECRET`).
Solo responde a tu id; el estado de las keys sale del mismo KV (`issued:` / `used:`).

## MULTIPLEXOR [21] (un puerto para todo, tipo sslh)

Deja un solo puerto público, normalmente el 443, y reparte cada conexión según lo que llega: TLS con SNI va a SSL/TLS [5],
`SSH-` va a SSH/Dropbear y un payload HTTP (WebSocket, 101, CONNECT) va a WS-PRO o SOCKS PYTHON. Un cliente que no manda nada en
2 s se trata como SSH, porque espera el banner del servidor. Si el 443 lo usa SSL/TLS [5], el asistente lo mueve solo a un puerto
interno (solo local) y el público sigue siendo el 443; al quitar el multiplexor lo devuelve. Los destinos son siempre 127.0.0.1.

## Pantalla principal

Arriba se ve el uso de CPU, RAM y disco del VPS (con lo que queda libre). Los protocolos van numerados (1 a 20) y las herramientas
con letras en orden (A a Q), más `[Z]` actualizar y `[X]` desinstalar.

Desde la v1.17 la pantalla va en cajas redondeadas de colores: cabecera con la versión, barras de CPU/RAM/disco
(se ponen rojas al llegar al 90 %), dos cajas moradas con los puertos activos, banners azul (PROTOCOLOS) y rojo
(HERRAMIENTAS), listas con `[ON]` / `[OFF]` / `[N/D]` y el cursor dentro de una caja al pie. Necesita una terminal
de 57 columnas o más con 256 colores (JuiceSSH, Termux, etc.); si es más angosta o no es una terminal real,
muestra automáticamente el diseño clásico.

## Usuarios SSH [P]

Arriba del menú se ve el resumen (usuarios y conexiones). `5) Listar usuarios` muestra por cada cuenta la fecha de
vencimiento, los días que le quedan (amarillo a 3 días o menos, rojo si está vencida), el cupo (para cuántas conexiones a la vez
se creó) y cuántas conexiones tiene abiertas ahora. `6) Quién está conectado` muestra solo los que están en línea.

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

`menu` abre directamente la pantalla de dos columnas (ON/OFF por servicio); `[P]` administra usuarios SSH y `[O]` configura Telegram. Cada número instala el
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
