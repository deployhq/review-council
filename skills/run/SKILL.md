---
description: Multi-agent convergence review. Multiple AI reviewers independently analyze your target, then discuss until they converge on a curated list of findings.
argument-hint: "[PR number | file/directory path | blank for auto-detect]"
allowed-tools: Agent, Bash, Read, Glob, Grep, Write, mcp__codex__codex, mcp__codex__codex-reply
---

# Review Council — Multi-Agent Convergence Review

You are the **Orchestrator** of a review council. Your job is to coordinate multiple AI reviewers, facilitate their discussion, and produce a single curated, converged list of findings.

## Step 0: Read Config & Detect Available Providers

Two independent gates decide the reviewer roster: **configuration** (which reviewers/lenses are *enabled*, from the config files) and **detection** (which reviewers are *available* on this machine). A reviewer participates only if it is **both** enabled and available. Do 0.1 and 0.2, then reconcile in 0.3.

### 0.1 Read the effective configuration

Run the bundled config reader and capture its `key=value` output. It reconciles `.review-council/config.yml`, `.review-council/config.local.yml`, `RC_*` env vars, and built-in defaults — precedence **env > config.local.yml > config.yml > built-in default** — and prints the effective config to stdout (diagnostics to stderr). It always exits `0`: absent files or absent `yq` degrade to defaults. See `rules/config.md` for the full schema.

```bash
# Read from the TARGET repo's .review-council/ (the CWD where the review runs).
# ${CLAUDE_PLUGIN_ROOT} is the plugin's own install dir — must be double-quoted.
CONFIG_OUT="$("${CLAUDE_PLUGIN_ROOT}/scripts/rc-config.sh" .review-council 2>/tmp/rc-config-notes)"
printf '%s\n' "$CONFIG_OUT"
# Surface any reader diagnostics (malformed keys, yq-not-found, skipped files):
[ -s /tmp/rc-config-notes ] && { echo "--- rc-config notes ---"; cat /tmp/rc-config-notes; }
```

**Echo the effective, reconciled config to the user before applying it.** This printed block is the observable artifact of what the run resolved — show what you resolved, never silently eyeball the YAML. Parse the `key=value` lines (one per line, no spaces around `=`; `#` lines are section comments). The keys are:

- `reviewer.<p>.enabled` / `reviewer.<p>.model` for `p` in `claude`, `codex`, `google`, `perplexity`.
- `lens.<l>.enabled` / `lens.<l>.providers` for `l` in `security`, `correctness`, `cross_file`, `performance`, `design`, `dependency` — plus `lens.security.replaces_dedicated`.
- `settings.<k>` for `personas`, `verify`, `verify_max_findings`, `learn`, `min_reviewers`, `reviewer_timeout_seconds`, `run_budget_seconds`, `auto_retry`.

If `yq` is missing, the reader prints a `yq not found` note and falls back to defaults + env; the run proceeds normally (config files are simply ignored). `rules/config.md` documents the one-time `brew install yq` (mikefarah v4) needed to *use* config files.

### 0.2 Detect available providers

Probe which reviewers are available on this machine. Refer to `rules/providers.md` for detection methods.

**Run this detection command verbatim — do not hand-roll or abbreviate it.** The `agy` probe is the one most often dropped when detection is improvised, which silently collapses the Google slot to a `gemini` that cannot authenticate on Google Workspace accounts (`IneligibleTierError: DASHER_USER`). `agy` is the **default** Google reviewer and MUST be probed explicitly — including its known install path (`~/.local/bin/agy`), in case it isn't on `PATH`:

```bash
# agy: probe PATH first, then common install dirs (a minimal PATH may omit them)
AGY="$(command -v agy 2>/dev/null || true)"
if [ -z "$AGY" ]; then
  for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    [ -x "$d/agy" ] && { AGY="$d/agy"; break; }
  done
fi
GEM="$(command -v gemini 2>/dev/null || true)"
CDX="$(command -v codex 2>/dev/null || true)"
# one key=value per line — never space-join (a $HOME with a space would break parsing)
echo "codex=${CDX:-none}"
if [ -n "$AGY" ]; then
  echo "google=antigravity"
  echo "agy=$AGY"
  echo "gemini_fallback=${GEM:-none}"
elif [ -n "$GEM" ]; then
  echo "google=gemini"
  echo "gemini=$GEM"
else
  echo "google=none"
fi
echo "perplexity=$([ -n "$PERPLEXITY_API_KEY" ] && echo set || echo unset)"
```

