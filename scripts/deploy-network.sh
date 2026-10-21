#!/usr/bin/env bash
# Publishes the agent network to Exchange and deploys the Care Desk broker behind Omni Gateway.
#
# Needs: ANYPOINT_CLIENT_ID, ANYPOINT_CLIENT_SECRET, ANYPOINT_ORG_ID, SOFA_CARE_MCP_URL (printed by
# deploy-apps.sh), MCP_KEY (the same one the MCP app got) and OPENROUTER_API_KEY.
# Optional: ANYPOINT_ENV (Sandbox), TARGET (Cloudhub-US-East-2), GATEWAY (agent-network-gw),
# AF_CLI (the Agent Fabric CLI, default: anypoint-cli-agent-fabric-plugin on PATH).
#
# First run only: SETUP_GATEWAY=1 creates the managed Omni Gateway in the target space. On a trial
# organization add TRIAL=1, which creates the Small gateway with the settings a trial accepts, or
# uses the one that already has that name.
set -euo pipefail

: "${ANYPOINT_CLIENT_ID:?}" "${ANYPOINT_CLIENT_SECRET:?}" "${ANYPOINT_ORG_ID:?}"
: "${SOFA_CARE_MCP_URL:?}" "${MCP_KEY:?}" "${OPENROUTER_API_KEY:?}"
ENV_NAME="${ANYPOINT_ENV:-Sandbox}"
TARGET="${TARGET:-Cloudhub-US-East-2}"
GATEWAY="${GATEWAY:-agent-network-gw}"
AF="${AF_CLI:-anypoint-cli-agent-fabric-plugin}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ANYPOINT_CLIENT_ID ANYPOINT_CLIENT_SECRET

# The project keeps groupId as a placeholder; the build copy gets the real organization ID.
# The copy lives in the repo, not mktemp: on macOS the CLI refuses any path under /private,
# which is where /tmp and /var/folders resolve.
work="$ROOT/.build/agent-network"
rm -rf "$work" && mkdir -p "$work"
trap 'rm -rf "$ROOT/.build"' EXIT
cp -R "$ROOT/agent-network/." "$work/"
rm -rf "$work/target"
python3 - "$work/exchange.json" "$ANYPOINT_ORG_ID" <<'EOF'
import json, sys
path, org = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["groupId"] = d["organizationId"] = org
json.dump(d, open(path, "w"), indent=2)
EOF

common=(--organization "$ANYPOINT_ORG_ID" --environment "$ENV_NAME")

if [[ "${SETUP_GATEWAY:-0}" == 1 && "${TRIAL:-0}" == 1 ]]; then
  # The CLI creates a Large gateway with a 60 s upstream timeout and tracing on. A trial org only
  # has a Small gateway and rejects both settings, so create it through Gateway Manager instead.
  # The CLI reuses a gateway it finds by name, and so does this, so a stopped run can be repeated.
  echo "Setting up a Small Omni Gateway $GATEWAY in $TARGET (trial settings)..."
  API=https://anypoint.mulesoft.com
  tok="$(curl -fsS -X POST "$API/accounts/api/v2/oauth2/token" -H 'content-type: application/json' \
    -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$ANYPOINT_CLIENT_ID\",\"client_secret\":\"$ANYPOINT_CLIENT_SECRET\"}" |
    python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])')"
  env_id="$(curl -fsS -H "Authorization: Bearer $tok" "$API/accounts/api/organizations/$ANYPOINT_ORG_ID/environments" |
    python3 -c "import sys, json; print(next(e['id'] for e in json.load(sys.stdin)['data'] if e['name'] == '$ENV_NAME'))")"
  gateways="$API/gatewaymanager/api/v1/organizations/$ANYPOINT_ORG_ID/environments/$env_id/gateways"
  gateway_status() {
    curl -fsS -H "Authorization: Bearer $tok" "$gateways" |
      python3 -c "import sys, json; print(next((g['status'] for g in json.load(sys.stdin)['content'] if g['name'] == '$GATEWAY'), ''))"
  }
  if [[ -n "$(gateway_status)" ]]; then
    printf "  it already exists, waiting for it to be up"
  else
    version="$(curl -fsS -H "Authorization: Bearer $tok" "$API/gatewaymanager/xapi/v1/gateway/versions" |
      python3 -c 'import sys, json; print(json.load(sys.stdin)["channels"]["edge"]["versions"][0]["displayName"])')"
    curl -fsS -X POST -H "Authorization: Bearer $tok" -H 'content-type: application/json' "$gateways" \
      -d "{\"name\":\"$GATEWAY\",\"targetId\":\"$(echo "$TARGET" | tr 'A-Z' 'a-z')\",\"releaseChannel\":\"edge\",
           \"runtimeVersion\":\"$version\",\"size\":\"small\",\"configuration\":{
           \"ingress\":{\"publicUrl\":\"\",\"forwardSslSession\":false,\"lastMileSecurity\":false},
           \"logging\":{\"level\":\"info\",\"forwardLogs\":true},
           \"properties\":{\"upstreamResponseTimeout\":15,\"connectionIdleTimeout\":60},
           \"tracing\":{\"enabled\":false,\"sampling\":100}}}" >/dev/null
    printf "  created, waiting for it to start"
  fi
  # The broker can't deploy until the gateway is up: Gateway Manager lists it as APPLIED then.
  for _ in $(seq 1 60); do
    status="$(gateway_status)"
    [[ "$status" == APPLIED ]] && break
    printf "."; sleep 15
  done
  echo " $status"
  [[ "$status" == APPLIED ]] || { echo "  the gateway isn't up after 15 minutes, check Runtime Manager" >&2; exit 1; }
elif [[ "${SETUP_GATEWAY:-0}" == 1 ]]; then
  echo "Setting up Omni Gateway $GATEWAY in $TARGET..."
  "$AF" agent-network setup gateways -t "$TARGET" -g "$GATEWAY" "${common[@]}"
fi

echo "Building and publishing..."
"$AF" agent-network project build --path "$work" "${common[@]}"
"$AF" agent-network project publish --path "$work" "${common[@]}"

echo "Deploying the Care Desk broker..."
# stdin is /dev/null so a variable without a --property fails the deploy instead of prompting.
"$AF" agent-network project deploy --path "$work" -g "$GATEWAY" -t "$TARGET" "${common[@]}" \
  --property "sofaCareMcp.url:${SOFA_CARE_MCP_URL%/}" \
  --property "sofaCareMcp.apiKey:$MCP_KEY" \
  --property "openRouter.apiKey:$OPENROUTER_API_KEY" \
  --property "OBJECT_STORE_DEFAULT_TTL_MS:${CONVERSATION_TTL_MS:-86400000}" \
  --deployment-property brokers:vCores:0.1 </dev/null
