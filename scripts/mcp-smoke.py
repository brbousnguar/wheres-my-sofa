#!/usr/bin/env python3
"""Opens an MCP session on sofa-care-mcp and calls every tool once.

    scripts/mcp-smoke.py http://localhost:8721/mcp local-mcp-key
"""
import json, sys, urllib.request
U = sys.argv[1]; KEY = sys.argv[2]
sid = None
def rpc(method, params=None, id=1, notify=False):
    global sid
    body = {"jsonrpc": "2.0", "method": method}
    if not notify: body["id"] = id
    if params is not None: body["params"] = params
    h = {"accept": "application/json, text/event-stream", "content-type": "application/json", "x-api-key": KEY}
    if sid: h["mcp-session-id"] = sid
    req = urllib.request.Request(U, data=json.dumps(body).encode(), headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        sid = r.headers.get("mcp-session-id") or sid
        if notify: return None
        if "json" in (r.headers.get("content-type") or "") and "event-stream" not in r.headers.get("content-type"):
            return json.loads(r.read().decode())
        for line in r:
            line = line.decode().strip()
            if line.startswith("data:"): return json.loads(line[5:])
    return None
rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "1"}})
rpc("notifications/initialized", notify=True)
tools = rpc("tools/list", {}, id=2)["result"]["tools"]
print("tools:", [t["name"] for t in tools])
def call(name, args, i):
    r = rpc("tools/call", {"name": name, "arguments": args}, id=i)["result"]
    txt = r["content"][0]["text"]
    print(f"\n{name} {json.dumps(args)} isError={r.get('isError')}\n  {txt[:300]}")
call("find_orders", {"email": "camille.martin@example.com"}, 3)
call("get_order", {"orderId": "SO-24817", "email": "wrong@example.com"}, 4)
call("list_delivery_slots", {"orderId": "SO-24770", "email": "lea.dubois@example.com"}, 5)
call("list_delivery_slots", {"orderId": "SO-24903", "email": "julien.bernard@example.com"}, 6)
call("reschedule_delivery", {"orderId": "SO-24903", "email": "julien.bernard@example.com", "slotId": "D12-AM"}, 7)
call("open_care_case", {"orderId": "SO-24655", "email": "sofia.rossi@example.com", "category": "DAMAGE", "summary": "Scratch on the Halo table top; customer wants a repair."}, 8)
