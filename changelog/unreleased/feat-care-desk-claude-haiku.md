### Changed
- The classifier (`understandRequest`) runs on `anthropic/claude-haiku-5.5` through OpenRouter. With an Anthropic key added to OpenRouter as BYOK, its calls are billed to that Anthropic account. The vague-request scenario passed five runs out of five on it, where gpt-5-mini ended about one run in three in `TASK_STATE_INPUT_REQUIRED` (#9)

### Added
- README and `care-desk.agent`: why the other LLM nodes stay on `openai/gpt-5-mini`. Agent Fabric starts each LLM node after the first in a turn on an assistant turn, and Claude models refuse that (#9)