Interpret the output (each value is on its own line — read the whole line as the value, so paths containing spaces stay intact):

1. **Claude**: Always available.
2. **Codex**: `codex=<path>` → available (CLI). If `codex=none`, check whether the `mcp__codex__codex` tool is available — if so, available (MCP); otherwise unavailable.
3. **Google (Antigravity / Gemini)** — one slot shared by both Google CLIs (see `rules/providers.md` → "Google-family reviewer"):
   - `google=antigravity` → available as **Google (Antigravity)**. `agy` is primary — invoke it via the resolved `agy=<path>`; `gemini` (from `gemini_fallback=<path>`) is fallback only. Announce it as "Google (Antigravity)", **never** "Gemini", because `agy` is what will actually run.
   - `google=gemini` → available as **Google (Gemini)**. Note that `gemini` is ineligible for Workspace/Dasher Google accounts and may fast-fail auth (`IneligibleTierError`). **If the user's account is a Google Workspace / managed domain, double-check that `agy` truly isn't installed** (e.g. in a dir the probe missed) before accepting a gemini-only slot — a `google=gemini` verdict there usually means the `agy` probe missed it, which is the exact silent collapse this detection is meant to prevent.
   - `google=none` → unavailable.
   Never count this as two reviewers. Pass the resolved primary tool **and its path**, plus the fallback tool **and its path**, to the Google reviewer subagent.
4. **Perplexity**: `perplexity=set` → available; `unset` → unavailable.

### 0.3 Apply the configuration to the roster

Reconcile the config (0.1) with detection (0.2):

- **Roster (reviewers).** Drop any provider whose `reviewer.<p>.enabled=false` — it does not participate even if installed. Of the reviewers that remain enabled, those that detection found available make up the participating roster. Config gates the roster; detection gates availability — **both** must pass.
- **Models.** Where `reviewer.<p>.model` is non-empty, pass that model to that reviewer's invocation (e.g. the Google slot's model, or the Perplexity model — default `sonar`). An empty model means "use the tool's own default" — pass nothing.
- **Lens bindings (record for Round 1).** Record each `lens.<l>.enabled` and `lens.<l>.providers` (`auto`, or a comma-joined provider list). The actual lens dispatch lands in **PR 1b** — here you only **read and record** the bindings. Note `lens.security.replaces_dedicated`: when `true`, the pinned `security.providers` *replace* the dedicated security reviewer (do not run both); when `false`, security stays on its default/`auto` path.
- **Settings.** Load the `settings.*` values for this run and use them wherever the orchestration rules reference a run knob (`min_reviewers`, `reviewer_timeout_seconds`, `run_budget_seconds`, `auto_retry`, etc.). These **supersede** any ad-hoc reading of the bare `RC_*` env vars — the reader already folded `RC_*` in at the correct precedence, so read them from the reader's output, not from the environment directly.
- **Absent config / absent `yq` → today's defaults**, byte-identical to pre-config behavior. Disabling reviewers still honors `settings.min_reviewers`: if too few remain to reach it, the existing min-reviewers handling applies (single-reviewer mode or the usual prompt).

Announce: "**Review Council** — [N] reviewers available: [list]. [Skipped: reason for each unavailable **or config-disabled** provider]". When the Google slot is available, name the actual tool — e.g. "Google (Antigravity)" — so it's clear `agy` (not `gemini`) is the one running.

If only Claude is available, proceed in **single-reviewer mode** and note it in the output. Suggest running `/review-council:setup` to see how to add more reviewers.

## Step 1: Detect Review Target

Analyze the user's input: `$ARGUMENTS`

**Auto-detection rules (in order):**

