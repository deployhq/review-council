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

- **Detection**: probe `command -v agy` first, then — if empty — the common install dirs, since a minimal `PATH` may omit them. Use the **same probe as the `run`/`setup` skills** (keep all three in sync — don't let this one drift narrower):
  ```bash
  AGY="$(command -v agy 2>/dev/null || true)"
  if [ -z "$AGY" ]; then
    for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
      [ -x "$d/agy" ] && { AGY="$d/agy"; break; }
    done
  fi
  ```
  **`agy` must be probed explicitly and preferred — never default the Google slot to `gemini` without checking `agy` first.** Invoke by the resolved full path (`$AGY`) so a `PATH` gap doesn't make a present `agy` look absent. (No MCP transport exists for Antigravity.)
- **CLI invocation**: The subagent runs `agy --help` to discover current syntax, then invokes Antigravity in non-interactive mode with text output. Do not hardcode flags — CLI syntax changes between versions. Hint verified against agy 1.0.16–1.1.0: `agy -p "<prompt>"` (`-p`/`--print` = run a single prompt non-interactively and print the response). Optional: `--add-dir <repo>` to include the repo in the workspace, `--model <name>` to select a model, `--dangerously-skip-permissions` to avoid blocking on an approval it can't receive in a non-TTY.
- **Cold start**: `agy`'s **first** `-p` call in a session is slow (model load, auth handshake, update check) — it can take **several minutes**, versus ~10s once warm; occasionally it exits 0 with no stdout. Give it real headroom, or a cold start looks like a failure: the invocation is capped **twice** and both caps must cover the budget — the outer wrapper (`${RC_REVIEWER_TIMEOUT:-600}`, 10m default) **and** agy's own `--print-timeout`, which defaults to just **5m**. You MUST pass `--print-timeout` sized to the budget — but its value is a **Go duration string and requires a unit suffix**: a bare integer is rejected (`agy --print-timeout 600` exits 2 with `missing unit in duration "600"`). Since `RC_REVIEWER_TIMEOUT` is in **seconds**, append `s`: `--print-timeout "${RC_REVIEWER_TIMEOUT:-600}s"` (or a literal like `10m`). Set it equal to — or a touch below — the outer wrapper so agy trips on its own first and prints an attributable timeout message instead of being SIGTERM-ed. Without it agy self-limits at 5m and cuts off a slow cold start first. Treat multi-minute first-call latency as normal, not a hang. The empty-output quirk is handled by the retry-then-fallback policy below.
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

`agy` (Antigravity) and `gemini` run the same Gemini model family, so they share **one** reviewer slot — never dispatch both as separate votes (it would skew convergence). **`agy` is the primary Google reviewer whenever it is installed; `gemini` is only a last-resort fallback.** Resolve the slot at detection time:

- **`agy` installed** (with or without `gemini`) → the slot is **Google (Antigravity)** — `agy` primary, `gemini` fallback only. Announce and label it **Google (Antigravity)**, never "Gemini", even before invocation — `agy` is what will actually run.
- Only `gemini` installed → use `gemini`; announce as **Google (Gemini)**.
- Neither → the Google slot is unavailable; note it in the report.

**Invocation policy when `agy` is primary** (the order matters — a transient `agy` blip must not be masked by a `gemini` that cannot succeed):

1. Run `agy`. If it returns a valid non-empty review, use it. Done.
2. If `agy` returns **empty or malformed output** — the known `agy -p` quirk of exiting **0 with no stdout** in a non-TTY, usually a cold-start artifact — **retry `agy` once, but only if that empty result came back *quickly*** (rule of thumb: under ~⅓ of the budget). Time-box the retry to the **remaining** budget, not a fresh `RC_REVIEWER_TIMEOUT`, so first-try + retry can never exceed one budget. The warm retry almost always returns a valid review. Do not go to `gemini` yet.
3. Fall back to `gemini` only when `agy` cannot be salvaged: `agy` is **absent**, **hard-fails** (auth/quota — retrying won't help), **times out**, its empty result arrived **near the cap** (a slow-but-completed empty call — treat it like a timeout; do not retry, or you nearly double the wall-clock), or its **step-2 retry also returns empty/malformed**. The slot's outcome is then terminal for the round (not eligible for external reviewer-level retry).

**`gemini` is a dead fallback for Workspace/Dasher accounts.** `gemini -p` fast-fails almost instantly with `IneligibleTierError` (`reasonCode: DASHER_USER`, "not eligible for Gemini Code Assist for individuals") for any Google **Workspace**-domain account, and for any account without a `GEMINI_API_KEY` / Vertex / enterprise Code Assist license. For those users the fallback **cannot** succeed — that is expected, not a misconfiguration. When it fails this way, report the slot honestly attributed to its **primary** tool — e.g. *"Google (Antigravity) — agy returned empty output after retry; Gemini fallback ineligible (Workspace/Dasher account). Slot skipped."* — **never** as a bare "Gemini auth failure," which hides that `agy` was the real reviewer and misleads a user whose `agy` works fine interactively.

Label a successful result by the tool that produced it — **Antigravity** or **Gemini**.

## Adding a New Provider

Add a new section above with: Detection, CLI invocation, MCP fallback, Round 2 handling, Env requirements. Then update `skills/run/SKILL.md` to include it in the parallel dispatch.
