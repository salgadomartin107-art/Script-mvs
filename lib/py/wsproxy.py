#!/usr/bin/env python3
"""Puente hacia UN único destino TCP local (no es un proxy abierto).

Modos:
  raw : cualquier petición HTTP recibe "101 <estado>" y después se reenvía el flujo crudo
        (estilo HTTP Injector / HTTP Custom). Si el cliente empieza directo con "SSH-",
        se reenvía tal cual.
  connect : responde "200 Connection established" (estilo proxy HTTP CONNECT) y reenvía el flujo crudo
            al mismo destino fijo, sin importar el host que pida el cliente.
  ws  : WebSocket real (RFC 6455, con framing y enmascarado). Sirve detrás de un CDN.
"""
import argparse
import base64
import hashlib
import re
import select
import socket
import struct
import threading

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_HEAD = 16384
MAX_FRAME = 1 << 20
SLOTS = threading.BoundedSemaphore(500)


STATUS_RE = re.compile(r"[A-Za-z0-9 ._-]{1,40}")


def current_status(a):
    """Lee el texto de estado del archivo en cada conexión: se cambia sin reiniciar el servicio."""
    if a.status_file:
        try:
            with open(a.status_file, encoding="ascii") as f:
                t = f.read().strip()
            if STATUS_RE.fullmatch(t):
                return t
        except (OSError, UnicodeDecodeError):
            pass
    return a.status


def parse_head(raw):
    lines = raw.decode("latin-1").split("\r\n")
    hdr = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            hdr[k.strip().lower()] = v.strip()
    return hdr


def unmask(payload, mask):
    n = len(payload)
    if not n:
        return b""
    key = (mask * (n // 4 + 1))[:n]
    return (int.from_bytes(payload, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big")


def ws_frame(op, payload=b""):
    n = len(payload)
    if n < 126:
        head = struct.pack("!BB", 0x80 | op, n)
    elif n < 65536:
        head = struct.pack("!BBH", 0x80 | op, 126, n)
    else:
        head = struct.pack("!BBQ", 0x80 | op, 127, n)
    return head + payload


def pipe_raw(c, t, idle):
    pair = (c, t)
    while True:
        ready, _, _ = select.select(pair, [], [], idle)
        if not ready:
            return
        for s in ready:
            data = s.recv(65536)
            if not data:
                return
            (t if s is c else c).sendall(data)


def pipe_ws(c, t, idle, buf):
    pair = (c, t)
    while True:
        while len(buf) >= 2:
            op = buf[0] & 0x0F
            masked = buf[1] & 0x80
            ln = buf[1] & 0x7F
            off = 2
            if ln == 126:
                if len(buf) < 4:
                    break
                ln, off = struct.unpack("!H", buf[2:4])[0], 4
            elif ln == 127:
                if len(buf) < 10:
                    break
                ln, off = struct.unpack("!Q", buf[2:10])[0], 10
            if ln > MAX_FRAME:
                return
            mk = 4 if masked else 0
            if len(buf) < off + mk + ln:
                break
            mask = buf[off:off + mk]
            payload = buf[off + mk:off + mk + ln]
            buf = buf[off + mk + ln:]
            if masked:
                payload = unmask(payload, mask)
            if op in (0, 1, 2):
                if payload:
                    t.sendall(payload)
            elif op == 8:
                c.sendall(ws_frame(8))
                return
            elif op == 9:
                c.sendall(ws_frame(10, payload))
        ready, _, _ = select.select(pair, [], [], idle)
        if not ready:
            return
        for s in ready:
            data = s.recv(65536 if s is c else 16384)
            if not data:
                return
            if s is c:
                buf += data
            else:
                c.sendall(ws_frame(2, data))


def connect(a):
    t = socket.create_connection((a.thost, a.tport), timeout=10)
    t.settimeout(None)
    t.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return t


def serve(c, a, mode):
    t = None
    try:
        c.settimeout(10)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        first = c.recv(4096)
        if not first:
            return
        if mode in ("raw", "connect") and first[:4] == b"SSH-":
            t = connect(a)
            c.settimeout(None)
            t.sendall(first)
            pipe_raw(c, t, a.idle)
            return
        buf = first
        while b"\r\n\r\n" not in buf:
            chunk = c.recv(4096)
            if not chunk or len(buf) > MAX_HEAD:
                return
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        hdr = parse_head(head)
        if mode == "ws":
            key = hdr.get("sec-websocket-key", "")
            if "websocket" not in hdr.get("upgrade", "").lower() or not key:
                c.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
                return
            acc = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest())
            c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                      b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + acc + b"\r\n\r\n")
        elif mode == "connect":
            c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        else:
            c.sendall(("HTTP/1.1 101 %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
                       % current_status(a)).encode())
        t = connect(a)
        c.settimeout(None)
        if mode == "ws":
            pipe_ws(c, t, a.idle, rest)
        else:
            if rest:
                t.sendall(rest)
            pipe_raw(c, t, a.idle)
    except Exception:
        pass
    finally:
        for s in (c, t):
            try:
                if s:
                    s.close()
            except Exception:
                pass


def run(c, a, mode):
    try:
        serve(c, a, mode)
    finally:
        SLOTS.release()


def hostport(s):
    host, port = s.rsplit(":", 1)
    return host, int(port)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, action="append",
                    help="host:puerto; se puede repetir para escuchar en varios puertos")
    ap.add_argument("--target", required=True)
    ap.add_argument("--mode", choices=("raw", "ws", "connect"), default="raw")
    ap.add_argument("--status", default="Switching Protocols")
    ap.add_argument("--status-file", default="")
    ap.add_argument("--idle", type=int, default=3600)
    a = ap.parse_args()
    a.thost, a.tport = hostport(a.target)
    if a.thost not in ("127.0.0.1", "localhost"):
        raise SystemExit("El destino debe ser local (127.0.0.1).")
    if not re.fullmatch(r"[A-Za-z0-9 ._-]{1,40}", a.status):
        raise SystemExit("Texto de estado inválido.")
    servers = []
    for spec in a.listen:
        spec, _, smode = spec.partition("=")   # host:puerto[=raw|connect|ws]
        smode = smode or a.mode
        if smode not in ("raw", "connect", "ws"):
            raise SystemExit("Modo inválido: " + smode)
        lhost, lport = hostport(spec)
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((lhost, lport))
        srv.listen(128)
        servers.append((srv, smode))
    for srv, smode in servers[1:]:
        threading.Thread(target=accept_loop, args=(srv, a, smode), daemon=True).start()
    accept_loop(servers[0][0], a, servers[0][1])


def accept_loop(srv, a, mode):
    while True:
        c, _ = srv.accept()
        if not SLOTS.acquire(blocking=False):
            c.close()
            continue
        threading.Thread(target=run, args=(c, a, mode), daemon=True).start()


if __name__ == "__main__":
    main()
