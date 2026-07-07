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
- **CLI invocation**: The subagent runs `codex --help` and `codex exec --help` to discover current syntax, then invokes Codex in non-interactive/full-auto mode. Do not hardcode flags — CLI syntax changes between versions.
- **MCP fallback**: `mcp__codex__codex` tool with delegation prompt as message
- **Round 2 (CLI)**: Fresh CLI call with full context + synthesis (no thread state)
- **Round 2 (MCP)**: `mcp__codex__codex-reply` with `threadId` from Round 1
- **Env requirements**: OpenAI API key (configured via `codex login`)

### Antigravity (Google) — preferred Google-family reviewer

Google's successor to the Gemini CLI (binary `agy`). See the **Google-family reviewer** rule below — when both `agy` and `gemini` are installed, `agy` is tried first and `gemini` is the fallback; together they occupy a single reviewer slot.

- **Detection**: `which agy 2>/dev/null` — if found, use CLI. (No MCP transport exists for Antigravity.)
- **CLI invocation**: The subagent runs `agy --help` to discover current syntax, then invokes Antigravity in non-interactive mode with text output. Do not hardcode flags — CLI syntax changes between versions. Hint verified against agy 1.0.16: `agy -p "<prompt>"` (`-p`/`--print` = run a single prompt non-interactively and print the response). Optional: `--add-dir <repo>` to include the repo in the workspace, `--model <name>` to select a model, `--dangerously-skip-permissions` to avoid blocking on an approval it can't receive in a non-TTY. Print mode has a built-in `--print-timeout` (default 5m) — for reviews budgeted above 5m (the default `RC_REVIEWER_TIMEOUT` is 10m), pass `--print-timeout` to match (e.g. `--print-timeout 10m`) or agy will cut off first.
- **Round 2**: Fresh CLI call with full context + synthesis
- **Env requirements**: Authenticated `agy` session — Google account sign-in (Google One AI plans) or enterprise Gemini Enterprise Agent Platform (a Google Cloud project). Install: `curl -fsSL https://antigravity.google/cli/install.sh | bash`. Config lives under `~/.gemini/antigravity-cli/`.

### Gemini (Google) — fallback

Backward-compatible Google reviewer. Note: Gemini CLI's consumer "Sign in with Google" (Gemini Code Assist for individuals, and AI Pro/Ultra) was sunset **2026-06-18** — those sessions now fail with *"no longer supported for Gemini Code Assist for individuals… migrate to the Antigravity suite."* Gemini CLI still works when authenticated via a `GEMINI_API_KEY`, Vertex AI, or an enterprise Gemini Code Assist license. **Prefer Antigravity (`agy`) when both are installed.**

- **Detection**: `which gemini 2>/dev/null` — if found, use CLI. (No usable Gemini text-gen MCP exists; the Google-family fallback is `agy → gemini` at the CLI level, not MCP.)
- **CLI invocation**: The subagent runs `gemini --help` to discover current syntax, then invokes Gemini in non-interactive mode with text output. Do not hardcode flags — CLI syntax changes between versions. For headless/non-TTY runs, Gemini may refuse an untrusted workspace — pass `--skip-trust` or set `GEMINI_CLI_TRUST_WORKSPACE=true`.
- **Round 2**: Fresh CLI call with full context + synthesis
- **Env requirements**: `GEMINI_API_KEY` (or Vertex AI / enterprise Code Assist credentials). Consumer OAuth via `gemini login` is no longer served.

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
3. Report header shows availability: `Reviewers: Claude, Codex, Google (Antigravity) (3 participating — Perplexity: PERPLEXITY_API_KEY not set)`
4. Transport fallback: CLI first, then MCP, then skip
5. Never block a review because a provider is unavailable

### Google-family reviewer (Antigravity + Gemini)

`agy` (Antigravity) and `gemini` run the same Gemini model family, so they share **one** reviewer slot — never dispatch both as separate votes (it would skew convergence). Resolve the slot at detection time:

- Both installed → try `agy` first, fall back to `gemini` if `agy` is absent, fast-fails, **or returns empty/malformed output** (e.g. `agy -p` exiting 0 with no stdout in a non-TTY). Counts as **one** reviewer.
- Only one installed → use it.
- Neither → the Google slot is unavailable; note it in the report.

Label the result by the tool that produced it — **Antigravity** or **Gemini**.

## Adding a New Provider

Add a new section above with: Detection, CLI invocation, MCP fallback, Round 2 handling, Env requirements. Then update `skills/run/SKILL.md` to include it in the parallel dispatch.
