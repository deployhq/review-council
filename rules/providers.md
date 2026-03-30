# Provider Registry

Reference for the orchestrator. At runtime, probe each provider in order. Available providers join the reviewer pool.

## Detection & Invocation

### Claude (native subagent)

- **Detection**: Always available
- **Invocation**: `Agent` tool with `subagent_type: "reviewer-claude"`
- **Round 2**: New `Agent` spawn with Round 1 synthesis included
- **Env requirements**: None

### Codex (OpenAI)

- **Detection**:
  1. CLI: `which codex 2>/dev/null` — if found, use CLI
  2. MCP fallback: `mcp__codex__codex` tool — if available, use MCP
  3. Neither — skip, note in report
- **CLI invocation**: Write the delegation prompt to a temp file, then:
  ```bash
  codex exec --full-auto -q "$(cat /tmp/rc-review-prompt.md)"
  ```
- **MCP fallback**: `mcp__codex__codex` tool with delegation prompt as message
- **Round 2 (CLI)**: Fresh `codex exec` call with full context + synthesis (no thread state)
- **Round 2 (MCP)**: `mcp__codex__codex-reply` with `threadId` from Round 1
- **Env requirements**: OpenAI API key (configured via `codex login`)

### Gemini (Google)

- **Detection**:
  1. CLI: `which gemini 2>/dev/null` — if found, use CLI
  2. MCP fallback: Gemini MCP tool if configured
  3. Neither — skip, note in report
- **CLI invocation**: Write the delegation prompt to a temp file, then:
  ```bash
  gemini -p "$(cat /tmp/rc-review-prompt.md)" -o text
  ```
- **MCP fallback**: Gemini MCP tool if configured in user's environment
- **Round 2**: Fresh CLI call with full context + synthesis
- **Env requirements**: Google API key (configured via `gemini login` or `GEMINI_API_KEY` env var)

### Perplexity (Sonar API)

- **Detection**: `PERPLEXITY_API_KEY` env var is set and non-empty
- **CLI invocation**: `curl` POST to Sonar API:
  ```bash
  curl -s https://api.perplexity.ai/v1/chat/completions \
    -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "sonar",
      "messages": [{"role": "user", "content": "DELEGATION_PROMPT_HERE"}]
    }'
  ```
  Parse the response: `.choices[0].message.content`
- **MCP fallback**: None
- **Round 2**: Fresh curl call with full context + synthesis
- **Env requirements**: `PERPLEXITY_API_KEY` env var

## Runtime Rules

1. Probe all providers at review start
2. Minimum 2 available for convergence mode; 1 = single-reviewer mode
3. Report header shows availability: `Reviewers: Claude, Codex, Gemini (3 participating — Perplexity: PERPLEXITY_API_KEY not set)`
4. Transport fallback: CLI first, then MCP, then skip
5. Never block a review because a provider is unavailable

## Adding a New Provider

Add a new section above with: Detection, CLI invocation, MCP fallback, Round 2 handling, Env requirements. Then update `skills/run/SKILL.md` to include it in the parallel dispatch.
