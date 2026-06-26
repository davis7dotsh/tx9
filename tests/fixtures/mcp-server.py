#!/usr/bin/env python3
import http.server
import json
import pathlib
import sys


port_file = pathlib.Path(sys.argv[1])
status = int(sys.argv[2])
events_file = pathlib.Path(sys.argv[3])
response_mode = sys.argv[4] if len(sys.argv) > 4 else "valid"


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
        length = int(self.headers.get("Content-Length", "0"))
        try:
            request = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.respond(400)
            return
        if request.get("method") == "initialize":
            params = request.get("params", {})
            if (
                request.get("jsonrpc") != "2.0"
                or request.get("id") != 1
                or params.get("protocolVersion") != "2025-03-26"
                or not isinstance(params.get("capabilities"), dict)
                or params.get("clientInfo", {}).get("name") != "hermes-box-doctor"
                or params.get("clientInfo", {}).get("version") != "1"
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


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(f"{server.server_port}\n")
server.serve_forever()
