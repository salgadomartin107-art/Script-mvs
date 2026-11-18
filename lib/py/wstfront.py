#!/usr/bin/env python3
"""Frente para WSTUNNEL en modo ws: decide qué hacer con cada conexión según su primera petición.

  - Cliente real de wstunnel (cabecera Sec-WebSocket-Protocol con "authorization.bearer.") -> se pasa
    tal cual al wstunnel interno (127.0.0.1), que valida el prefijo secreto.
  - Cualquier otra petición HTTP (payload de HTTP Custom / HTTP Injector) -> responde
    "101 Switching Protocols" (o "200 Connection established" si es CONNECT) y reenvía el flujo
    crudo al ÚNICO destino fijo y local (SSH/Dropbear). No es un proxy abierto.
  - Si el cliente empieza directo con "SSH-", se reenvía tal cual.
"""
import argparse
import select
import socket
import threading

MAX_HEAD = 16384
SLOTS = threading.BoundedSemaphore(500)


def pipe(c, t, idle):
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


def dial(host, port):
    t = socket.create_connection((host, port), timeout=10)
    t.settimeout(None)
    t.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return t


def serve(c, a):
    t = None
    try:
        c.settimeout(10)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        buf = c.recv(4096)
        if not buf:
            return
        if buf[:4] == b"SSH-":
            t = dial("127.0.0.1", a.target)
            c.settimeout(None)
            t.sendall(buf)
            pipe(c, t, a.idle)
            return
        while b"\r\n\r\n" not in buf:
            chunk = c.recv(4096)
            if not chunk or len(buf) > MAX_HEAD:
                return
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        low = head.lower()
        c.settimeout(None)
        if b"authorization.bearer." in low:
            t = dial("127.0.0.1", a.internal)
            t.sendall(buf)
        else:
            if head[:8].upper() == b"CONNECT ":
                c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            else:
                c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
            # Tras el payload, la app suele mandar por la misma conexión el handshake del cliente wstunnel:
            # se espera un instante lo que llegue para decidir si va a wstunnel o directo al SSH.
            nxt = rest
            if not nxt:
                ready, _, _ = select.select([c], [], [], a.wait)
                if ready:
                    nxt = c.recv(65536)
                    if not nxt:
                        return
            if nxt[:4] != b"SSH-" and b"authorization.bearer." in nxt[:MAX_HEAD].lower():
                while b"\r\n\r\n" not in nxt and len(nxt) < MAX_HEAD:
                    more = c.recv(4096)
                    if not more:
                        return
                    nxt += more
                t = dial("127.0.0.1", a.internal)
            else:
                t = dial("127.0.0.1", a.target)
            if nxt:
                t.sendall(nxt)
        pipe(c, t, a.idle)
    except Exception:
        pass
    finally:
        for s in (c, t):
            try:
                if s:
                    s.close()
            except Exception:
                pass


def run(c, a):
    try:
        serve(c, a)
    finally:
        SLOTS.release()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, type=int)
    ap.add_argument("--internal", required=True, type=int, help="puerto local de wstunnel")
    ap.add_argument("--target", required=True, type=int, help="puerto local de SSH/Dropbear")
    ap.add_argument("--idle", type=int, default=3600)
    ap.add_argument("--wait", type=float, default=1.0, help="segundos de espera tras el 101")
    a = ap.parse_args()
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", a.listen))
    srv.listen(128)
    while True:
        c, _ = srv.accept()
        if not SLOTS.acquire(blocking=False):
            c.close()
            continue
        threading.Thread(target=run, args=(c, a), daemon=True).start()


if __name__ == "__main__":
    main()
