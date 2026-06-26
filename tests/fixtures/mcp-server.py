#!/usr/bin/env python3
import http.server
import json
import pathlib
import socket
import sys


port_file = pathlib.Path(sys.argv[1])
status = int(sys.argv[2])
events_file = pathlib.Path(sys.argv[3])
response_mode = sys.argv[4] if len(sys.argv) > 4 else "valid"
bind_host = sys.argv[5] if len(sys.argv) > 5 else "127.0.0.1"


def record(event):
    with events_file.open("a") as events:
        events.write(f"{event}\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self, code, body=b"", content_type=None):
        self.send_response(code)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        if self.path != "/mcp":
            self.respond(404)
            return
        if self.headers.get("Authorization") != "Bearer fixture-token":
            self.respond(401)
            return
        if not self.headers.get("Content-Type", "").startswith("application/json"):
            self.respond(400)
            return
        accept = self.headers.get("Accept", "")
        if "application/json" not in accept or "text/event-stream" not in accept:
            self.respond(400)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except (TypeError, ValueError):
            self.respond(400)
            return
        if length < 0:
            self.respond(400)
            return
        try:
            request = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.respond(400)
            return
        if not isinstance(request, dict):
            self.respond(400)
            return
        if request.get("method") == "initialize":
            params = request.get("params", {})
            if not isinstance(params, dict):
                self.respond(400)
                return
            client_info = params.get("clientInfo", {})
            if (
                request.get("jsonrpc") != "2.0"
                or request.get("id") != 1
                or params.get("protocolVersion") != "2025-03-26"
                or not isinstance(params.get("capabilities"), dict)
                or not isinstance(client_info, dict)
                or client_info.get("name") != "hermes-box-doctor"
                or client_info.get("version") != "1"
            ):
                self.respond(400)
                return
            if status != 200:
                self.respond(status)
                return
            protocol_version = "2025-03-26"
            if response_mode == "wrong-version":
                protocol_version = "2024-11-05"
            response = {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {
                    "protocolVersion": protocol_version,
                    "serverInfo": {"name": "fixture", "version": "1"},
                    "capabilities": {},
                },
            }
            body = json.dumps(response).encode()
            content_type = "application/json"
            if response_mode == "malformed-json":
                body = b'{"jsonrpc":'
            elif response_mode == "wrong-content-type":
                content_type = "text/plain"
            elif response_mode == "event-stream":
                body = b"data: " + body + b"\n\n"
                content_type = "text/event-stream"
            self.send_response(200)
            self.send_header("Mcp-Session-Id", "fixture-session")
            self.send_header("Content-Type", content_type)
            self.end_headers()
            self.wfile.write(body)
            return
        if request.get("method") == "notifications/initialized":
            if request.get("jsonrpc") != "2.0" or "id" in request:
                self.respond(400)
                return
            if self.headers.get("Mcp-Session-Id") != "fixture-session":
                self.respond(404)
                return
            record("initialized")
            self.respond(202)
            return
        self.respond(400)

    def do_GET(self):
        if self.path != "/health":
            self.respond(404)
            return
        if status != 200:
            self.respond(status, b'{"status":"error"}', "application/json")
            return
        body = b'{"status":"ok","platform":"hermes-agent"}'
        if response_mode == "health-malformed":
            body = b'{"status":'
        self.respond(200, body, "application/json")

    def do_DELETE(self):
        if (
            self.path == "/mcp"
            and self.headers.get("Authorization") == "Bearer fixture-token"
            and self.headers.get("Mcp-Session-Id") == "fixture-session"
        ):
            record("deleted")
            self.respond(204)
            return
        self.respond(400)

    def log_message(self, _format, *_args):
        pass


class ThreadingHTTPServerV6(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


server_class = ThreadingHTTPServerV6 if bind_host == "::1" else http.server.ThreadingHTTPServer
server = server_class((bind_host, 0), Handler)
port_file.write_text(f"{server.server_port}\n")
server.serve_forever()
