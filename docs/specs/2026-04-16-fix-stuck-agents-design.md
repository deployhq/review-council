# Fix Stuck Agents — Design Spec

## Problem

Review-council reviewers — particularly the Claude subagent — frequently fail to produce structured output. The Claude reviewer (`review-council:reviewer-claude`) gets lost exploring the codebase instead of reviewing and producing findings. When this happens:

1. The user gets no feedback about what went wrong until the final report
2. There is no way to recover — the review proceeds with fewer reviewers, undermining the "council" value proposition
3. Tokens are wasted on a reviewer that produced nothing useful

Secondary issues:
- Reviewers have asymmetric capabilities and instructions, making the council unfair
- No output validation — malformed output silently corrupts synthesis
- No user control over retry behavior or token spend

## Design

### 1. Fairness — Identical Baseline for All Reviewers

The orchestrator builds a **baseline context package** in Steps 2-3, identical for every reviewer:

- Full diff
- Complete file contents for changed files
- Git log for changed files: `git log --oneline -10 -- <changed_files>`
- Git blame for changed lines: `git blame -L <start>,<end> -- <file>` for each changed hunk
- PR metadata (if applicable): `gh pr view <number> --json title,body,baseRefName,headRefName`
- Project conventions: raw contents of CLAUDE.md, CONTRIBUTING.md (if they exist)

The baseline is gathered mechanically — exact commands, raw output, no interpretive summaries. This minimizes orchestrator bias in what reviewers see.

All reviewers receive this baseline context + the same delegation prompt (the 7-section format from `delegation-format.md`). This is the fair starting point.

**Exploration is each reviewer's own business.** Each reviewer can go deeper using its own capabilities:

| Reviewer | Exploration capability |
|---|---|
| Claude | Read, Glob, Grep (codebase tools via subagent) |
| Codex | Own file access via CLI |
| Gemini | Own file access via CLI |
| Perplexity | None (API-only), but brings web/ecosystem knowledge |

The baseline ensures nobody starts from zero. The exploration is where plurality lives — each model notices different things based on its own judgment about what to investigate. The orchestrator intentionally does NOT pre-gather enriched context (callers, imports, etc.) because that would bias all reviews through Claude's perspective on what's relevant.

### 2. Claude Reviewer Overhaul

**Keep the named agent definition** (`agents/reviewer-claude.md`) for tool restriction, but restructure how it's used.

#### Agent definition changes

```yaml
tools: [Read, Glob, Grep]   # was: [Read, Glob, Grep, Bash]
maxTurns: 30                 # was: 15. Configurable via RC_CLAUDE_MAX_TURNS
```

Bash is removed because there is no read-only Bash mode. Read + Glob + Grep cover all read-only exploration needs (follow imports, check callers, find related files). Git context is pre-gathered in the baseline (including full `git log` with diffs for changed files to compensate for the lack of direct git access).

`maxTurns` defaults to 30 — double the current 15, generous for verification after receiving the full baseline context. The real fix is embedding context in the prompt so the reviewer starts reviewing from turn 1. If that works, 30 is plenty. If it doesn't, a higher limit just multiplies the token waste. Users can override via `RC_CLAUDE_MAX_TURNS`.

#### Instructions become minimal

