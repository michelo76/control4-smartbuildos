#!/usr/bin/env python3
"""AI Core touchscreen page development server.

Serves the AI Core page on http://localhost:<port>/ by forwarding every HTTP
request to tools/aicore-devhost.lua, which runs the REAL page relay
(src/aicore/webui.lua) with a scripted cloud and a fake PIN Lock. A second
listener on 47831 plays PIN Lock's /verify (the page only ever posts a PIN
there, as on a controller). No controller, cloud or PIN Lock is involved and
nothing here is evidence of their behaviour.

    python3 tools/aicore-dev.py                         # open chat, port 47881
    AIC_DEV_ACCESS=owner_pin python3 tools/aicore-dev.py --port 47882

Page:  http://127.0.0.1:47881/app?k=aicoredev0123456789abcdef0123456
Dev PIN: 2468 (AIC_DEV_PIN)
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

ROOT = Path(__file__).resolve().parent.parent
MAX_BODY = 8 * 1024
TOKEN = os.environ.get("AIC_DEV_TOKEN", "aicoredev0123456789abcdef0123456")


class Host:
    """One luajit process; requests are serialised through a lock."""

    def __init__(self):
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            ["luajit", "tools/aicore-devhost.lua"],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

    def call(self, message):
        message["now"] = time.time()
        with self.lock:
            self.proc.stdin.write(json.dumps(message) + "\n")
            self.proc.stdin.flush()
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    raise RuntimeError("the dev host exited")
                line = line.strip()
                if line.startswith("{"):
                    return json.loads(line)


HOST = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    verify_only = False

    def log_message(self, fmt, *args):
        if os.environ.get("AIC_DEV_QUIET"):
            return
        sys.stderr.write((fmt % args).replace(TOKEN, "[token]") + "\n")

    def _send(self, status, content_type, body, cors=False):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(int(str(status).split(" ")[0]))
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if cors:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def _handle(self, method):
        parts = urlsplit(self.path)
        length = min(int(self.headers.get("Content-Length") or 0), MAX_BODY)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        if self.verify_only:
            if method == "OPTIONS":
                return self._send("204 No Content", "text/plain", "", cors=True)
            if parts.path != "/verify" or method != "POST":
                return self._send("404 Not Found", "application/json", "{}", cors=True)
            answer = HOST.call({"type": "verify", "body": body})
            return self._send(
                "200 OK", "application/json", answer.get("body", "{}"), cors=True
            )
        if parts.path in ("/", ""):
            self.send_response(302)
            self.send_header("Location", "/app?k=" + TOKEN)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        hostname = (self.headers.get("Host") or "127.0.0.1").split(":")[0]
        answer = HOST.call(
            {
                "type": "http",
                "method": method,
                "path": parts.path,
                "query": dict(parse_qsl(parts.query)),
                "body": body,
                "host": hostname,
            }
        )
        return self._send(
            answer.get("status", "500"),
            answer.get("contentType", "application/json"),
            answer.get("body", ""),
        )

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_OPTIONS(self):
        self._handle("OPTIONS")


class VerifyHandler(Handler):
    verify_only = True


def ticker():
    while True:
        time.sleep(0.25)
        try:
            HOST.call({"type": "tick"})
        except Exception:  # the host went away with the server
            return


def main():
    global HOST
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("PORT", "47881"))
    )
    parser.add_argument("--verify-port", type=int, default=47831)
    args = parser.parse_args()
    HOST = Host()
    HOST.call({"type": "tick"})
    threading.Thread(target=ticker, daemon=True).start()
    try:
        verify = ThreadingHTTPServer(("127.0.0.1", args.verify_port), VerifyHandler)
        threading.Thread(target=verify.serve_forever, daemon=True).start()
    except OSError:
        print(
            f"PIN Lock stand-in not started (port {args.verify_port} busy)", flush=True
        )
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"AI Core dev page: http://127.0.0.1:{args.port}/app?k={TOKEN}", flush=True)
    print("Development host: no controller, no cloud, no PIN Lock.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
