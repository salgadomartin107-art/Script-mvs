#!/usr/bin/env python3
"""API mínima de consulta de usuarios: GET /<token>/<usuario> -> JSON.
El token (variable de entorno CHECKUSER_TOKEN) evita que cualquiera enumere usuarios."""
import argparse
import datetime
import hmac
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

NAME = re.compile(r"^[a-z_][a-z0-9_-]{2,30}$")
TOKEN = os.environ.get("CHECKUSER_TOKEN", "")
DB = "/etc/mvs/users.db"


def lookup(user):
    try:
        with open(DB) as f:
            for line in f:
                p = line.rstrip("\n").split("|")
                if len(p) >= 3 and p[0] == user:
                    return p[1], p[2]
    except OSError:
        pass
    return None


def online(user):
    try:
        out = subprocess.check_output(["pgrep", "-c", "-u", user, "sshd|dropbear"],
                                      stderr=subprocess.DEVNULL, universal_newlines=True, timeout=5)
        return int(out.strip() or 0)
    except subprocess.CalledProcessError:
        return 0   # pgrep sale con 1 cuando no hay coincidencias
    except Exception:
        return 0


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class H(BaseHTTPRequestHandler):
    def reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        if len(parts) != 2 or not TOKEN or not hmac.compare_digest(parts[0].encode(), TOKEN.encode()) or not NAME.match(parts[1]):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        user = parts[1]
        row = lookup(user)
        if not row:
            return self.reply(200, {"usuario": user, "existe": False})
        exp, limit = row
        try:
            days = (datetime.date.fromisoformat(exp) - datetime.date.today()).days
        except ValueError:
            days = None
        self.reply(200, {"usuario": user, "existe": True, "vence": exp, "dias": days,
                         "limite": int(limit) if limit.isdigit() else 0, "conectados": online(user)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0:8100")
    ap.add_argument("--db", default=DB)
    a = ap.parse_args()
    DB = a.db
    host, port = a.listen.rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), H).serve_forever()
