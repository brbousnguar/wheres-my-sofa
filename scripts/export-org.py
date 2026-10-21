#!/usr/bin/env python3
"""Saves how the deployed demo is set up in an Anypoint org, read-only, so a new org can be
built to match: the CloudHub 2.0 apps and their settings, the Omni Gateways, every API Manager
instance with its policies, upstreams and contracts, the org's Exchange assets, and the System
API's current orders and care cases.

    ANYPOINT_CLIENT_ID=... ANYPOINT_CLIENT_SECRET=... ANYPOINT_ORG_ID=... \\
    SAPI_KEY=... scripts/export-org.py <out-dir>

Optional: ANYPOINT_ENV (Sandbox). Secret values (keys, secrets, passwords, tokens, secure
properties) are replaced by "<redacted>", but the files still name the org and its IDs: keep
<out-dir> outside this public repo. A call the connected app may not make is saved as its error.
"""
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "https://anypoint.mulesoft.com"
SECRET = re.compile(r"secret|password|token|api[-_]?key|credential|secureproperties", re.I)
# The python.org build of Python on macOS ships without CA certificates: fall back to the system's.
TLS = ssl.create_default_context(cafile=None if os.environ.get("SSL_CERT_FILE") or not os.path.exists(
    "/etc/ssl/cert.pem") else "/etc/ssl/cert.pem")
EMAILS = ["camille.martin@example.com", "julien.bernard@example.com", "lea.dubois@example.com",
          "sofia.rossi@example.com"]


def redact(v, key=""):
    if isinstance(v, dict):
        return {k: redact(x, k) for k, x in v.items()}
    if isinstance(v, list):
        return [redact(x, key) for x in v]
    if SECRET.search(key) and v not in (None, "", True, False) and not isinstance(v, (int, float)):
        return "<redacted>"
    return v


def call(url, token=None, headers=None, data=None):
    h = {"accept": "application/json", **(headers or {})}
    if token:
        h["authorization"] = f"Bearer {token}"
    if data is not None:
        h["content-type"] = "application/json"
        data = json.dumps(data).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), timeout=60, context=TLS) as r:
            body = r.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        return {"error": e.code, "url": url, "body": e.read().decode(errors="replace")[:500]}
    except Exception as e:  # noqa: BLE001 - one failed call must not stop the export
        return {"error": str(e), "url": url}


def main():
    out = Path(sys.argv[1]).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    org = os.environ["ANYPOINT_ORG_ID"]
    env_name = os.environ.get("ANYPOINT_ENV", "Sandbox")
    tok = call(f"{API}/accounts/api/v2/oauth2/token", data={
        "grant_type": "client_credentials", "client_id": os.environ["ANYPOINT_CLIENT_ID"],
        "client_secret": os.environ["ANYPOINT_CLIENT_SECRET"]})["access_token"]
    get = lambda path: call(API + path, tok)  # noqa: E731

    def save(name, data):
        (out / f"{name}.json").write_text(json.dumps(redact(data), indent=2, ensure_ascii=False) + "\n")
        bad = isinstance(data, dict) and "error" in data
        print(("ERR " if bad else "ok  ") + name)

    envs = get(f"/accounts/api/organizations/{org}/environments")
    save("environments", envs)
    env = next(e["id"] for e in envs["data"] if e["name"] == env_name)
    base = f"/organizations/{org}/environments/{env}"

    deps = get(f"/amc/application-manager/api/v2{base}/deployments")
    save("cloudhub-deployments", deps)
    sapi_url = None
    for d in deps.get("items", []):
        detail = get(f"/amc/application-manager/api/v2{base}/deployments/{d['id']}")
        save(f"cloudhub-deployment-{d['name']}", detail)
        if d["name"] == "sofa-orders-sapi":
            http = detail.get("target", {}).get("deploymentSettings", {}).get("http", {})
            sapi_url = http.get("inbound", {}).get("publicUrl", "").split(",")[0].rstrip("/") or None

    save("gateways", get(f"/gatewaymanager/api/v1{base}/gateways"))

    apis = get(f"/apimanager/api/v1{base}/apis")
    save("api-manager-apis", apis)
    for group in apis.get("assets", []):
        for inst in group.get("apis", []):
            i = inst["id"]
            name = f"api-{i}-{group.get('assetId', 'api')}"
            save(name, get(f"/apimanager/api/v1{base}/apis/{i}"))
            save(f"{name}-policies", get(f"/apimanager/api/v1{base}/apis/{i}/policies"))
            # The policies list holds the outbound ones too (credential injection, transcoding).
            save(f"{name}-upstreams", get(f"/apimanager/api/v1{base}/apis/{i}/upstreams"))
            # Needs API Manager's View Contracts, which the deploy's connected app doesn't have.
            save(f"{name}-contracts", get(f"/apimanager/api/v1{base}/apis/{i}/contracts"))

    save("exchange-assets", get(f"/exchange/api/v2/assets?organizationId={org}&limit=100"))

    # The System API's data as it stands: the seed is apps/sofa-orders-sapi/.../orders.json,
    # this adds what the demos changed (moved deliveries, opened cases).
    if sapi_url and os.environ.get("SAPI_KEY"):
        key = {"x-api-key": os.environ["SAPI_KEY"]}
        save("sapi-orders", {e: call(f"{sapi_url}/api/orders?email={e}", headers=key) for e in EMAILS})
        save("sapi-cases", call(f"{sapi_url}/api/cases", headers=key))
    print(f"saved to {out}")


if __name__ == "__main__":
    main()
