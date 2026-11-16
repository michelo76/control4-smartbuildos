#!/usr/bin/env python3
"""VenueFlow development server.

Serves the operator page and Installer Studio on http://localhost:<port>/ by
forwarding every HTTP request to tools/venueflow-devhost.lua, which runs the
real Lua core and relay router on the simulator. No controller is involved and
nothing here is evidence of controller behaviour.

    python3 tools/venueflow-dev.py                 # port 47861, sports bar sample
    VF_DEV_SAMPLE=conference_center python3 tools/venueflow-dev.py --port 47862

Operator page:     http://localhost:47861/app?k=devtile0123456789abcdef
Installer Studio:  http://localhost:47861/studio      (dev passcode: see devhost)

The pages are rebuilt from ui/venueflow before every page request, so editing
a source file and reloading the browser is enough.
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
MAX_BODY = 4 * 1024 * 1024


class Host:
    """One luajit process; requests are serialised through a lock.

    Framing both ways: one JSON line of metadata, then `bytes` raw bytes of
    body. The body is never put inside JSON, so a large upload reaches the
    Lua router the way it reaches the driver's socket.
    """

    def __init__(self, env):
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            ["luajit", "tools/venueflow-devhost.lua"],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )

    def call(self, message, body=b""):
        with self.lock:
            if self.proc.poll() is not None:
                raise RuntimeError("the Lua host exited")
            message = dict(message, bytes=len(body))
            self.proc.stdin.write(json.dumps(message).encode("utf-8") + b"\n" + body)
            self.proc.stdin.flush()
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("the Lua host closed its output")
            meta = json.loads(line)
            size = int(meta.get("bytes") or 0)
            data = b""
            while len(data) < size:
                chunk = self.proc.stdout.read(size - len(data))
                if not chunk:
                    raise RuntimeError("the Lua host closed its output")
                data += chunk
            meta["body"] = data
            return meta


def rebuild_pages():
    subprocess.run(
        [sys.executable, "tools/venueflow-ui.py", "build", "--quiet"],
        cwd=ROOT,
        check=False,
    )


def make_handler(host):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quiet: the state poll would flood the log
            if "/api" not in (self.path or ""):
                sys.stderr.write("[http] " + fmt % args + "\n")

        def _forward(self, method):
            parts = urlsplit(self.path)
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                self.send_response(413)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = self.rfile.read(length) if length else b""
            if method == "GET" and parts.path in ("/app", "/studio"):
                rebuild_pages()
            try:
                result = host.call(
                    {
                        "type": "http",
                        "method": method,
                        "path": parts.path,
                        "query": dict(parse_qsl(parts.query, keep_blank_values=True)),
                        "session": self.headers.get("X-VF-Session"),
                        "client": self.client_address[0],
                    },
                    body,
                )
            except Exception as exc:  # the Lua host died
                payload = json.dumps({"ok": False, "error": str(exc)}).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            status = result.get("status", "500 Internal Server Error")
            code, _, reason = status.partition(" ")
            payload = result.get("body") or b""
            self.send_response(int(code), reason)
            self.send_header(
                "Content-Type", result.get("contentType", "application/json")
            )
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header(
                "Access-Control-Allow-Headers", "Content-Type, X-VF-Session"
            )
            for header in result.get("headers") or []:
                name, _, value = header.partition(": ")
                self.send_header(name, value)
            self.end_headers()
            if payload:
                self.wfile.write(payload)

        def do_GET(self):
            if urlsplit(self.path).path == "/":
                self.send_response(302)
                self.send_header(
                    "Location",
                    "/app?k="
                    + os.environ.get("VF_DEV_TILE", "devtile0123456789abcdef"),
                )
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self._forward("GET")

        def do_POST(self):
            self._forward("POST")

        def do_OPTIONS(self):
            self._forward("OPTIONS")

    return Handler


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("PORT", "47861"))
    )
    args = parser.parse_args()

    env = dict(os.environ)
    env.setdefault("VF_DEV_SAMPLE", "sports_bar")
    (ROOT / "build").mkdir(exist_ok=True)
    env.setdefault(
        "VF_DEV_STATE", str(ROOT / "build" / f"venueflow-dev-state-{args.port}.json")
    )
    env["VF_DEV_PORT"] = str(args.port)
    rebuild_pages()
    host = Host(env)

    def ticker():
        last = time.monotonic()
        while True:
            time.sleep(0.1)
            now = time.monotonic()
            try:
                host.call({"type": "tick", "ms": int((now - last) * 1000)})
            except Exception:
                return
            last = now

    threading.Thread(target=ticker, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(host))
    sys.stderr.write(
        f"[venueflow-dev] http://localhost:{args.port}/  (simulator; not a controller)\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        host.proc.terminate()


if __name__ == "__main__":
    main()
