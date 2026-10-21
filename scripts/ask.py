#!/usr/bin/env python3
"""Talk to the Care Desk broker over A2A v1.0 from a terminal.

    BROKER_URL=https://<gateway>/<broker-path> CLIENT_ID=... CLIENT_SECRET=... scripts/ask.py

Each line you type is one SendMessage. The script reuses the contextId the broker returns,
so the broker remembers earlier turns. Pass a message as arguments to send just that one.
"""
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

URL = os.environ["BROKER_URL"].rstrip("/") + "/"
HEADERS = {
    "content-type": "application/json",
    "A2A-Version": "1.0",
    "client_id": os.environ["CLIENT_ID"],
    "client_secret": os.environ["CLIENT_SECRET"],
}


def send(text, context_id=None):
    message = {"role": "ROLE_USER", "parts": [{"text": text}], "messageId": str(uuid.uuid4())}
    if context_id:
        message["contextId"] = context_id
    body = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": "SendMessage", "params": {"message": message}}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers=HEADERS, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP {e.code}: {e.read().decode()[:400]}")
    if "error" in data:
        raise SystemExit(f"A2A error: {data['error']}")
    task = data["result"]["task"]
    reply = " ".join(p.get("text", "") for p in task["status"]["message"]["parts"])
    return task["contextId"], task["status"]["state"], reply


def main():
    context_id = os.environ.get("CONTEXT_ID")
    if len(sys.argv) > 1:
        context_id, state, reply = send(" ".join(sys.argv[1:]), context_id)
        print(f"{reply}\n\n[{state} · contextId {context_id}]")
        return
    print("Care Desk. Ctrl-D to quit.")
    while True:
        try:
            text = input("\nyou> ").strip()
        except EOFError:
            print()
            return
        if text:
            context_id, state, reply = send(text, context_id)
            print(f"\ndesk> {reply}")


if __name__ == "__main__":
    main()
