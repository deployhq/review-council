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
- **The Google slot is exempt when it already exhausted its internal retry/fallback.** A `SKIPPED` whose reason is `agy` empty-after-retry, `agy` timeout, or `gemini` ineligibility (`DASHER_USER`) is **terminal** — do not re-run it here (it already spent its one allowed retry internally, and re-running only re-hits a dead `gemini` or another cold-start). Applies even under `RC_AUTO_RETRY=true`.
- **Retried results merge into the Round 1 pool** before synthesis begins. All validated results (first-pass and retried) are treated identically.
- **RC_AUTO_RETRY=true** skips the user prompt and retries failed reviewers automatically. Intended for CI/automated pipelines.

## Reviewer Timeouts & Fast-Fail

CLI and API reviewers must fail fast. A single overloaded or quota-capped provider must never stall the council — a dead provider should return `SKIPPED` in minutes, not tens of minutes. Every CLI/API reviewer subagent (Codex, the Google slot's `agy`/`gemini`, Perplexity) follows these rules:

1. **Hard per-invocation timeout — never run a CLI unbounded.** Cap every CLI call. Prefer a tool-native cap when one exists (`curl --max-time`, agy's `--print-timeout`); otherwise wrap with `timeout`/`gtimeout`; and if **neither binary is present** (e.g. a stock macOS with no coreutils), use a pure-shell watchdog so the call still can't hang forever. Resolve the binary first and use an explicit `if`/`else` (portable across bash, sh, and zsh — do **not** use `${TO:+$TO 600}`, which word-splits in bash but stays one word in zsh):
   ```bash
   cap="${RC_REVIEWER_TIMEOUT:-600}"
   TO="$(command -v timeout || command -v gtimeout || true)"
   if [ -n "$TO" ]; then
     "$TO" "$cap" <cli> … > out.txt 2>&1; rc=$?
   else
     # no timeout binary — background + watchdog so the call is never unbounded
     <cli> … > out.txt 2>&1 & pid=$!
     ( sleep "$cap"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
     wait "$pid"; rc=$?; kill "$wd" 2>/dev/null
   fi
   # rc != 0 (124 timeout / 143 SIGTERM / provider error) = failure for this invocation
   ```
   For `curl`, its built-in `--max-time ${RC_REVIEWER_TIMEOUT:-600}` already caps it (no external binary needed). If a CLI has its own internal wait (e.g. agy's `--print-timeout`, default 5m), raise it to match the budget or it will cut off before the wrapper — agy's flag takes a **unit-suffixed duration** (`"${RC_REVIEWER_TIMEOUT:-600}s"` or `10m`; a bare integer like `600` is rejected with `missing unit in duration`). The watchdog guarantees a cap even with no `timeout`/`gtimeout`; do **not** fall back to a bare, uncapped invocation — that reopens the exact hang this section prevents.
2. **No compounding retries.** At most **one** retry per tool, and only for a single clearly-transient blip (e.g. one network hiccup). Never chase a provider's own model auto-fallback across many backoff attempts — that is what turned one dead provider into an ~84-minute hang.
3. **Fast-fail the current *tool* immediately (no retry)** when the output or error indicates a non-transient condition. Fast-fail is **tool-level, not slot-level**: if the reviewer has a documented fallback tool (the Google slot's `agy`→`gemini`), move to it next; return the reviewer-level `SKIPPED` sentinel only when **no fallback tool remains**. Non-transient conditions:
   - **Auth failure** — e.g. `no longer supported`, `not authenticated`, `please migrate to the Antigravity`, `secret keyring is locked`, `IneligibleTierError` / `DASHER_USER` / `not eligible for Gemini Code Assist` (Workspace/Dasher account — `gemini` only), login/OAuth errors.
   - **Quota / rate cap** — HTTP 429, `exhausted your daily quota`, `TerminalQuotaError`, `rate limit`.
   - **Persistent overload** — HTTP 503 / `high demand` that continues past the timeout.
4. **Fallback, not retry — with one narrow, budget-bounded exception for `agy` empty output.** For the Google slot, a **hard** fast-fail of `agy` (auth/quota) or an `agy` timeout means move on to `gemini` (its fallback), not retry `agy`. **The one exception:** if `agy` returns **empty/malformed output *quickly*** (exit 0 with no stdout, back in well under the budget — the cold-start quirk), **retry `agy` once** before falling back, and **time-box that retry to the *remaining* budget, not a fresh `RC_REVIEWER_TIMEOUT`** (first-try + retry must fit inside one budget). If instead the empty result arrived **near the cap** — a slow call that completed but printed nothing — treat it like a timeout: **do not retry**, fall straight to `gemini`. The warm retry almost always succeeds, and `gemini` is a dead end for Workspace/Dasher accounts (`IneligibleTierError: DASHER_USER`), so burning the slot on it wastes the whole Google reviewer. When no tool remains, return the `SKIPPED` sentinel **attributed to the primary tool** (`agy` when installed) — not mislabeled as a `gemini` auth failure. That `SKIPPED` (and any successful Google result) is **terminal for the round**: the internal `agy` retry already consumed the slot's one allowed retry, so the Google reviewer is **not eligible for the Step 3.5 reviewer-level retry** — never re-run it externally on an `agy`-empty-after-retry, `agy`-timeout, or `gemini`-ineligible reason. Let the council proceed with the remaining reviewers (subject to `RC_MIN_REVIEWERS`).

## Run Settings

Run knobs come from the **config reader** (`scripts/rc-config.sh`, read in Step 0 of `skills/run/SKILL.md`), which reconciles the config files, `RC_*` environment variables, and built-in defaults. Precedence is applied **per key**:

```
env (RC_*)  >  .review-council/config.local.yml  >  .review-council/config.yml  >  built-in default
```

Step 0 (of `skills/run/SKILL.md`) resolves the effective `settings.*` via `rc-config.sh`, which already folds any `RC_*` environment override into each value at the correct precedence. **Throughout this document, every `RC_*` name denotes that knob's *effective* value** (its resolved `settings.*` result) — not a fresh read of the ambient environment. With no config files (or no `yq` installed), the effective values are the defaults + any `RC_*` overrides — byte-identical to prior behavior. Full schema: `rules/config.md`.

When the orchestrator runs a step that **consumes** an `RC_*` env var — the timeout wrapper below, or `scripts/rc-invoke-provider.sh` in a later PR — it **supplies the effective value on that invocation**, e.g. `RC_REVIEWER_TIMEOUT=<effective settings.reviewer_timeout_seconds> <cli> …`. Do **not** rely on a shell `export` to carry a value across steps: the orchestrator is an LLM driving separate tool calls and subagents, so it carries the effective values resolved in Step 0 and passes them explicitly per-invocation.

| Setting (`settings.*`) | Default | Env override | Purpose |
|---|---|---|---|
| `personas` | `true` | `RC_PERSONAS` | Use reviewer personas when prompting reviewers. |
| `verify` | `true` | `RC_VERIFY` | Run the verification pass over findings. |
| `verify_max_findings` | `12` | `RC_VERIFY_CAP` | Cap on findings sent to the verification pass. |
| `learn` | `true` | `RC_LEARN` | Enable the learning/memory mechanism. |
| `min_reviewers` | `2` | `RC_MIN_REVIEWERS` | Minimum participating reviewers for council mode. |
| `reviewer_timeout_seconds` | `600` | `RC_REVIEWER_TIMEOUT` | Per-invocation wall-clock cap (**seconds**) for CLI/API reviewers. |
| `run_budget_seconds` | `600` | `RC_RUN_BUDGET` | Total wall-clock budget (**seconds**) for the whole run. |
| `auto_retry` | `false` | `RC_AUTO_RETRY` | Retry failed reviewers without asking (CI-friendly). |

**`reviewer_timeout_seconds` / `RC_REVIEWER_TIMEOUT`** is sized to cover `agy`'s multi-minute cold start; `agy`'s own `--print-timeout` must be raised to match, as a **unit-suffixed** duration — `"${RC_REVIEWER_TIMEOUT}s"` or `10m`, never a bare `600` (see the timeout wrapper above). Raise for very large diffs or slow networks.

One additional env var is **not** part of the config schema (it has no `settings.*` key and is read directly):

| Variable | Default | Purpose |
|---|---|---|
| `RC_CLAUDE_MAX_TURNS` | `30` | Max turns for the Claude reviewer subagent. |
