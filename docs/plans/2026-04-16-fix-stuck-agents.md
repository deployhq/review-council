# Fix Stuck Agents — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make review-council resilient to reviewer failures — validate output, notify users, and offer recovery options.

**Architecture:** Update 4 markdown instruction files that define the plugin's behavior. The delegation format becomes the single source of truth for review criteria and methodology. The orchestrator gains a validation + recovery step between dispatch and synthesis. The Claude reviewer agent is stripped of Bash and given pre-gathered context.

**Tech Stack:** Claude Code plugin (markdown-based skills, rules, and agent definitions)

**Spec:** `docs/specs/2026-04-16-fix-stuck-agents-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `rules/delegation-format.md` | Modify | Add 5-step review methodology, becomes single source of truth for all review criteria |
| `agents/reviewer-claude.md` | Modify | Remove Bash, set maxTurns 30, minimize to persona + output format + tool guidance |
| `rules/orchestration.md` | Modify | Add output validation rules, recovery flow, env var definitions |
| `skills/run/SKILL.md` | Modify | Embed baseline context in Claude prompt, add Step 4.5 (validate + recover), env var config |

---

### Task 1: Update delegation-format.md — Add Review Methodology

This must be done first because other files will reference it as the single source of truth.

**Files:**
- Modify: `rules/delegation-format.md`

- [ ] **Step 1: Add the 5-step review methodology to the template**

Insert a `## REVIEW PROCESS` section into the delegation template, between `## TASK` and `## CONTEXT`. This methodology is currently only in `agents/reviewer-claude.md` — moving it here means all reviewers (Claude, Codex, Gemini, Perplexity) get the same structured review process.

In `rules/delegation-format.md`, find the template section and add after `## TASK`:

```markdown
## REVIEW PROCESS
Follow these steps in order:
1. **Understand intent** — What is this PR/code/plan trying to achieve? Read carefully before judging.
2. **Evaluate correctness** — Does it achieve its stated goal? Are there logic errors, missed edge cases, or incorrect assumptions?
3. **Identify risks** — What could go wrong in production? Consider security, performance, reliability, data integrity, and failure modes.
4. **Check completeness** — What's missing? Error handling, tests, documentation, migration steps, rollback plans.
5. **Assess design** — Is this the right approach? Is there a simpler way? Will this be maintainable in 6 months?
```

- [ ] **Step 2: Update the "Why This Format" section**

Add a bullet explaining the new section. In the "Why This Format" section, add:

```markdown
- Gives every reviewer the same structured methodology, not just the same constraints
```

- [ ] **Step 3: Commit**

```bash
git add rules/delegation-format.md
git commit -m "feat: add review methodology to delegation format for all reviewers

Moves the 5-step review process (understand intent, evaluate correctness,
identify risks, check completeness, assess design) from the Claude-only
agent definition to the shared delegation format. All reviewers now get
the same structured methodology, improving council fairness."
```

---

### Task 2: Update agents/reviewer-claude.md — Minimal Agent Definition

**Files:**
- Modify: `agents/reviewer-claude.md`

- [ ] **Step 1: Replace the entire file contents**

The agent file becomes minimal — persona, output format, tool guidance only. All review methodology and criteria now come from the delegation prompt.

Replace the full contents of `agents/reviewer-claude.md` with:

```markdown
---
name: reviewer-claude
description: "Independent reviewer for the Review Council plugin. Provides thorough, substantive review as one member of a multi-agent council."
model: inherit
tools:
  - Read
  - Glob
  - Grep
maxTurns: 30
---

# Review Council — Claude Reviewer

You are an **independent expert reviewer** participating in a multi-agent review council. Other AI models are reviewing the same material simultaneously. Your reviews will be compared and synthesized.

## Your Role

Provide a thorough, honest, independent review. The value of this process comes from genuinely independent perspectives — do NOT try to be agreeable, hedge everything, or avoid controversy. If something is wrong, say so clearly.

## Tool Usage

You have access to Read, Glob, and Grep for targeted codebase verification. Use them to:
- Follow import chains to check callers/callees of changed code
- Verify type definitions and interfaces referenced in the diff
- Check if tests exist for changed functionality
- Confirm assumptions about how changed code is used elsewhere

Start by reviewing the context provided in your prompt. Use tools only when you need to verify something specific — do not explore the codebase broadly.

## Output Format

You MUST produce output with these exact sections:

### Findings

For each finding (max 10, prioritize by importance):

- **Severity**: `critical` | `important` | `suggestion`
- **Confidence**: `high` | `medium` | `low`
- **Location**: Specific `file:line` or section reference
- **Issue**: What's wrong (one clear sentence)
- **Why it matters**: Impact if not addressed
- **Recommendation**: Concrete fix or alternative approach

If you find no issues, write: "No issues found."

### What's Good

Brief list of things done well. Be genuine — if nothing stands out, say "Solid implementation, no standout positives to highlight" rather than inventing praise.

### Overall Assessment

One paragraph: Is this ready? What's the biggest risk? What's the single most important thing to address?
```

