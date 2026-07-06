---
description: Multi-agent convergence review. Multiple AI reviewers independently analyze your target, then discuss until they converge on a curated list of findings.
argument-hint: "[PR number | file/directory path | blank for auto-detect]"
allowed-tools: Agent, Bash, Read, Glob, Grep, Write, mcp__codex__codex, mcp__codex__codex-reply
---

# Review Council — Multi-Agent Convergence Review

You are the **Orchestrator** of a review council. Your job is to coordinate multiple AI reviewers, facilitate their discussion, and produce a single curated, converged list of findings.

## Step 0: Detect Available Providers

Before doing anything else, probe which reviewers are available. Refer to `rules/providers.md` for detection methods.

Run these checks in parallel:

1. **Claude**: Always available.
2. **Codex**: Run `which codex 2>/dev/null`. If found, mark as available (CLI). If not, check if `mcp__codex__codex` tool is available — if so, mark as available (MCP). Otherwise, unavailable.
3. **Google (Antigravity / Gemini)** — a single slot shared by both Google CLIs (see `rules/providers.md` → "Google-family reviewer"). Run `which agy 2>/dev/null` and `which gemini 2>/dev/null`. Resolve the slot:
   - Both found → available; primary `agy`, fallback `gemini`.
   - Only `agy` → available via `agy`. Only `gemini` → available via `gemini`.
   - Neither → unavailable.
   Never count this as two reviewers. Announce which tool will run (and that a fallback exists, if any).
4. **Perplexity**: Run `test -n "$PERPLEXITY_API_KEY" && echo "available" || echo "unavailable"`.

Announce: "**Review Council** — [N] reviewers available: [list]. [Skipped: reason for each unavailable provider]"

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
> - Wrap each invocation with a hard timeout so it can't hang forever. Resolve the binary first (it may be `timeout` or, on macOS, `gtimeout`, or absent), then use a portable `if`/`else` (works in bash, sh, and zsh): `TO="$(command -v timeout || command -v gtimeout || true)"` then `if [ -n "$TO" ]; then "$TO" "${RC_REVIEWER_TIMEOUT:-600}" codex …; else codex …; fi`. Exit code 124 = timed out = failure. Do NOT use `${TO:+$TO 600}` — it word-splits in bash but not zsh. If no timeout binary exists, run bare but still obey the next two rules strictly.
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

Dispatch a `general-purpose` Agent with this prompt. Pass the ordered tool list resolved in Step 0 — `agy` then `gemini` if both are installed, or whichever single tool is available:

> You are invoking the Google-family reviewer (Antigravity `agy`, with Gemini `gemini` as fallback) for a Review Council review. Your job is to call the CLI, collect its response, and return the structured findings. Try the tools in this order: **[ordered tool list, e.g. `agy`, then `gemini`]**.
>
> For each tool in order:
>
> **Step 1: Discover CLI syntax.** Run `<tool> --help` to learn the available subcommands and flags. Do NOT assume any specific flags exist — always derive the correct invocation from the help output. (Hints verified against agy 1.0.16: `agy -p "<prompt>"` runs one prompt non-interactively and prints the response; optional `--add-dir <repo>`, `--model <name>`, and `--dangerously-skip-permissions` to avoid blocking on approvals in a non-TTY — agy print mode self-limits via `--print-timeout` (default 5m) — for the default 10m budget, pass `--print-timeout 10m` (or match `RC_REVIEWER_TIMEOUT`) so agy doesn't cut off before the outer timeout. `gemini` uses `gemini -p "<prompt>"` and may need `--skip-trust` or `GEMINI_CLI_TRUST_WORKSPACE=true` for headless/non-TTY runs.)
>
> **Step 2: Invoke the tool.** Write the delegation prompt to `/tmp/rc-google-prompt.md`, then use the syntax you discovered to run the tool in non-interactive mode with the prompt content and text output.
>
> **Reliability rules — apply to every CLI call (see `rules/orchestration.md` → "Reviewer Timeouts & Fast-Fail"):**
> - Wrap each invocation with a hard timeout so it can't hang forever. Resolve the binary first (it may be `timeout` or, on macOS, `gtimeout`, or absent), then use a portable `if`/`else` (works in bash, sh, and zsh): `TO="$(command -v timeout || command -v gtimeout || true)"` then `if [ -n "$TO" ]; then "$TO" "${RC_REVIEWER_TIMEOUT:-600}" <tool> …; else <tool> …; fi`. Exit code 124 = timed out = failure. Do NOT use `${TO:+$TO 600}` — it word-splits in bash but not zsh. If no timeout binary exists, run bare but still obey the next two rules strictly.
> - Do NOT loop with compounding retries. At most ONE retry per tool, and only for a single clearly-transient blip (e.g. one network hiccup). Do NOT chase a provider's own model auto-fallback across many backoff attempts.
> - Fast-fail a tool immediately (move to the next tool, no further retries) when the output or error shows an auth failure (`no longer supported`, `not authenticated`, `please migrate to the Antigravity`, `secret keyring is locked`), a quota/rate cap (HTTP 429, `exhausted your daily quota`, `TerminalQuotaError`, `rate limit`), or persistent overload (HTTP 503 / `high demand` past the timeout). A dead provider must fail in minutes, not tens of minutes.
>
> **Fallback:** If the first tool fast-fails or is unavailable, move to the next tool in the list and repeat Steps 1–2.
>
> **On success:** Return the full structured review output (Findings, What's Good, Overall Assessment), and note which tool produced it — prefix your answer with `TOOL: Antigravity` (for `agy`) or `TOOL: Gemini` (for `gemini`).
>
> **If every tool fails**: Return "SKIPPED: Google (Antigravity/Gemini) unavailable — [error details for each tool tried]"

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
> Fast-fail (return SKIPPED, no retry) on an HTTP 401/403 auth error or 429 rate cap; do not loop on retries.
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
