#!/usr/bin/env python3
"""A local demo page: chat with the deployed Care Desk broker, and watch the System API change.

    BROKER_URL=... CLIENT_ID=... CLIENT_SECRET=... SAPI_URL=https://<sofa-orders-sapi> SAPI_KEY=... demo/server.py

The page talks only to this server, which holds the credentials: it forwards each message to the
broker over A2A and reads the demo orders and care cases from the System API. It listens on
127.0.0.1, on DEMO_PORT or a free port, and prints the address.
"""
import json
import os
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "scripts"))
from ask import send  # noqa: E402  (reads BROKER_URL, CLIENT_ID and CLIENT_SECRET)

SAPI = os.environ["SAPI_URL"].rstrip("/") + "/api"
SAPI_KEY = os.environ["SAPI_KEY"]
OWNERS = {
    "SO-24817": "camille.martin@example.com",
    "SO-25012": "camille.martin@example.com",
    "SO-24903": "julien.bernard@example.com",
    "SO-24770": "lea.dubois@example.com",
    "SO-24655": "sofia.rossi@example.com",
}


def sapi(path):
    req = urllib.request.Request(SAPI + path, headers={"x-api-key": SAPI_KEY})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def state():
    orders = []
    for order_id, email in OWNERS.items():
        o = sapi(f"/orders/{order_id}?email={email}")
        delivery = o.get("delivery") or {}
        orders.append({
            "orderId": o["orderId"],
            "customer": o["customerName"],
            "items": ", ".join((f"{l['quantity']} × " if l["quantity"] > 1 else "") + l["product"] for l in o["lines"]),
            "status": o["status"],
            "delivery": delivery.get("status"),
            "slot": delivery.get("slot"),
        })
    return {"orders": orders, "cases": sapi("/cases")["cases"]}


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", content_type)
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            self.reply(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/api/state":
            self.reply(200, state())
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/ask":
            return self.reply(404, {"error": "not found"})
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or "{}")
        started = time.monotonic()
        try:
            context_id, task_state, text = send(body["text"], body.get("contextId"))
        except SystemExit as e:
            return self.reply(502, {"error": str(e)})
        self.reply(200, {"contextId": context_id, "state": task_state, "reply": text,
                         "seconds": round(time.monotonic() - started, 1)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("DEMO_PORT", 0))), Handler)
    print(f"Demo at http://127.0.0.1:{server.server_port}/", flush=True)
    server.serve_forever()
