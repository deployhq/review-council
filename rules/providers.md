# Provider Registry

Reference for the orchestrator. At runtime, probe each provider in order. Available providers join the reviewer pool.

## Detection & Invocation

### Claude (native subagent)

- **Detection**: Always available
- **Invocation**: `Agent` tool with `subagent_type: "reviewer-claude"`
- **Env requirements**: None

### Codex (OpenAI)

- **Detection**:
  1. CLI: `which codex 2>/dev/null` — if found, use CLI
  2. MCP fallback: `mcp__codex__codex` tool — if available, use MCP
  3. Neither — skip, note in report
- **CLI invocation**: dispatch goes through the tested state machine `scripts/rc-invoke-provider.sh` — the script, not the calling subagent, owns dispatch:
  ```bash
  RC_REVIEWER_TIMEOUT=<effective settings.reviewer_timeout_seconds> \
    scripts/rc-invoke-provider.sh "<codex-path>" "" "<prompt-file>"
  ```
  One call = one result. Codex has no CLI fallback, so the fallback positional is always `""`. The script owns:
  - **Binary resolution** — `resolve_bin()` re-validates the path Step 0.2 detected: a PATH-findable name via `command -v`, or (when detection resolved an off-`PATH` absolute path) a direct executable check — so it works whether `codex` sits on `PATH` or not.
  - **The frozen argv**: `codex exec --sandbox read-only --skip-git-repo-check <prompt>`. `exec` is the non-interactive subcommand (plain `codex` would hang forever with no TTY, and `exec` has no approval prompt to bypass); the prompt is a **positional** argument, not `-p` (which means `--profile` for `codex exec`, unlike agy/gemini); `--sandbox read-only` is least-privilege (the model's shell commands can read the repo but cannot write or reach the network — sufficient for a reviewer, and deliberately not `--dangerously-bypass-approvals-and-sandbox`); `--skip-git-repo-check` lets the run proceed outside a git repo.
  - **The hard timeout cap** — `RC_REVIEWER_TIMEOUT` (default 600s), enforced by a TERM-then-KILL escalation (`run_capped` / `KILL_GRACE`, shared via `scripts/rc-lib-timeout.sh`).
  - **Fast-fail classification** — auth/quota/overload patterns are checked, but only *after* confirming the output isn't a valid result: a heading-anchored `Findings` + `Overall Assessment` review, or (for Step-4 refutation calls) a `<finding-id> | UPHELD/REFUTED/INCONCLUSIVE` verdict line. That ordering means a genuine review that happens to discuss "login" or "429" is never misclassified as a failure.
  - **No retry** — the one fast-empty retry is `agy`-only (see the Google-family reviewer rule below); a Codex attempt that comes back absent/timed-out/empty/auth/quota/overload is terminal for the slot, reported as a single `SKIPPED: Codex unavailable — codex: <reason>` line.
  The **one** thing the script can't do is call an MCP tool — that fallback stays in the orchestrator's subagent: on a **soft** `SKIPPED` reason (`timed out` or `empty output`), try `mcp__codex__codex` once; on a **hard** reason (`auth failure`, `quota exhausted`, `overloaded`), skip MCP too — retrying a dead auth/quota/overload won't help.
- **MCP fallback**: `mcp__codex__codex` tool with delegation prompt as message — used directly, without the script, when Codex is MCP-only (`codex=none` at detection but the tool is available), or as the one soft-skip retry described above.
- **Probe mode**: `scripts/rc-invoke-provider.sh --probe "<codex-path>" ""` — opt-in Step-0 health check (`settings.health_probe`, default off), a trivial 1-token prompt under a short cap (`RC_HEALTH_PROBE_TIMEOUT`, default 20s), verdict `HEALTHY` / `UNHEALTHY: <reason>` / `INCONCLUSIVE`. Fail-open: only positive auth/quota/overload evidence drops the slot; a timeout or empty response never does.
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
  **`agy` must be probed explicitly and preferred — never default the Google slot to `gemini` without checking `agy` first.** Pass the resolved full path (`$AGY`) to `scripts/rc-invoke-provider.sh` so a `PATH` gap doesn't make a present `agy` look absent — the script's `resolve_bin()` accepts either a `PATH`-findable name or an off-`PATH` executable path. (No MCP transport exists for Antigravity.)
- **CLI invocation**: dispatch goes through `scripts/rc-invoke-provider.sh "<agy-path>" "<gemini-path-or-empty>" "<prompt-file>"` — one call, one result; the script owns the full retry/fallback state machine (see **Google-family reviewer** below). The frozen argv is:
  ```bash
  agy -p "<prompt>" --print-timeout "<cap>s" --dangerously-skip-permissions [--add-dir <RC_GOOGLE_ADD_DIR>] [--model <RC_GOOGLE_MODEL>]
  ```
  `--dangerously-skip-permissions` is **unconditional** — always appended, not optional — because a non-interactive run has no TTY to answer an approval prompt it can't receive. `--print-timeout` is sized to that invocation's own cap (the primary's full `RC_REVIEWER_TIMEOUT`, or the retry's time-boxed remaining budget) and **must** carry its unit suffix: agy's flag takes a Go duration string, and a bare integer (`--print-timeout 600`) is rejected with `missing unit in duration "600"` — the script always appends `s` (`"${cap}s"`). `--add-dir` / `--model` are appended only when `RC_GOOGLE_ADD_DIR` / `RC_GOOGLE_MODEL` are set. Success is validated the same way as Codex above (heading-anchored `Findings`/`Overall Assessment`, or a refutation verdict line) before any auth/quota/overload pattern is checked.
- **Cold start**: `agy`'s **first** `-p` call in a session is slow (model load, auth handshake, update check) — it can take **several minutes** versus ~10s once warm, and it occasionally exits 0 with no stdout. This is now handled automatically by the script's fast-empty retry (see **Google-family reviewer** below) rather than being something the calling subagent has to reason about — treat multi-minute first-call latency as normal, not a hang.
- **Probe mode**: `scripts/rc-invoke-provider.sh --probe "<agy-path>" "<gemini-path-or-empty>"` — opt-in Step-0 health check (`settings.health_probe`, default off), reusing the same frozen argv and hard-fail patterns under a short cap (`RC_HEALTH_PROBE_TIMEOUT`, default 20s); a probe treats any clean, non-empty exit-0 response as alive (it doesn't require review-shaped headings, since the probe prompt is a trivial "ping"). Slot verdict is `HEALTHY` iff either `agy` or `gemini` probes healthy; `UNHEALTHY: <reason>` only if **both** give positive hard-fail evidence; otherwise `INCONCLUSIVE` (fail-open — a cold/slow provider is never dropped).
- **Env requirements**: Authenticated `agy` session — Google account sign-in (Google One AI plans) or enterprise Gemini Enterprise Agent Platform (a Google Cloud project). Install: `curl -fsSL https://antigravity.google/cli/install.sh | bash`. Config lives under `~/.gemini/antigravity-cli/`.

### Gemini (Google) — fallback

Backward-compatible Google reviewer. Note: Gemini CLI's consumer "Sign in with Google" (Gemini Code Assist for individuals, and AI Pro/Ultra) was sunset **2026-06-18** — those sessions now fail with *"no longer supported for Gemini Code Assist for individuals… migrate to the Antigravity suite."* Gemini CLI still works when authenticated via a `GEMINI_API_KEY`, Vertex AI, or an enterprise Gemini Code Assist license. **Prefer Antigravity (`agy`) when both are installed.**

- **Detection**: `which gemini 2>/dev/null` — if found, use CLI. (No usable Gemini text-gen MCP exists; the Google-family fallback is `agy → gemini` at the CLI level, not MCP.)
- **CLI invocation**: never dispatched directly — it is always the **fallback positional** to `scripts/rc-invoke-provider.sh` (or, on a `gemini`-only slot, the **primary** positional with `""` as the fallback). The frozen argv is `gemini -p "<prompt>" --skip-trust` (`--skip-trust` avoids Gemini refusing an untrusted workspace on a headless/non-TTY run). As a fallback it gets a **fresh, full `RC_REVIEWER_TIMEOUT` budget** — never the `agy` retry's time-boxed remainder — and is **never retried itself**.
- **Env requirements**: `GEMINI_API_KEY` (or Vertex AI / enterprise Code Assist credentials). Consumer OAuth via `gemini login` is no longer served.

### Perplexity (Sonar API)

- **Detection**: `PERPLEXITY_API_KEY` env var is set and non-empty
- **CLI invocation**: `curl` POST to Sonar API — **not** routed through `scripts/rc-invoke-provider.sh` (that script is CLI-only: a binary to resolve plus an exit-code/stderr failure taxonomy; Perplexity is an HTTP API with an HTTP-status failure taxonomy, so it keeps its own inline `curl` path):
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
- **Env requirements**: `PERPLEXITY_API_KEY` env var

## Runtime Rules

1. Detection runs for every provider at review start (installed vs. not — see each provider's Detection above). A separate, **opt-in** Step-0 health probe (`settings.health_probe`, default off) further live-checks the Codex and Google slots via `scripts/rc-invoke-provider.sh --probe` before roster assembly — see each provider's Probe mode above. Claude and the dedicated Security reviewer are native-always and never probed; Perplexity has no probe binary (it's a curl-only API).
2. Minimum 2 available for council mode; 1 = single-reviewer mode
3. Report header shows availability: `Reviewers: Claude, Codex, Google (Antigravity) (3 participating — Perplexity: PERPLEXITY_API_KEY not set)`
4. **Dispatch transport**: Codex and the Google slot dispatch through `scripts/rc-invoke-provider.sh` (one call = one result) for both the Round-1 review and Step-4 refutation verdicts. Perplexity (curl-only Sonar API) and the native Claude/Security subagents do **not** go through the script.
5. Transport fallback (Codex only): CLI first, then MCP, then skip
6. Never block a review because a provider is unavailable

### Google-family reviewer (Antigravity + Gemini)

`agy` (Antigravity) and `gemini` run the same Gemini model family, so they share **one** reviewer slot — never dispatch both as separate votes (it would skew convergence). **`agy` is the primary Google reviewer whenever it is installed; `gemini` is only a last-resort fallback.** Resolve the slot at detection time:

- **`agy` installed** (with or without `gemini`) → the slot is **Google (Antigravity)** — `agy` primary, `gemini` fallback only. Announce and label it **Google (Antigravity)**, never "Gemini", even before invocation — `agy` is what will actually run.
- Only `gemini` installed → use `gemini`; announce as **Google (Gemini)**.
- Neither → the Google slot is unavailable; note it in the report.

The retry/fallback state machine itself lives in `scripts/rc-invoke-provider.sh` (one call, one result — see the Antigravity section above for its argv). The policy it enforces, in order (the order matters — a transient `agy` blip must not be masked by a `gemini` that cannot succeed):

1. **Run `agy`** with a fresh, full `RC_REVIEWER_TIMEOUT` budget. If it returns a valid non-empty review, that's the result. Done.
2. **If `agy` returns empty or malformed output *quickly*** (elapsed under ⅓ of the budget — the known cold-start quirk of exiting 0 with no stdout), **retry `agy` once**, time-boxed to the **remaining** budget (`budget - spent`), never a fresh `RC_REVIEWER_TIMEOUT` — so first-try + retry can never exceed one budget. The warm retry almost always returns a valid review. Do not fall to `gemini` yet.
3. **Fall back to `gemini`** — with its own **fresh, full** budget (not the remainder) and **no retry of its own** — when `agy` cannot be salvaged: it's **absent**, **hard-fails** (auth/quota/overload — retrying won't help), **times out**, its empty result arrived **near the cap** (a slow-but-completed empty call is treated like a timeout, not retried), or its step-2 retry **also** comes back empty/malformed. Whatever `gemini` returns (or fails to) is then **terminal for the slot** — not eligible for the Step 3.5 reviewer-level retry.

**`gemini` is a dead fallback for Workspace/Dasher accounts.** `gemini -p` fast-fails almost instantly with `IneligibleTierError` (`reasonCode: DASHER_USER`, "not eligible for Gemini Code Assist for individuals") for any Google **Workspace**-domain account, and for any account without a `GEMINI_API_KEY` / Vertex / enterprise Code Assist license. For those users the fallback **cannot** succeed — that is expected, not a misconfiguration. When it fails this way, the script's `SKIPPED` line stays honestly attributed to the **primary** tool — e.g. *"SKIPPED: Google (Antigravity) unavailable — agy: empty output after retry; gemini fallback: ineligible (auth/DASHER)"* — **never** a bare "Gemini auth failure," which would hide that `agy` was the real reviewer and mislead a user whose `agy` works fine interactively.

Label a successful result by the tool that produced it — **Antigravity** or **Gemini** (the script's `TOOL: <label>` line, keyed off the resolved binary's basename).

## Adding a New Provider

Add a new section above with: Detection, Invocation (note whether it dispatches through `scripts/rc-invoke-provider.sh` — only providers shaped as "one primary CLI binary, classifiable by exit code + stderr text, plus an optional one-fallback binary" qualify; an HTTP API like Perplexity keeps its own inline transport), MCP fallback (if any), Env requirements. Then update `skills/run/SKILL.md` to include it in the parallel dispatch.