1. **Number** (e.g., `42`, `#42`) — PR review. Fetch with `gh pr view <number> --json title,body,baseRefName,headRefName,changedFiles,additions,deletions,reviewDecision,comments,reviews` and `gh pr diff <number>`.
2. **Path to `.md` file** inside `docs/`, `plans/`, `adr/`, or similar documentation directory — Plan/document review. Read the file and any documents it references.
3. **Path to source code** (file or directory) — Code review. Read the files. If a directory, identify the key files (skip node_modules, dist, etc.).
4. **No argument** — Auto-detect:
   a. Check for open PR on current branch: `gh pr view --json number,title,body,baseRefName,headRefName,changedFiles 2>/dev/null`
   b. If PR found — PR review
   c. If no PR — check for staged changes: `git diff --cached --stat`
   d. If staged changes — Code review of staged diff
   e. If nothing staged — check unstaged: `git diff --stat`
   f. If unstaged changes — Code review of working changes
   g. If nothing — ask the user what to review

Announce your detection: "**Review Council** — Reviewing [PR #42: title | plan: path | code: path | staged changes]"

## Step 2: Gather Context — Baseline Context Package

Collect context appropriate to the detected type. This becomes the **baseline context package** — the identical context every reviewer receives. Gather mechanically using exact commands; do not summarize or interpret.

**PR review:**
- PR metadata: `gh pr view <number> --json title,body,baseRefName,headRefName,changedFiles,additions,deletions,reviewDecision,comments,reviews`
- Full diff: `gh pr diff <number>`
- List of changed files with additions/deletions
- Git log for changed files: `git log --oneline -10 -- <changed_files>`
- Git blame for changed hunks: `git blame -L <start>,<end> -- <file>` for each changed hunk
- Any existing review comments or discussions
- Project conventions: raw contents of CLAUDE.md, CONTRIBUTING.md, README (if present)

**Plan/document review:**
- Full document content
- Any documents referenced or linked (ADRs, related plans)
- Project conventions: raw contents of CLAUDE.md, CONTRIBUTING.md, README (if present)

**Code review:**
- Full file contents (or diff if reviewing changes)
- Git log for changed files: `git log --oneline -10 -- <files>`
- Git blame for changed hunks
- Project conventions: raw contents of CLAUDE.md, CONTRIBUTING.md, README (if present)

Package this as a structured text block. You will send this same package to each reviewer — this is the shared baseline. Reviewers may explore further using their own tools, but the baseline ensures equal starting context.

## Step 3: Round 1 — Independent Review (Parallel)

Launch **all available reviewers in parallel**. They must not see each other's output — this ensures truly independent perspectives.

### Reviewer: Claude (native subagent) — Always

Use the `Agent` tool with `subagent_type: "reviewer-claude"`.

If the `RC_CLAUDE_MAX_TURNS` environment variable is set, override the default maxTurns by passing it to the Agent tool.

**IMPORTANT:** Embed the full baseline context package and delegation prompt directly in the Agent tool's `prompt` parameter. Use this exact template — fill in the bracketed sections with the actual content:

> ## TASK
> [Review type]: Review the following [PR/plan/code] as one member of a multi-agent review council. Other AI models are reviewing the same material simultaneously.
>
> ## REVIEW PROCESS
> Follow these steps in order:
> 1. **Understand intent** — What is this PR/code/plan trying to achieve? Read carefully before judging.
> 2. **Evaluate correctness** — Does it achieve its stated goal? Are there logic errors, missed edge cases, or incorrect assumptions?
> 3. **Identify risks** — What could go wrong in production? Consider security, performance, reliability, data integrity, and failure modes.
> 4. **Check completeness** — What's missing? Error handling, tests, documentation, migration steps, rollback plans.
> 5. **Assess design** — Is this the right approach? Is there a simpler way? Will this be maintainable in 6 months?
>
> ## CONTEXT
> [Paste the COMPLETE baseline context package here — full diff, file contents, git log, git blame, project conventions. Do NOT summarize or truncate.]
>
> ## CONSTRAINTS
> - For PRs: focus on what the change introduces, what it might break, and whether it achieves its stated goal
> - For plans: focus on feasibility, completeness, risks, and missing considerations
> - For code: focus on correctness, security, performance, error handling, and maintainability
> - You have Read, Glob, and Grep tools available. Review the provided context and produce your structured findings FIRST. Then use tools to verify concerns and explore for issues the context may have missed (e.g., check callers of a changed function, look for side effects). Always produce your structured output — exploration supplements the review, it does not replace it.
>
> ## MUST DO
> - Provide specific file:line or section references
> - Explain WHY each finding matters — include the impact, not just the symptom
> - Suggest a concrete fix for each finding
> - Rate severity (critical/important/suggestion) and confidence (high/medium/low)
> - Quality over quantity — 3 important findings beat 10 nitpicks
>
> ## MUST NOT DO
> - Flag style/formatting nitpicks
> - Flag pre-existing issues not in the diff — only review what changed
> - Provide vague feedback without actionable recommendations
> - Exceed 10 findings
> - Explore the codebase without first reviewing the provided context and producing findings
>
> ## OUTPUT FORMAT
> You MUST produce output with these exact sections:
>
> ### Findings
> For each finding (max 10): Severity, Confidence, Location, Issue, Why it matters, Recommendation.
> If no issues: write "No issues found."
>
> ### What's Good
> Brief list of things done well.
>
> ### Overall Assessment
> One paragraph: readiness, biggest risk, most important thing to address.

### Reviewer: Codex — If Available

**IMPORTANT:** Use an `Agent` subagent to invoke Codex. This keeps the full review response out of the orchestrator's context window — only the structured findings return.

Dispatch a `general-purpose` Agent with this prompt:

> You are invoking the Codex reviewer for a Review Council review. Your job is to call the Codex CLI, collect its response, and return the structured findings.
>
> **Step 1: Discover CLI syntax.** Run `codex --help` and `codex exec --help` to learn the available subcommands and flags. Do NOT assume any specific flags exist — always derive the correct invocation from the help output.
>
> **Step 2: Invoke Codex.** Write the delegation prompt to `/tmp/rc-codex-prompt.md`, then use the syntax you discovered to run Codex in non-interactive/full-auto mode with the prompt content.
>
> **Reliability rules — apply to every CLI call (see `rules/orchestration.md` → "Reviewer Timeouts & Fast-Fail"):**
> - Cap each invocation so it can never hang forever. Resolve the binary first (it may be `timeout` or, on macOS, `gtimeout`, or absent), then use a portable `if`/`else` (works in bash, sh, and zsh): `TO="$(command -v timeout || command -v gtimeout || true)"` then `if [ -n "$TO" ]; then "$TO" "${RC_REVIEWER_TIMEOUT:-600}" codex …; else <pure-shell watchdog>; fi`. Do NOT use `${TO:+$TO 600}` — it word-splits in bash but not zsh. If **neither** `timeout` nor `gtimeout` exists, do NOT run bare — use the pure-shell watchdog from `rules/orchestration.md` § Reviewer Timeouts (background the call, `kill` it after the budget) so the invocation is still bounded. A non-zero exit (124 timeout / 143 SIGTERM / provider error) = failure.
> - Do NOT loop with compounding retries. At most ONE retry, and only for a single clearly-transient blip (e.g. one network hiccup).
> - Fast-fail immediately (return the SKIPPED sentinel, no further retries) when the output or error shows an auth failure (`not authenticated`, login/OAuth errors), a quota/rate cap (HTTP 429, `exhausted your … quota`, `rate limit`), or persistent overload (HTTP 503 / `high demand` past the timeout). A dead provider must fail in minutes, not tens of minutes.
>
> **MCP fallback:** If the CLI call fails for a non-fatal reason (not an auth/quota fast-fail), use the `mcp__codex__codex` tool with the delegation prompt instead.
>
> **If both fail**: Return "SKIPPED: Codex unavailable — [error details]"
>
> Return the full structured review output (Findings, What's Good, Overall Assessment).

### Reviewer: Google (Antigravity / Gemini) — If Available

**IMPORTANT:** Use an `Agent` subagent to invoke the Google-family reviewer, same pattern as Codex — keeps the response out of the orchestrator's context. `agy` (Antigravity) and `gemini` share one slot; try `agy` first, fall back to `gemini`.

Dispatch a `general-purpose` Agent with this prompt. Pass the ordered tool list resolved in Step 0 — `agy` then `gemini` if both are installed, or whichever single tool is available — **using the resolved paths** from Step 0's detection output (`agy=<path>` and `gemini_fallback=<path>`), not bare command names, so the subagent can invoke each even if its dir isn't on the subagent's `PATH`:

> You are invoking the Google-family reviewer (Antigravity `agy`, with Gemini `gemini` as fallback) for a Review Council review. Your job is to call the CLI, collect its response, and return the structured findings. Try the tools in this order: **[ordered tool list with resolved full paths, e.g. `/Users/you/.local/bin/agy`, then `/Users/you/.nvm/.../bin/gemini`]**. Invoke each tool by the exact full path given here — if a tool isn't found on `PATH`, use the full path provided rather than declaring it unavailable.
>
> For each tool in order:
>
> **Step 1: Discover CLI syntax.** Run `<tool> --help` to learn the available subcommands and flags. Do NOT assume any specific flags exist — always derive the correct invocation from the help output. (Hints verified against agy 1.0.16–1.1.0: `agy -p "<prompt>"` runs one prompt non-interactively and prints the response; optional `--add-dir <repo>`, `--model <name>`, and `--dangerously-skip-permissions` to avoid blocking on approvals in a non-TTY. `gemini` uses `gemini -p "<prompt>"` and may need `--skip-trust` or `GEMINI_CLI_TRUST_WORKSPACE=true` for headless/non-TTY runs.)
>
> **Give `agy` room for a cold start — this is the "more time" it needs.** `agy`'s **first** `-p` call in a session pays a cold-start cost (model load, auth handshake, update check) and can legitimately take **several minutes** (a warm call is ~10s). Two caps apply to it and BOTH must cover the budget, or the cold start is truncated:
> - The outer wrapper cap = `${RC_REVIEWER_TIMEOUT:-600}` (10 min default).
> - agy's **own** `--print-timeout`, which defaults to **just 5 minutes**. You MUST pass it sized to the budget — but its value is a **Go duration string that needs a unit suffix**: a bare integer is rejected (`agy --print-timeout 600` → exit 2, `missing unit in duration "600"`, which kills the primary Google reviewer instantly). `RC_REVIEWER_TIMEOUT` is in **seconds**, so append `s`: `--print-timeout "${RC_REVIEWER_TIMEOUT:-600}s"` (or a literal like `10m`) — never a bare `--print-timeout 600`. Not optional: without it agy cuts itself off at 5m before the wrapper and a slow cold start looks like a failure.
>
> Treat multi-minute latency on the first `agy` call as **normal, not a hang** — do not fast-fail it for being slow. (Only auth/quota errors fast-fail; see below.)
>
> **Step 2: Invoke the tool.** Write the delegation prompt to `/tmp/rc-google-prompt.md`, then use the syntax you discovered to run the tool in non-interactive mode with the prompt content and text output.
>
> **Reliability rules — apply to every CLI call (see `rules/orchestration.md` → "Reviewer Timeouts & Fast-Fail"):**
> - Cap each invocation so it can never hang forever. Resolve the binary first (it may be `timeout` or, on macOS, `gtimeout`, or absent), then use a portable `if`/`else` (works in bash, sh, and zsh): `TO="$(command -v timeout || command -v gtimeout || true)"` then `if [ -n "$TO" ]; then "$TO" "${RC_REVIEWER_TIMEOUT:-600}" <tool> …; else <pure-shell watchdog>; fi`. Do NOT use `${TO:+$TO 600}` — it word-splits in bash but not zsh. If **neither** `timeout` nor `gtimeout` exists, do NOT run bare — use the pure-shell watchdog from `rules/orchestration.md` § Reviewer Timeouts (background the call, `kill` it after the budget) so the invocation is still bounded. A non-zero exit (124 timeout / 143 SIGTERM / provider error) = failure.
> - Do NOT loop with compounding retries. At most ONE retry per tool, and only for a single clearly-transient blip (e.g. one network hiccup). Do NOT chase a provider's own model auto-fallback across many backoff attempts.
> - Fast-fail a tool immediately (move to the next tool, no further retries) when the output or error shows an auth failure (`no longer supported`, `not authenticated`, `please migrate to the Antigravity`, `secret keyring is locked`), a quota/rate cap (HTTP 429, `exhausted your daily quota`, `TerminalQuotaError`, `rate limit`), or persistent overload (HTTP 503 / `high demand` past the timeout). A dead provider must fail in minutes, not tens of minutes.
>
> **Step 3: Validate the output before accepting it.** A tool counts as successful ONLY if it returned **non-empty** text containing a real `Findings` section (and `Overall Assessment`). Note: `agy -p` can exit **0 while printing nothing** in a non-TTY subprocess — so a zero exit code is not sufficient. Empty or malformed output is a **failure**, not a clean review.
>
> **Step 4: Retry `agy` once (only if it failed *fast*), THEN fall back — this ordering is the whole point.** A transient `agy` blip must never be masked by a `gemini` that cannot succeed, but the retry must never turn into a runaway. Concretely:
> - Retry `agy` ONCE **only when the empty/malformed result came back quickly** — as a rule of thumb, in under ~⅓ of the budget (e.g. < ~2 min of a 10 min cap). That fast-empty is the exit-0-no-stdout cold-start quirk, and the warm retry almost always succeeds. **Time-box the retry to the *remaining* budget, not a fresh `RC_REVIEWER_TIMEOUT`**, so first-try + retry together can never exceed one budget. This is the single allowed retry for `agy`.
> - Do **NOT** retry — move straight to the fallback — when the empty result arrived **near the cap** (a slow call that completed but printed nothing: treat it exactly like a timeout — a second full attempt would nearly double the wall-clock), or when `agy` **timed out** (rc 124/143), is **absent**, or **hard-failed** (auth/quota fast-fail — retrying won't help). Never retry a tool that hard-failed on auth/quota.
> - **This is a terminal outcome for the slot.** Once you've done the one allowed `agy` retry (or skipped it per the rule above) and, if needed, tried `gemini`, the Google reviewer's result — success or `SKIPPED` — is **final for this round**. Do not let the orchestrator's Step 3.5 reviewer-level retry re-run it (see Step 3.5: the Google slot is not eligible for external retry once its internal retry/fallback is exhausted).
> - **`gemini` is a dead end for Workspace/Dasher accounts:** `gemini -p` fast-fails near-instantly with `IneligibleTierError` (`reasonCode: DASHER_USER`, "not eligible for Gemini Code Assist for individuals") for any Google Workspace-domain account and any account without a `GEMINI_API_KEY`/Vertex/enterprise license. Treat that as the slot being unavailable — it is expected, not a bug to retry.
>
> **On success:** Return the full structured review output (Findings, What's Good, Overall Assessment), and note which tool produced it — prefix your answer with `TOOL: Antigravity` (for `agy`) or `TOOL: Gemini` (for `gemini`).
>
> **If every tool fails**: Return a SKIPPED message attributed to the **primary** tool, with a per-tool status — e.g. "SKIPPED: Google (Antigravity) unavailable — agy: empty output after retry; gemini fallback: ineligible (Workspace/Dasher account, IneligibleTierError)". Lead with `agy` whenever it was installed. Do **NOT** report the slot as a bare "Gemini auth failure" when `agy` was the intended reviewer — that misleads a user whose `agy` works fine interactively.

### Reviewer: Perplexity — If Available

**IMPORTANT:** Use an `Agent` subagent to invoke Perplexity, same pattern — keeps the API response out of the orchestrator's context.

Dispatch a `general-purpose` Agent with this prompt:

> You are invoking the Perplexity reviewer for a Review Council review. Your job is to call the Sonar API, collect its response, and return the structured findings.
>
> **Step 1: Build the JSON payload** using `jq` to avoid manual escaping:
> ```bash
> PROMPT="[the full delegation prompt text]"
> jq -n --arg model "sonar" --arg prompt "$PROMPT" \
>   '{model: $model, messages: [{role: "user", content: $prompt}]}' \
>   > /tmp/rc-perplexity-payload.json
> ```
>
> **Step 2: Call the API:**
> ```bash
> curl -fsS --max-time "${RC_REVIEWER_TIMEOUT:-600}" https://api.perplexity.ai/v1/chat/completions \
>   -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
>   -H "Content-Type: application/json" \
>   -d @/tmp/rc-perplexity-payload.json \
>   -o /tmp/rc-perplexity-response.json
> ```
> Note: `-f` makes `curl` exit non-zero (22) on any HTTP 4xx/5xx without exposing the status code. Treat any such failure as terminal — fast-fail (return SKIPPED, no retry), do not loop. Perplexity has no fallback tool, so there's nothing to gain from distinguishing 401/403/429 from other errors. (If you ever need the exact status, capture it with `-w '%{http_code}'` and drop `-f`.)
>
> **Step 3: Parse the response:**
> ```bash
> jq -er '.choices[0].message.content' /tmp/rc-perplexity-response.json
> ```
>
> **If curl or jq fails**: Return "SKIPPED: Perplexity unavailable — [error details]"
>
> Return the full structured review output (Findings, What's Good, Overall Assessment).

### Delegation Prompt

For **all** reviewers (including Claude), use the delegation format from `rules/delegation-format.md`. The prompt structure and review criteria are identical for every provider — only the transport differs. The baseline context package from Step 2 goes into the CONTEXT section.

## Step 3.5: Validate Round 1 Results & Recover

Before synthesis, validate each reviewer's output. Refer to `rules/orchestration.md` for full validation rules.

### Validate

For each reviewer's response:
1. Check for `## Findings` (or `### Findings`) section — present?
2. Check for `## Overall Assessment` (or `### Overall Assessment`) section — present?
3. If Findings section exists and contains findings, check each finding has: **Severity**, **Location**, **Recommendation**
4. If Findings section says "No issues found" or equivalent — mark as CLEAN
5. If sections are missing or findings lack required fields — mark as FAILED

### Report & Recover

Count VALID, CLEAN, and FAILED results.

**If all VALID or CLEAN:** Announce results and proceed to Step 4.

```
Round 1 complete. All N reviewers produced valid output:
  Claude        [ok]  3 findings
  Codex         [ok]  5 findings
  Antigravity   [clean]  no issues found
```

**If any FAILED but enough remain (>= RC_MIN_REVIEWERS, default 2):**

Report the status and ask the user conversationally:

"Round 1 complete: [list results]. N of M reviewers succeeded. Should I retry the failed reviewer(s) (will use additional tokens), proceed with the N successful reviews, or abort?"

If `RC_AUTO_RETRY` is set to `true`, skip the prompt and retry automatically.

**If any FAILED and not enough remain (< RC_MIN_REVIEWERS):**

"Round 1 complete: [list results]. Only N reviewer(s) succeeded — council mode requires RC_MIN_REVIEWERS. Should I retry the failed reviewer(s) (will use additional tokens), or abort? Proceeding without retry means single-reviewer mode."

**If all FAILED:** Report the failure and abort.

### Retry

If retrying:
- Re-dispatch only the FAILED reviewers using the same dispatch method as Round 1
- Validate the retry results using the same checks
- **One retry max per reviewer** — if it fails again, mark as unavailable
- Merge all validated results (first-pass and retried) into a single pool
- Proceed to Step 4 with the merged pool

## Step 4: Analyze Round 1 Results

Once all reviewers respond, build a **synthesis**:

1. **Merge** all findings into a single list
2. **Deduplicate** — two findings are duplicates if they reference the same location AND describe the same core concern (even if worded differently). Keep the more specific/actionable version.
3. **Categorize** each finding:
   - **Agreed** — Multiple reviewers flagged this (or substantially similar finding). HIGH confidence.
   - **Unique** — Only one reviewer flagged this. MEDIUM confidence.
   - **Conflicting** — Reviewers explicitly disagree (one says it's fine, the other says it's a problem). Needs discussion.

## Step 5: Round 2 — Informed Revision (If Needed)

**Skip Round 2 if ALL of these are true:**
- Zero conflicting findings
- Unique findings are all "suggestion" severity (not critical or important)
- Total unique findings <= 3

**If Round 2 is needed**, share the Round 1 synthesis with all reviewers that participated in Round 1 and ask them to revise.

### Claude (Round 2)
Spawn a new `reviewer-claude` agent. Provide the Round 1 synthesis and ask:
- Confirm or revise your original findings in light of the other reviewers' perspectives
- Specifically address conflicting findings — explain your reasoning
- Flag any new concerns triggered by other reviewers' observations

### Codex (Round 2)
Dispatch a new `general-purpose` Agent subagent (same pattern as Round 1). Provide the full original context + Round 1 synthesis + Round 2 revision instructions from `rules/delegation-format.md`. For MCP mode, the subagent can use `mcp__codex__codex-reply` with `threadId` from Round 1 to continue the thread.

### Google (Antigravity / Gemini) (Round 2)
Dispatch a new `general-purpose` Agent subagent with full context + Round 1 synthesis + revision instructions. Reuse the same tool that succeeded in Round 1 (Antigravity or Gemini); if unknown, use the `agy → gemini` order again. Same reliability rules (timeout, no compounding retries, fast-fail) apply.

### Perplexity (Round 2)
Dispatch a new `general-purpose` Agent subagent with full context + Round 1 synthesis + revision instructions via Sonar API.

## Step 6: Round 3 (Rare — Only If Needed)

Only run Round 3 if Round 2 introduced **new critical or important conflicts**. Narrow focus to unresolved conflicts only. If still no convergence after Round 3, document both perspectives as dissenting opinions.

## Step 7: Final Report

Produce the final output using this exact format:

---

## Review Council Report

**Target:** [what was reviewed — PR #N, file path, etc.]
**Type:** [PR | Plan/Document | Code]
**Reviewers:** [list of reviewers that participated] ([N] participating — [skipped: reasons])
**Rounds:** [number of rounds run]
**Consensus:** [Strong | Moderate | Mixed]

### Critical Issues
[Findings multiple reviewers agree are critical. Must fix before merging/shipping.]

*If none: "No critical issues identified."*

### Important Findings
[Findings with broad agreement. Should fix.]

*If none: "No important findings."*

### Suggestions
[Lower-severity or single-reviewer findings worth considering.]

*If none: "No additional suggestions."*

### Dissenting Opinions
[Unresolved disagreements with both perspectives. Only include if genuinely unresolved after discussion.]

*If none: omit this section entirely.*

### What's Done Well
[Brief — things reviewers praised. Keep to 2-3 bullet points max.]

---

## Step 8: Cleanup

Remove any temporary files created during the review:

```bash
rm -f /tmp/rc-*-prompt.* /tmp/rc-perplexity-payload.json /tmp/rc-perplexity-response.json
```

Note: Subagents handle their own temp files, so this is a belt-and-suspenders cleanup for anything that leaked.

## Orchestration Rules

- **Max 3 rounds.** If no convergence, output what you have with both perspectives noted.
- **Substance over style.** Aggressively filter out nitpicks, formatting opinions, and subjective preferences.
- **Confidence from agreement.** Multiple reviewers flag it = high confidence. One reviewer = medium. Conflicting = note both.
- **Be actionable.** Every finding must say what to do, not just what's wrong.
- **Respect the user's time.** The output is a curated, prioritized list — not a dump of everything all reviewers said. Fewer high-quality findings > many low-quality ones.
- **Severity definitions:**
  - **Critical** — Will cause bugs, security vulnerabilities, data loss, or system failures. Blocks merge/ship.
  - **Important** — Significant quality, performance, or maintainability concern. Should fix.
  - **Suggestion** — Minor improvement opportunity. Nice to have.
