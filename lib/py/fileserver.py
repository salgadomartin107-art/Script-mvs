#!/usr/bin/env python3
"""Sirve archivos sueltos en /<token>/<archivo>. Sin listado de directorios ni subcarpetas."""
import argparse
import hmac
import os
import re
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import unquote

TOKEN = os.environ.get("FILESERVER_TOKEN", "")
ROOT = "/var/lib/mvs/www"
FILE = re.compile(r"^[A-Za-z0-9._-]{1,80}$")


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class H(BaseHTTPRequestHandler):
    def not_found(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        parts = unquote(self.path.split("?")[0]).strip("/").split("/")
        if len(parts) != 2 or not TOKEN or not hmac.compare_digest(parts[0].encode(), TOKEN.encode()) or not FILE.match(parts[1]):
            return self.not_found()
        path = os.path.join(ROOT, parts[1])
        if not os.path.isfile(path) or os.path.islink(path):
            return self.not_found()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % parts[1])
        self.send_header("Content-Length", str(os.path.getsize(path)))
        self.end_headers()
        with open(path, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0:81")
    ap.add_argument("--root", default=ROOT)
    a = ap.parse_args()
    ROOT = a.root
    host, port = a.listen.rsplit(":", 1)
    ThreadingHTTPServer((host, int(port)), H).serve_forever()
