### Added
- `scripts/eval.py`: eight customer messages against the deployed broker, each checked against the System API's slots and cases before and after (#3)
- `demo/server.py`: a local demo page with the chat next to the System API's own data (#3)

### Changed
- The broker decides what's missing in its router, quotes the customer's message to the model as data, reads free slots from an executor and asks every question to the customer from a fixed echo reply, so the model only fills fields and no longer ends a task to wait for input and sends its reasoning as the reply (#3)
- sofa-care-mcp runs on MCP Connector 1.7 and Mule 4.12, which answer with one JSON body instead of an SSE stream; tool discovery behind Omni Gateway timed out on 1.6 (#3)

### Fixed
- Deploy scripts publish before deploying to CloudHub 2.0, size the Omni Gateway for a trial org and pass every network variable (#3)
