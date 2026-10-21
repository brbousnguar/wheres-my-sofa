#!/usr/bin/env bash
# Deploys the two Mule apps to CloudHub 2.0: the System API first, then the MCP server
# pointed at the System API's public URL.
#
# Needs: ANYPOINT_CLIENT_ID, ANYPOINT_CLIENT_SECRET, ANYPOINT_ORG_ID (a connected app with
# Runtime Manager and Exchange Contributor permissions), SAPI_KEY and MCP_KEY (any random
# strings, e.g. `openssl rand -hex 24`). Optional: ANYPOINT_ENV (Sandbox), TARGET (Cloudhub-US-East-2),
# MULE_VERSION (4.12.5: MCP Connector 1.7.2 fails to start on 4.9.6), JAVA_HOME pointing at JDK 17.
set -euo pipefail

: "${ANYPOINT_CLIENT_ID:?}" "${ANYPOINT_CLIENT_SECRET:?}" "${ANYPOINT_ORG_ID:?}" "${SAPI_KEY:?}" "${MCP_KEY:?}"
ENV_NAME="${ANYPOINT_ENV:-Sandbox}"
TARGET="${TARGET:-Cloudhub-US-East-2}"
MULE_VERSION="${MULE_VERSION:-4.12.5}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MVN="${MVN:-mvn}"
API=https://anypoint.mulesoft.com

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Exchange accepts a connected app as ~~~Client~~~ / id~?~secret.
cat > "$work/settings.xml" <<EOF
<settings>
  <servers>
    <server>
      <id>anypoint-exchange-v3</id>
      <username>~~~Client~~~</username>
      <password>${ANYPOINT_CLIENT_ID}~?~${ANYPOINT_CLIENT_SECRET}</password>
    </server>
  </servers>
</settings>
EOF

token() {
  curl -fsS -X POST "$API/accounts/api/v2/oauth2/token" -H 'content-type: application/json' \
    -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$ANYPOINT_CLIENT_ID\",\"client_secret\":\"$ANYPOINT_CLIENT_SECRET\"}" |
    python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])'
}

public_url() { # app name -> https://host
  local tok env_id
  tok="$(token)"
  env_id="$(curl -fsS -H "Authorization: Bearer $tok" "$API/accounts/api/organizations/$ANYPOINT_ORG_ID/environments" |
    python3 -c "import sys, json; print(next(e['id'] for e in json.load(sys.stdin)['data'] if e['name'] == '$ENV_NAME'))")"
  local deployments="$API/amc/application-manager/api/v2/organizations/$ANYPOINT_ORG_ID/environments/$env_id/deployments"
  local dep_id
  dep_id="$(curl -fsS -H "Authorization: Bearer $tok" "$deployments" |
    python3 -c "import sys, json; print(next(d['id'] for d in json.load(sys.stdin)['items'] if d['name'] == '$1'))")"
  curl -fsS -H "Authorization: Bearer $tok" "$deployments/$dep_id" |
    python3 -c "import sys, json; d = json.load(sys.stdin); print(d['target']['deploymentSettings']['http']['inbound']['publicUrl'].split(',')[0].rstrip('/'))"
}

published() { # app dir -> exit 0 if Exchange already has this version
  local dir="$1" version
  version="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$ROOT/apps/$dir/pom.xml" | head -1)"
  curl -fsS -o /dev/null -H "Authorization: Bearer $(token)" \
    "$API/exchange/api/v2/assets/$ANYPOINT_ORG_ID/$dir/$version" 2>/dev/null
}

# For mule-application packaging, `mvn deploy` publishes the jar to Exchange and
# `mvn deploy -DmuleDeploy` deploys it from Exchange to CloudHub 2.0: two separate runs.
deploy() { # app dir, extra -D flags...
  local dir="$1"; shift
  local flags=(-B -q -s "$work/settings.xml" -DskipTests -Danypoint.orgId="$ANYPOINT_ORG_ID"
    -Danypoint.clientId="$ANYPOINT_CLIENT_ID" -Danypoint.clientSecret="$ANYPOINT_CLIENT_SECRET"
    -Ddeploy.environment="$ENV_NAME" -Ddeploy.target="$TARGET" -Ddeploy.muleVersion="$MULE_VERSION")
  if published "$dir"; then
    echo "  $dir is already in Exchange at this version, deploying it"
  else
    (cd "$ROOT/apps/$dir" && "$MVN" "${flags[@]}" clean deploy)
  fi
  (cd "$ROOT/apps/$dir" && "$MVN" "${flags[@]}" deploy -DmuleDeploy "$@")
}

echo "Deploying sofa-orders-sapi to $TARGET ($ENV_NAME)..."
deploy sofa-orders-sapi -Dapi.key="$SAPI_KEY"
SAPI_URL="$(public_url sofa-orders-sapi)"
echo "  System API: $SAPI_URL"

echo "Deploying sofa-care-mcp..."
deploy sofa-care-mcp -Dsapi.host="${SAPI_URL#https://}" -Dsapi.key="$SAPI_KEY" -Dmcp.key="$MCP_KEY"
MCP_URL="$(public_url sofa-care-mcp)"
echo "  MCP server: $MCP_URL/mcp"
echo
echo "Next: SOFA_CARE_MCP_URL=$MCP_URL scripts/deploy-network.sh"