The agent file provides only:
- Reviewer persona ("you are one member of a multi-agent review council")
- Output format specification (Findings, What's Good, Overall Assessment)
- Tool guidance ("use Read/Grep/Glob to verify specific concerns — follow callers, check imports, confirm assumptions")

Everything else (review criteria, MUST DO / MUST NOT DO, constraints, review methodology) comes from the delegation prompt the orchestrator builds. The 5-step review methodology currently in `reviewer-claude.md` (understand intent, evaluate correctness, identify risks, check completeness, assess design) must be moved to `delegation-format.md` so all reviewers get the same structured review process. This eliminates duplication and improves fairness — all reviewers now share review criteria AND methodology.

#### Orchestrator embeds context in the prompt

Instead of the Claude reviewer independently gathering context, the orchestrator passes the full baseline context + delegation format inline in the Agent tool's `prompt` parameter. The reviewer starts reviewing from turn 1 and uses tools only for targeted verification.

### 3. Output Validation & Recovery Flow

After all reviewers return from Round 1, the orchestrator validates each result.

#### Validation check

**Section presence:**
- `## Findings` (or equivalent structured findings list)
- `## Overall Assessment`

**Field-level validation (for each finding):**
- Must have severity (critical/important/suggestion)
- Must have location (file:line or section reference)
- Must have recommendation (concrete fix or alternative)
- Findings missing required fields are flagged — the reviewer's output is marked FAILED

**Zero-finding case:**
- A reviewer that returns "## Findings\n\nNo issues found" with a valid Overall Assessment is a legitimate "clean" review, not a failure. This is tracked as a distinct CLEAN outcome.

#### Three outcomes per reviewer

1. **VALID** — has required sections with properly structured findings, proceed to synthesis
2. **CLEAN** — has required sections, reviewer explicitly found no issues. Valid but contributes no findings to synthesis.
3. **FAILED** — returned but output is malformed, missing required sections, or findings lack required fields

#### User notification and recovery prompt

After validation, the orchestrator reports results conversationally and asks the user what to do. This is a natural language question, not a programmatic menu — Claude Code supports conversational back-and-forth within a skill invocation.

Example:

```
Round 1 complete:
  Codex    [ok]  4 findings
  Gemini   [ok]  6 findings
  Claude   [FAILED]  no structured findings produced

Council requires 2+ reviewers. 2 of 3 succeeded.

Should I retry the failed reviewer (will use additional tokens), proceed with the 2 successful reviews, or abort?
```

Decision logic:
- All valid (or clean): proceed to synthesis (no prompt needed)
- Some failed, enough remain for council (>= RC_MIN_REVIEWERS): ask user — retry, proceed, or abort
- Some failed, not enough for council: ask user — retry or abort, noting that proceeding means single-reviewer mode
- All failed: abort with error

**One retry attempt max.** If a reviewer fails twice, mark as unavailable and move on. This prevents infinite retry loops.

**RC_AUTO_RETRY=true** skips the interactive prompt and retries automatically (for CI/automated pipelines).

### 4. Environment Variables

All configuration via environment variables with sensible defaults:

| Variable | Default | Purpose |
|---|---|---|
| `RC_CLAUDE_MAX_TURNS` | `30` | Max turns for Claude reviewer subagent |
| `RC_MIN_REVIEWERS` | `2` | Minimum successful reviewers for council mode |
| `RC_AUTO_RETRY` | `false` | If `true`, retry failed reviewers without asking |

Design principles:
- No wall-clock timeout (Claude Code subagents don't support it)
- No per-reviewer configuration (keeps it simple)
- Env vars are easy to set, easy to override per-run, no files to manage

### 5. Orchestrator Changes (skills/run/SKILL.md)

The existing 8-step flow is preserved. Changes:

**Step 3 (Gather Context)** — Formalizes the baseline context package as an explicit, named artifact that all reviewers receive identically. No change to what's gathered, just clarity that this is the shared baseline.

**Step 3 (Round 1 Dispatch)** — Two changes:
- Claude reviewer prompt now embeds the full baseline context + delegation format inline
- All reviewers get the identical delegation prompt with baseline context

**New Step 3.5 (Validate & Recover):**
- Validate each reviewer's output against required sections
- Count valid / failed / clean results
- If all valid/clean: proceed to synthesis
- If any failed: report to user conversationally, ask whether to retry/proceed/abort
- If user chooses retry: re-dispatch only failed reviewers, validate again
- One retry max per reviewer — fail twice, mark unavailable, move on
- Retried results merge into the Round 1 pool before synthesis begins — all validated results (first-pass and retried) are treated identically

**Steps 5-8** — Unchanged, except synthesis only uses validated results.

### 6. Files Changed

| File | Change |
|---|---|
| `agents/reviewer-claude.md` | Remove Bash from tools, set maxTurns to 30, minimize instructions to persona + output format + tool guidance |
| `skills/run/SKILL.md` | Embed baseline context in Claude reviewer prompt, add Step 4.5 (validation + recovery), read env vars for config |
| `rules/orchestration.md` | Add output validation rules (section + field level), recovery flow, env var definitions |
| `rules/delegation-format.md` | Add 5-step review methodology (moved from reviewer-claude.md) so all reviewers share the same process |
| `rules/providers.md` | No changes |

### 7. Future Considerations

**Agent Teams (v2):** Claude Code's experimental Agent Teams feature would allow reviewers to directly discuss findings with each other instead of the orchestrator mediating convergence rounds. Note: this would be a parallel implementation path, not an incremental evolution of the current architecture — the mediator pattern (orchestrator owns synthesis) and peer-to-peer pattern (reviewers discuss directly) are fundamentally different. The current subagent architecture should be maintained independently even if Agent Teams support is added later. Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` opt-in.

**NEEDS_CONTEXT flow:** A future enhancement where reviewers can signal they need more information. Would require adding instructions to the delegation format telling reviewers how to signal this (e.g., a `## NEEDS_CONTEXT` output section). Deferred from v1 to keep the validation logic simple.

**Additional env vars:** Per-reviewer configuration, per-provider cost controls, and context enrichment toggles could be added later based on user feedback. Starting minimal. The retry prompt already notes that retrying uses additional tokens.
