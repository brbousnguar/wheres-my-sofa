# Where's my sofa?

![mule](https://img.shields.io/badge/Mule-4.12-00a0df)
![mcp](https://img.shields.io/badge/MCP%20Connector-1.7.2-1f6feb)
![agent fabric](https://img.shields.io/badge/Agent%20Fabric-Agent%20Network%202.0-032d60)
![a2a](https://img.shields.io/badge/A2A-v1.0-56616c)
![llm](https://img.shields.io/badge/LLM-gpt--5--mini%20%2B%20Claude%20Haiku%205.5%20via%20OpenRouter-6e40c9)

A customer-care agent for a made-to-order furniture shop, built the MuleSoft way: an
API-led System API, an MCP server in front of it, and an Agent Fabric broker that talks to
customers over A2A, behind Omni Gateway.

Furniture made to order is a good test for an agent. A sofa is sewn in a partner workshop
weeks after the order, so "where is my sofa?" means joining the order in the ERP, the supplier
order in the workshop, and the delivery booking. Customers also want to move deliveries and
report damage, and some of that must never be left to a model's judgment: whose order it is,
which slots are free, and that a delivery under 48 hours away can't move.

So the rules live in the System API, the model only classifies and phrases, and the graph
decides what happens. The shop, its products and its customers are invented.

## What it does

```
customer (A2A client) ──► Omni Gateway ──► Care Desk broker (Agent Script)
                          client ID,          │
                          rate limit,         ├─ understandRequest  generator, 1 LLM call, no tools
                          user context        ├─ intentRouter       deterministic
                                              ├─ orderStatus        find_orders, get_order
                                              ├─ listSlots          executor, list_delivery_slots, no LLM
                                              ├─ pickSlot           generator, 1 LLM call, no tools
                                              ├─ slotRouter         deterministic
                                              ├─ moveDelivery       executor, reschedule_delivery, no LLM
                                              └─ openComplaintCase  executor, open_care_case, no LLM
                                                       │ MCP (Streamable HTTP, x-api-key)
                                                       ▼
                                              sofa-care-mcp  (Mule, MCP Connector)
                                                       │ HTTPS, x-api-key
                                                       ▼
                                              sofa-orders-sapi  (Mule System API over a mock ERP)
```

A conversation goes like this (dates as of 16 October 2026; the data moves with today):

> **Camille:** Where is my sofa? camille.martin@example.com
>
> **Care Desk:** Your Lune 3-seater sofa in ivory bouclé is being upholstered in our Porto
> workshop. It should be ready on 13 November, two weeks later than planned, because the fabric
> reached the workshop late. We'll book the delivery as soon as it reaches our warehouse. Your
> Orbe coffee table was delivered on 16 September.

> **Julien:** Can you move the delivery of SO-24903 to a Saturday morning? julien.bernard@example.com
>
> **Care Desk:** Done: your two Pli armchairs now arrive on Saturday 24 October, between 8:00 and 12:00.

> **Léa:** Please push my delivery back, SO-24770, lea.dubois@example.com. I won't be home tomorrow.
>
> **Care Desk:** Your delivery is less than 48 hours away, so I can't move it online. I've opened
> case CARE-1001 for the care team in Bordeaux, and they'll get back to you within one business day.

Each path in the broker carries only the tools it needs:

| Node | Type | Tools | What it decides |
|---|---|---|---|
| `understandRequest` | generator | none | intent (`order_status`, `reschedule`, `complaint`, `other`), order number, email, category, summary, preferred slot |
| `intentRouter` | router | none | the path, and whether the order number and email are there, with no LLM |
| `orderStatus` | orchestrator | `find_orders`, `get_order` (email bound) | how to explain the order |
| `listSlots` | executor | `list_delivery_slots` (order and email bound) | nothing: fixed arguments, no LLM |
| `pickSlot` | generator | none | whether the order was found and can move, the one free slot that matches the request, or the slots to offer |
| `slotRouter` | router | none | not found, a care case (a delivery that can't move, every time), a choice, or the move |
| `moveDelivery` | executor | `reschedule_delivery` (order and email bound) | nothing: the picked slot, no LLM |
| `openComplaintCase`, `openDeliveryCase` | executor | `open_care_case` | nothing: fixed arguments, no LLM |
| `caseReply`, `movedReply` | generator | none | the wording of the confirmation |

The order number and email are bound to the tools by the graph (`with email = @generator...`),
so the model can pick a slot but can't point a tool at another order. And no model asks the
customer anything: "Which one suits you?" is a fixed reply from an echo node.

## Requirements

- JDK 17 and Maven 3.8+ (Anypoint Code Builder ships both).
- A Mule 4.12 EE runtime to run the apps locally (MCP Connector 1.7.2 fails to start on 4.9.6).
- For the cloud part: an Anypoint Platform organization with Agent Fabric, a CloudHub 2.0
  shared space and a managed Omni Gateway, plus a connected app (client credentials) with
  Runtime Manager, Exchange Contributor, API Manager and Gateway Manager permissions.
- The Agent Fabric CLI: `npm install mulesoft-anypoint-cli-agent-fabric-plugin`.
- An OpenRouter API key. Add your Anthropic key to OpenRouter as BYOK and the classifier's Claude
  calls are billed to your Anthropic account. Any other OpenAI-compatible Responses API works too:
  change the LLM connection `url` and the models in `care-desk.agent`.

## Run locally

Build both apps and drop them in a Mule runtime's `apps/` folder:

```bash
(cd apps/sofa-orders-sapi && mvn -DskipTests package)
(cd apps/sofa-care-mcp && mvn -DskipTests package)
cp apps/*/target/*-mule-application.jar "$MULE_HOME/apps/"
"$MULE_HOME/bin/mule" start
```

| App | Address | Key |
|---|---|---|
| sofa-orders-sapi | `http://localhost:8720/api` | `x-api-key: local-dev-key` |
| sofa-care-mcp | `http://localhost:8721/mcp` | `x-api-key: local-mcp-key` |

```bash
curl -H 'x-api-key: local-dev-key' 'localhost:8720/api/orders?email=camille.martin@example.com'
scripts/mcp-smoke.py http://localhost:8721/mcp local-mcp-key   # opens an MCP session, calls each tool
```

Any MCP client can use the server. For Claude Code:

```bash
claude mcp add --transport http sofa-care http://localhost:8721/mcp --header "x-api-key: local-mcp-key"
```

## Deploy

```bash
export ANYPOINT_CLIENT_ID=... ANYPOINT_CLIENT_SECRET=... ANYPOINT_ORG_ID=...
export SAPI_KEY=$(openssl rand -hex 24) MCP_KEY=$(openssl rand -hex 24) OPENROUTER_API_KEY=...

scripts/deploy-apps.sh                                       # both Mule apps to CloudHub 2.0
SETUP_GATEWAY=1 SOFA_CARE_MCP_URL=https://... scripts/deploy-network.sh   # gateway, publish, broker
```

On a trial organization, add `TRIAL=1` to the first `deploy-network.sh` run. The CLI's `setup
gateways` asks for a Large gateway with a 60 s upstream timeout and tracing on. A trial only has a
Small gateway and rejects both settings, so with `TRIAL=1` the script creates the gateway through
the Gateway Manager API instead, with a 15 s timeout and tracing off, and waits until Gateway
Manager lists it as `APPLIED` (a few minutes) before it deploys the broker. If a gateway with that
name already exists, the script uses it, so a run that stopped after the gateway step can be run
again as is.

The connected app needs these permissions in the target environment, and two on the business group:

| Product | Permissions |
| --- | --- |
| Exchange | Exchange Contributor |
| Runtime Manager / CloudHub 2.0 | Create Applications, Read Servers, Manage Servers; on the business group, Read Runtime Fabrics and CloudHub Network Viewer |
| API Manager | Manage APIs Configuration, Manage Policies, Deploy API Proxies |

The Agent Fabric docs list only the last two API Manager permissions, but the deploy creates one
API instance for the broker and one for each connection, and that needs Manage APIs Configuration.
Without it the deploy fails with `Error while trying to create '[MCP Server] ...' in API Manager`.

The two business-group permissions are for the Maven deploy. The Mule Maven plugin finds the
CloudHub 2.0 target by listing every deployment target, Runtime Fabrics and private spaces
included. Without them `deploy-apps.sh` publishes to Exchange, then fails with `403 Forbidden:
Request failed. Response status code is 401`. Scopes count only once the connected app's page is
saved with **Save changes**.

`deploy-network.sh` copies `agent-network/` to `.build/` (the CLI refuses paths under
`/private`, where macOS keeps temporary folders), writes your organization ID
into `exchange.json`, then runs `agent-network project build`, `publish` and `deploy` with the
MCP URL and both keys as `--property` values. Nothing secret is committed.

`deploy-apps.sh` skips the Exchange publish when Exchange already has the app's version, so bump
the version in the app's `pom.xml` before deploying a code change.

To call the broker, create a client application in Exchange with access to the Care Desk API
instance, then:

```bash
BROKER_URL=https://<gateway>/<broker-path> CLIENT_ID=... CLIENT_SECRET=... scripts/ask.py
```

`ask.py` reuses the `contextId` the broker returns, so follow-ups like "Saturday morning then"
continue the same conversation.

## Move to a new organization

A trial org lasts 30 days. Nothing the demo needs lives only in the org: the apps, the network,
its policies and the demo data are all in this repo, and the System API seeds its orders from
`data/orders.json` with dates relative to the day it starts. So a new org (a new trial, say)
gets the same demo, built the same way:

1. In the new org, on its Sandbox environment, create a connected app (client credentials) with
   the permissions above. Export its ID and secret and the new organization ID.
2. Keep `SAPI_KEY`, `MCP_KEY` and `OPENROUTER_API_KEY` from the old deploy, or make new keys.
3. Deploy the apps, then the network, which creates the gateway on the way:
   ```bash
   scripts/deploy-apps.sh
   SETUP_GATEWAY=1 TRIAL=1 SOFA_CARE_MCP_URL=<the URL deploy-apps.sh printed> scripts/deploy-network.sh
   ```
4. In Exchange, create a client application and request access to the Care Desk API instance:
   its client ID and secret, and the broker's URL on the gateway, go to `ask.py`, `eval.py` and
   the demo page. This is the one step done in the browser.
5. Run `scripts/eval.py`: the eight scenarios should pass again.

Before an org expires, `scripts/export-org.py <out-dir>` saves how it is set up, read-only: the
CloudHub 2.0 apps and their settings, the gateway, each API Manager instance with its inbound and
outbound policies and upstreams, the Exchange assets, and the System API's current orders and
cases. Secret values come out as `<redacted>`, but the files still carry the org's name and IDs,
so keep `<out-dir>` outside this repo. Compare a new org's export with the old one to check
nothing was missed.

## Evaluate

```bash
BROKER_URL=... CLIENT_ID=... CLIENT_SECRET=... SAPI_URL=https://<sofa-orders-sapi> SAPI_KEY=... scripts/eval.py
```

`eval.py` sends eight customer messages to the broker. Before and after each one it snapshots
every order's delivery slot and the care cases in the System API. A scenario passes when the
system of record changed the way it should, and nothing else changed:

| Scenario | Passes when |
|---|---|
| Order status from the email alone | nothing changes, and the reply gives the 14-day workshop delay |
| Vague request ("I want to move my delivery") | nothing changes, and the reply asks for the order number |
| Move a delivery to "another morning" | nothing changes, and the reply lists the free mornings |
| Move a delivery to a named morning | only SO-24903 moves, to that exact slot, and no case is opened |
| Move a delivery inside 48 hours | nothing moves, and one DELIVERY case is opened for SO-24770 |
| Damage on delivery | one DAMAGE case for SO-24655, and the reply quotes its number |
| Someone else's order, with a prompt injection | nothing changes |
| Product question | nothing changes |

The checks compare snapshots, so the suite runs again on the same deployment. Set
`EVAL_JSON=results.json` to keep the replies and timings. On 18 October 2026 the deployed broker
passed all eight, with replies in 3.5 to 15 seconds. On 21 October, with the classifier on Claude
Haiku 5.5, it passed all eight in three runs in a row, with replies in 2.2 to 16.6 seconds.

## Demo page

```bash
BROKER_URL=... CLIENT_ID=... CLIENT_SECRET=... SAPI_URL=https://<sofa-orders-sapi> SAPI_KEY=... demo/server.py
```

`demo/server.py` serves a page with the chat on the left and the System API's own data on the
right: each demo order's delivery slot, the care cases, and what the last message changed. The
page talks only to that server, which holds the credentials, forwards each message to the broker
over A2A and reads the System API after every reply. It listens on `127.0.0.1`, on `DEMO_PORT`
or a free port, and prints the address. Restart the System API first for a clean demo.

## System API

All routes need `x-api-key`. A wrong email gets the same 404 as a missing order, so the API
never confirms that an order number exists.

| Route | Does |
|---|---|
| `GET /api/health` | liveness |
| `GET /api/orders?email=` | a customer's orders, newest first |
| `GET /api/orders/{orderId}?email=` | one order: lines, workshop production (stages, promised and estimated ready dates, delay and reason), delivery |
| `GET /api/orders/{orderId}/delivery-slots?email=` | current slot and free slots; 409 if nothing is booked or the slot is under 48 hours away |
| `PUT /api/orders/{orderId}/delivery` `{email, slotId}` | moves the delivery; 409 if the slot isn't free |
| `POST /api/cases` `{orderId, email, category, summary}` | opens a care case (`DAMAGE`, `DELAY`, `DELIVERY`, `OTHER`), 201 with `CARE-100x` |
| `GET /api/cases` | the cases opened since the app started |

Dates in `data/orders.json` are day offsets from today, so the demo never goes stale.
Rebookings and cases live in an in-memory object store: a restart resets the demo.

## MCP tools

| Tool | Arguments | Calls |
|---|---|---|
| `find_orders` | `email` | `GET /orders` |
| `get_order` | `orderId`, `email` | `GET /orders/{orderId}` |
| `list_delivery_slots` | `orderId`, `email` | `GET /orders/{orderId}/delivery-slots` |
| `reschedule_delivery` | `orderId`, `email`, `slotId` | `PUT /orders/{orderId}/delivery` |
| `open_care_case` | `orderId`, `email`, `category`, `summary` | `POST /cases` |

A System API error becomes a tool error carrying the API's own message ("No order with that
number for that email."), so the agent can relay it. A new MCP session without the right
`x-api-key` is rejected with 401 in `mcp:on-new-session-listener`.

## Demo data

| Order | Customer | Story |
|---|---|---|
| SO-24817 | camille.martin@example.com | Lune sofa in upholstery, 14 days late (fabric arrived late); coffee table delivered |
| SO-25012 | camille.martin@example.com | Halo bench, confirmed, not started |
| SO-24903 | julien.bernard@example.com | 2 Pli armchairs, delivery booked in 5 days, 4 free slots |
| SO-24770 | lea.dubois@example.com | Nuage bed, delivery tomorrow afternoon: can't move online |
| SO-24655 | sofia.rossi@example.com | Halo table delivered a week ago: the complaint path |

## Tech stack

- Mule 4.12, HTTP Connector 1.11, Object Store Connector 1.2, DataWeave 2.
- MuleSoft MCP Connector 1.7.2 (Streamable HTTP server, JSON responses).
- Agent Fabric Agent Network 2.0: `agent-network.yaml`, Agent Script (`AGENTFABRIC=1.2`),
  Omni Gateway policies (client ID enforcement, rate limiting, user context propagation).
- A2A v1.0 (JSON-RPC `SendMessage`).
- `anthropic/claude-haiku-5.5` for the classifier and `openai/gpt-5-mini` for the other LLM nodes,
  both with low reasoning effort, through OpenRouter's Responses API.

Why only the classifier runs on Claude: Agent Fabric starts each LLM node after the first in a
turn on a history that ends with the previous node's answer, an assistant turn. Claude refuses a
conversation that ends that way: Claude 5 models always, earlier ones when the output must follow
a schema. With `anthropic/claude-haiku-5.5` on the other nodes too (21 October 2026), the
classifier worked, and `orderStatus`, `pickSlot` and `caseReply` failed with a 400 ("This model
does not support assistant message prefill"). The classifier is the first LLM call of a turn, so
its history ends on the customer's message.

## Repository layout

```
apps/
  sofa-orders-sapi/        System API: flows in src/main/mule, rules in src/main/resources/dw/sofa.dwl,
                           data in src/main/resources/data/orders.json
  sofa-care-mcp/           MCP server: global.xml (server, session auth), tools.xml (5 tools)
agent-network/
  agent-network.yaml       registry (MCP server, LLM), connections, policies, the broker and its card
  brokers/care-desk.agent  the Agent Script graph
  exchange.json            asset descriptor, deploy-time variables, policy dependencies
demo/
  server.py, index.html    local demo page: the chat next to the System API's data
scripts/
  deploy-apps.sh           CloudHub 2.0 deploy of both apps
  deploy-network.sh        build, publish and deploy the agent network
  ask.py                   terminal A2A client
  eval.py                  end-to-end eval, checked against the System API
  export-org.py            read-only export of an org's setup, before it expires
  mcp-smoke.py             MCP session check
```

## Notes

- The customer's email comes from their message, which is fine for a demo. In production the
  broker would take it from the authenticated caller (a JWT validated at the gateway, then
  `@request.headers`), and the email check in the System API would be a real authorization.
- The broker's inbound policies run in order: client ID enforcement, then rate limiting
  (60 requests an hour per client, to cap LLM spend), then user context propagation. The last
  one gives each caller an identity, which is what the broker keys conversation memory on.
- `agent-network project build` validates the Agent Script graph locally, including the rule
  that every path ends in a terminal task state.
- Agent Fabric runs generator and orchestrator nodes with human-in-the-loop: the model can decide
  it needs more input and end the task in `TASK_STATE_INPUT_REQUIRED`, and its reasoning then
  comes back as the reply. Classifying a vague message ("I want to move my delivery") did that,
  and so did any node that had to put a question to the customer: an orchestrator deciding the
  customer had a choice to make, and then a generator that only wrote the list of free slots.
  What stopped it: the router, not the model, checks that the order number and email are there;
  the message reaches the model quoted, as data, and its instructions say its goal is complete
  once the fields are filled; and every question to the customer is a fixed echo reply, so the
  model only fills fields and never writes one. Telling the model never to ask the customer made
  it worse. On gpt-5-mini the classifier still did it with the vague message about one run in
  three. On Claude Haiku 5.5 that message passed five runs out of five.
- MCP Connector 1.6 held an SSE stream open for every response. Behind Omni Gateway the broker's
  tool discovery then timed out, and a tool missed at discovery stays missing until the broker
  restarts. 1.7 answers with one JSON body. It needs Mule 4.12: 1.7.2 fails to start on 4.9.6.
- Status: deployed on CloudHub 2.0 in a trial organization, both Mule apps and the broker behind
  a Small Omni Gateway, and `eval.py` passes against it.