- [ ] **Step 2: Verify the frontmatter is valid**

Check that the YAML frontmatter has the correct structure by reading the file back:

Run: `head -8 agents/reviewer-claude.md`

Expected: YAML block with `tools: [Read, Glob, Grep]` and `maxTurns: 30`

- [ ] **Step 3: Commit**

```bash
git add agents/reviewer-claude.md
git commit -m "feat: overhaul Claude reviewer — remove Bash, minimize instructions

- Remove Bash from tools (no read-only mode available)
- Reduce tools to Read, Glob, Grep for targeted verification
- Set maxTurns to 30 (was 15, configurable via RC_CLAUDE_MAX_TURNS)
- Strip review methodology (now in delegation-format.md)
- Keep only: persona, tool guidance, output format
- Add explicit instruction to start from provided context"
```

---

### Task 3: Update rules/orchestration.md — Validation, Recovery, Env Vars

**Files:**
- Modify: `rules/orchestration.md`

- [ ] **Step 1: Add output validation rules**

Append the following new sections after the existing "Graceful Degradation" section in `rules/orchestration.md`:

```markdown
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

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `RC_CLAUDE_MAX_TURNS` | `30` | Max turns for Claude reviewer subagent |
| `RC_MIN_REVIEWERS` | `2` | Minimum successful reviewers for council mode |
| `RC_AUTO_RETRY` | `false` | If `true`, retry failed reviewers without asking |
```

- [ ] **Step 2: Commit**

```bash
git add rules/orchestration.md
git commit -m "feat: add output validation, recovery flow, and env var config

- Output validation: section presence + field-level checks
- Three outcomes: VALID, CLEAN, FAILED
- Recovery flow with conversational user prompt
- One retry max per reviewer, retried results merge into Round 1 pool
- RC_AUTO_RETRY for CI pipelines
- Env vars: RC_CLAUDE_MAX_TURNS, RC_MIN_REVIEWERS, RC_AUTO_RETRY"
```

---

### Task 4: Update skills/run/SKILL.md — Baseline Context, Validation Step, Env Vars

This is the largest change. The orchestrator gets: formalized baseline context, embedded Claude reviewer prompt, and a new Step 4.5 for validation and recovery.

**Files:**
- Modify: `skills/run/SKILL.md`

- [ ] **Step 1: Update Step 2 (Gather Context) to formalize the baseline context package**

Find the `## Step 2: Gather Context` section. Replace its content with:

```markdown
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
```

- [ ] **Step 2: Update the Claude reviewer dispatch in Step 3**

Find the `### Reviewer: Claude (native subagent) — Always` section. Replace it with:

```markdown
### Reviewer: Claude (native subagent) — Always

Use the `Agent` tool with `subagent_type: "reviewer-claude"`.

**Embed the full baseline context package and delegation prompt directly in the Agent tool's `prompt` parameter.** Build the prompt using the delegation format from `rules/delegation-format.md` with:
- TASK: the review type and what to review
- REVIEW PROCESS: included in the delegation format template
- CONTEXT: the complete baseline context package gathered in Step 2
- EXPECTED OUTCOME, CONSTRAINTS, MUST DO, MUST NOT DO, OUTPUT FORMAT: from the delegation format template

The Claude reviewer has Read, Glob, and Grep tools for targeted verification but should start reviewing from the context provided — not exploring broadly.
```

- [ ] **Step 3: Update the delegation prompt note**

Find the `### Delegation Prompt` section at the end of Step 3. Replace it with:

```markdown
### Delegation Prompt

For **all** reviewers (including Claude), use the delegation format from `rules/delegation-format.md`. The prompt structure and review criteria are identical for every provider — only the transport differs. The baseline context package from Step 2 goes into the CONTEXT section.
```

- [ ] **Step 4: Add Step 3.5 — Validate & Recover (between current Steps 3 and 4)**

Insert a new section after Step 3 (Round 1 dispatch) and before Step 4 (Analyze Round 1 Results). Renumber subsequent steps accordingly.

Add after the Round 1 dispatch step:

```markdown
## Step 3.5: Validate Round 1 Results & Recover

Before synthesis, validate each reviewer's output. Refer to `rules/orchestration.md` for validation rules.

### Validate

For each reviewer's response:
1. Check for `## Findings` (or `### Findings`) section — present?
2. Check for `## Overall Assessment` (or `### Overall Assessment`) section — present?
3. If Findings section exists and contains findings, check each finding has: **Severity**, **Location**, **Recommendation**
4. If Findings section says "No issues found" or equivalent — mark as CLEAN
5. If sections are missing or findings lack required fields — mark as FAILED

### Report & Recover

Count VALID, CLEAN, and FAILED results.

**If all VALID or CLEAN:** Announce results and proceed to synthesis.

```
Round 1 complete. All N reviewers produced valid output:
  Claude   [ok]  3 findings
  Codex    [ok]  5 findings
  Gemini   [clean]  no issues found
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
- Proceed to synthesis with the merged pool
```

- [ ] **Step 5: Renumber Steps 4-8 to 4.5-8.5 (or keep numbering with the insert)**

The current steps are numbered 0-8. After inserting Step 3.5, the numbering becomes:
- Step 0: Detect Available Providers (unchanged)
- Step 1: Detect Review Target (unchanged)
- Step 2: Gather Context (updated)
- Step 3: Round 1 — Independent Review (updated)
- Step 3.5: Validate & Recover (NEW)
- Step 4-8: unchanged (keep current numbering)

No renumbering needed — Step 3.5 slots in naturally.

- [ ] **Step 6: Commit**

```bash
git add skills/run/SKILL.md
git commit -m "feat: add validation step, baseline context, embedded Claude prompt

- Step 2: formalize baseline context package with mechanical gathering
- Step 3: Claude reviewer gets full context + delegation prompt inline
- Step 3.5: new validation & recovery step between dispatch and synthesis
- Output validation (section + field level), user-prompted retry
- RC_AUTO_RETRY support for CI pipelines
- All delegation prompts now use delegation-format.md uniformly"
```

---

### Task 5: Add Spec to Repository

**Files:**
- Add: `docs/specs/2026-04-16-fix-stuck-agents-design.md` (already exists on disk)

- [ ] **Step 1: Commit the spec**

```bash
git add docs/specs/2026-04-16-fix-stuck-agents-design.md
git commit -m "docs: add fix-stuck-agents design spec

Covers: output validation, recovery flow, Claude reviewer overhaul,
fairness baseline, env var configuration. Reviewed by council."
```

---

### Task 6: Final Verification

- [ ] **Step 1: Verify all files are consistent**

Read each modified file and check:
- `delegation-format.md` has the 5-step REVIEW PROCESS section
- `reviewer-claude.md` has tools: [Read, Glob, Grep], maxTurns: 30, no review methodology
- `orchestration.md` has Output Validation, Recovery Flow, Environment Variables sections
- `skills/run/SKILL.md` has baseline context package, embedded Claude prompt, Step 3.5

- [ ] **Step 2: Check for cross-file consistency**

Verify:
- The output format in `reviewer-claude.md` matches the OUTPUT FORMAT in `delegation-format.md`
- The env var names in `orchestration.md` match references in `skills/run/SKILL.md`
- The VALID/CLEAN/FAILED outcomes in `orchestration.md` match the validation logic in `skills/run/SKILL.md`
- The tool list in `reviewer-claude.md` frontmatter matches what `skills/run/SKILL.md` says about Claude's capabilities

- [ ] **Step 3: Commit plan file**

```bash
git add docs/plans/2026-04-16-fix-stuck-agents.md
git commit -m "docs: add implementation plan for fix-stuck-agents"
```
