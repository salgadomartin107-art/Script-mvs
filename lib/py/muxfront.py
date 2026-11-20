#!/usr/bin/env python3
"""Multiplexor de un solo puerto (tipo sslh): mira los primeros bytes de cada conexión y la manda al destino local que corresponde.
  TLS (ClientHello)            -> --tls   (stunnel: SSL/TLS con SNI)
  SSH-...                      -> --ssh   (OpenSSH / Dropbear)
  HTTP o payload (GET, CONNECT) -> --http  (WS-PRO / PYTHON-WS)
  silencio (el cliente espera el banner del servidor, como SSH) -> --ssh tras --timeout segundos
Todos los destinos son locales (127.0.0.1). Solo biblioteca estándar."""
import argparse, select, socket, threading

MAX_CONN = 512
SLOTS = threading.BoundedSemaphore(MAX_CONN)
HTTP_START = (b"GET ", b"POST", b"HEAD", b"PUT ", b"OPTI", b"CONN", b"DELE", b"PATC", b"TRAC", b"PRI ")


def classify(d):
    d = d.lstrip(b"\r\n")            # los bloques [split] de un payload pueden empezar con líneas en blanco
    if not d:
        return "http"
    if d[0] == 0x16 and len(d) >= 2 and d[1] == 0x03:
        return "tls"
    if d[:4] == b"SSH-":
        return "ssh"
    if d[:4].upper() in HTTP_START:
        return "http"
    return "http"                    # cualquier otro arranque de payload


def hostport(s):
    h, p = s.rsplit(":", 1)
    if h not in ("127.0.0.1", "localhost"):
        raise SystemExit("Los destinos deben ser locales (127.0.0.1).")
    return h, int(p)


def pipe(a, b, idle):
    socks = [a, b]
    while True:
        r, _, _ = select.select(socks, [], [], idle)
        if not r:
            return
        for s in r:
            d = s.recv(65536)
            if not d:
                return
            (b if s is a else a).sendall(d)


def handle(c, args):
    t = None
    try:
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        first = b""
        c.settimeout(args.timeout)
        try:
            while len(first) < 4:
                chunk = c.recv(4096)
                if not chunk:
                    return
                first += chunk
        except socket.timeout:
            pass                      # nadie habló: es un cliente que espera el banner (SSH)
        kind = classify(first) if first else "ssh"
        dest = {"tls": args.tls, "ssh": args.ssh, "http": args.http}.get(kind)
        if not dest:
            return
        t = socket.create_connection(dest, timeout=10)
        t.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        t.settimeout(None)
        c.settimeout(None)
        if first:
            t.sendall(first)
        pipe(c, t, args.idle)
    except Exception:
        pass
    finally:
        for s in (c, t):
            try:
                if s:
                    s.close()
            except Exception:
                pass
        SLOTS.release()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True)
    ap.add_argument("--tls", default="")
    ap.add_argument("--ssh", default="")
    ap.add_argument("--http", default="")
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--idle", type=int, default=3600)
    a = ap.parse_args()
    for k in ("tls", "ssh", "http"):
        setattr(a, k, hostport(getattr(a, k)) if getattr(a, k) else None)
    lh, lp = a.listen.rsplit(":", 1)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lh, int(lp)))
    srv.listen(256)
    while True:
        c, _ = srv.accept()
        if not SLOTS.acquire(blocking=False):
            c.close()
            continue
        threading.Thread(target=handle, args=(c, a), daemon=True).start()


if __name__ == "__main__":
    main()
