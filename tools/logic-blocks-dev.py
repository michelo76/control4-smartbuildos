#!/usr/bin/env python3
"""Logic Blocks development server.

Serves the dealer page on http://localhost:<port>/ by forwarding every HTTP
request to tools/logic-blocks-devhost.lua, which runs the real block runtime,
sandbox and relay router. No controller is involved and nothing here is
evidence of controller behaviour.

    python3 tools/logic-blocks-dev.py                       # port 47871, sample house
    LB_DEV_SCENARIO=empty python3 tools/logic-blocks-dev.py --port 47872
    LB_DEV_SCENARIO=restore_failed python3 tools/logic-blocks-dev.py --port 47873

Page:  http://localhost:47871/app?k=devblocks0123456789abcdef

The page file is read on every request, so editing it and reloading is enough.

Dev-only switches (not part of the driver):
    POST /__dev/offline  {"on": true}   the server stops answering the page
    POST /__dev/command, /__dev/variable, /__dev/restart, /__dev/readonly
        forwarded to the dev host (see its header)
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
MAX_BODY = 256 * 1024


class Host:
    """One luajit process; requests are serialised through a lock."""

    def __init__(self):
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            ["luajit", "tools/logic-blocks-devhost.lua"],
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
OFFLINE = {"on": False}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if os.environ.get("LB_DEV_QUIET"):
            return
        text = fmt % args
        # The page token never reaches the log.
        sys.stderr.write(text.replace(os.environ.get("LB_DEV_TOKEN", "devblocks0123456789abcdef"), "[token]") + "\n")

    def _send(self, status, content_type, body):
        data = body.encode("utf-8") if isinstance(body, str) else body
        code = int(str(status).split(" ")[0])
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def _handle(self, method):
        parts = urlsplit(self.path)
        length = min(int(self.headers.get("Content-Length") or 0), MAX_BODY)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        if parts.path == "/__dev/offline":
            try:
                OFFLINE["on"] = bool(json.loads(body or "{}").get("on"))
            except ValueError:
                OFFLINE["on"] = False
            return self._send("200 OK", "application/json", json.dumps({"ok": True, "offline": OFFLINE["on"]}))
        if parts.path in ("/", ""):
            self.send_response(302)
            self.send_header("Location", "/app?k=" + os.environ.get("LB_DEV_TOKEN", "devblocks0123456789abcdef"))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        if OFFLINE["on"] and parts.path not in ("/app",) and not parts.path.startswith("/__dev/"):
            # What a controller that stopped answering looks like to the page.
            self.close_connection = True
            self.connection.close()
            return None
        answer = HOST.call(
            {"type": "http", "method": method, "path": parts.path, "query": dict(parse_qsl(parts.query)), "body": body}
        )
        return self._send(answer.get("status", "500"), answer.get("contentType", "application/json"), answer.get("body", ""))

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_OPTIONS(self):
        self._handle("OPTIONS")


def ticker():
    while True:
        time.sleep(0.25)
        try:
            HOST.call({"type": "tick"})
        except Exception:  # the host went away with the server
            return


def main():
    global HOST
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "47871")))
    args = parser.parse_args()
    HOST = Host()
    HOST.call({"type": "tick"})
    threading.Thread(target=ticker, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    token = os.environ.get("LB_DEV_TOKEN", "devblocks0123456789abcdef")
    print(f"Logic Blocks dev page: http://localhost:{args.port}/app?k={token}", flush=True)
    print("Development host: no controller, no Composer, no equipment.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
