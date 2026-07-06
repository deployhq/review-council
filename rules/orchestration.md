# Orchestration Rules

## Convergence Criteria

Stop iterating when ANY of these are true:
1. All findings are agreed upon by all reviewers
2. No new findings emerged in the latest round
3. Maximum rounds (3) reached

## Round Logic

### Round 1: Independent Review
- All reviewers see the same context
- None see each other's review
- Ensures truly independent perspectives

### Round 2: Informed Revision
- All reviewers see Round 1 synthesis
- Each can confirm, revise, or rebut findings
- New findings from seeing other reviewers' perspectives are welcome

### Round 3: Final Resolution (rare)
- Only if Round 2 introduced significant new disagreements
- Focus narrowed to unresolved conflicts only
- If still no convergence, document both perspectives

## Severity Definitions

- **Critical**: Bugs, security vulnerabilities, data loss, system failures. Blocks ship.
- **Important**: Quality, performance, or maintainability concern. Should fix.
- **Suggestion**: Minor improvement. Nice to have.

## Deduplication

Two findings are duplicates if they:
- Reference the same code/section AND describe the same core concern
- Use different words but the underlying issue is identical

Keep the more specific/actionable version.

## Graceful Degradation

If only Claude is available (no other providers detected):
- Run full process with Claude reviewer only
- Orchestrator critically examines findings from a second perspective
- Output clearly notes "single-reviewer mode"
- Suggest running `/review-council:setup` to check provider availability

## Output Validation

After each reviewer returns, validate its output before including in synthesis.

### Section Presence

The output must contain:
- A `## Findings` section (or `### Findings`)
- A `## Overall Assessment` section (or `### Overall Assessment`)

### Field-Level Validation

Each finding must include:
- **Severity** (critical/important/suggestion)
- **Location** (file:line or section reference)
- **Recommendation** (concrete fix or alternative)

Findings missing any required field mark the entire reviewer output as FAILED.

### Outcomes

- **VALID** — has required sections with properly structured findings
- **CLEAN** — has required sections, reviewer explicitly found no issues ("No issues found" in Findings section). Valid but contributes no findings to synthesis. CLEAN counts toward the RC_MIN_REVIEWERS threshold.
- **FAILED** — output is malformed, missing required sections, or findings lack required fields

## Recovery Flow

After Round 1 validation, the orchestrator reports results and determines next action.

### Decision Logic

1. **All VALID or CLEAN**: proceed to synthesis (no user prompt needed)
2. **Some FAILED, enough remain (>= RC_MIN_REVIEWERS)**: ask the user conversationally — "Should I retry the failed reviewer(s) (will use additional tokens), proceed with the N successful reviews, or abort?"
3. **Some FAILED, not enough remain (< RC_MIN_REVIEWERS)**: ask the user — "Should I retry the failed reviewer(s) (will use additional tokens), or abort? Proceeding without retry means single-reviewer mode."
4. **All FAILED**: report the failure and abort. Do not retry automatically.

### Retry Rules

- **One retry attempt max** per reviewer per round. If a reviewer fails twice, mark it as unavailable and move on.
- **Retried results merge into the Round 1 pool** before synthesis begins. All validated results (first-pass and retried) are treated identically.
- **RC_AUTO_RETRY=true** skips the user prompt and retries failed reviewers automatically. Intended for CI/automated pipelines.

## Reviewer Timeouts & Fast-Fail

CLI and API reviewers must fail fast. A single overloaded or quota-capped provider must never stall the council — a dead provider should return `SKIPPED` in minutes, not tens of minutes. Every CLI/API reviewer subagent (Codex, the Google slot's `agy`/`gemini`, Perplexity) follows these rules:

1. **Hard per-invocation timeout.** Wrap every CLI call with a timeout so a single call can't hang forever. Resolve the binary first — GNU `timeout` is not always present (notably on macOS without coreutils, where it may be `gtimeout`). Use an explicit `if`/`else` (portable across bash, sh, and zsh — do **not** use `${TO:+$TO 600}`, which word-splits in bash but stays one word in zsh):
   ```bash
   TO="$(command -v timeout || command -v gtimeout || true)"
   if [ -n "$TO" ]; then "$TO" "${RC_REVIEWER_TIMEOUT:-600}" <cli> …; else <cli> …; fi
   ```
   A timeout (exit code 124) counts as a failure for that invocation. For `curl`, prefer its built-in `--max-time ${RC_REVIEWER_TIMEOUT:-600}` (no external binary needed). If a CLI has its own internal wait (e.g. agy's `--print-timeout`, default 5m), raise it to match the budget or it will cut off before the wrapper does. If no timeout binary is available and you can't wrap the call, still enforce rules 2–3 strictly — the retry cap and fast-fail are what actually prevent a multi-hour hang.
2. **No compounding retries.** At most **one** retry per tool, and only for a single clearly-transient blip (e.g. one network hiccup). Never chase a provider's own model auto-fallback across many backoff attempts — that is what turned one dead provider into an ~84-minute hang.
3. **Fast-fail (return `SKIPPED` immediately, no retry)** when the output or error indicates a non-transient condition:
   - **Auth failure** — e.g. `no longer supported`, `not authenticated`, `please migrate to the Antigravity`, `secret keyring is locked`, login/OAuth errors.
   - **Quota / rate cap** — HTTP 429, `exhausted your daily quota`, `TerminalQuotaError`, `rate limit`.
   - **Persistent overload** — HTTP 503 / `high demand` that continues past the timeout.
4. **Fallback, not retry.** For the Google slot, a fast-fail of `agy` means move on to `gemini` (its fallback), not retry `agy`. When no fallback tool remains, return the `SKIPPED` sentinel and let the council proceed with the remaining reviewers (subject to `RC_MIN_REVIEWERS`).

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `RC_CLAUDE_MAX_TURNS` | `30` | Max turns for Claude reviewer subagent |
| `RC_MIN_REVIEWERS` | `2` | Minimum successful reviewers for council mode |
| `RC_AUTO_RETRY` | `false` | If `true`, retry failed reviewers without asking |
| `RC_REVIEWER_TIMEOUT` | `600` | Per-invocation wall-clock cap (seconds, 10 min) for CLI/API reviewers; raise for very large diffs |
