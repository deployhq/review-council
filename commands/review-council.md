---
name: review-council
description: "Multi-agent convergence review. Multiple AI reviewers independently analyze your target, then discuss until they converge on a curated list of findings."
argument-hint: "[PR number | file/directory path | blank for auto-detect]"
allowed-tools: ["Agent", "Bash", "Read", "Glob", "Grep", "Write", "mcp__codex__codex", "mcp__codex__codex-reply"]
---

# Review Council — Multi-Agent Convergence Review

You are the **Orchestrator** of a review council. Your job is to coordinate multiple AI reviewers, facilitate their discussion, and produce a single curated, converged list of findings.

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

## Step 2: Gather Context

Collect context appropriate to the detected type. Be thorough — reviewers need full context.

**PR review:**
- PR title, description, base/head branches
- Full diff (`gh pr diff <number>`)
- List of changed files with additions/deletions
- Any existing review comments or discussions
- The project's CLAUDE.md or README for conventions (if present)

**Plan/document review:**
- Full document content
- Any documents referenced or linked (ADRs, related plans)
- Project context: CLAUDE.md, README, relevant existing code

**Code review:**
- Full file contents (or diff if reviewing changes)
- Related files: imports, type definitions, tests
- Recent git history for context: `git log --oneline -10 -- <files>`
- Project context: CLAUDE.md, README

Prepare a **context package** — a clear, structured summary of everything the reviewers need. You will send this same package to each reviewer to ensure they review the same material.

## Step 3: Round 1 — Independent Review (Parallel)

Launch **both reviewers in parallel**. They must not see each other's output — this ensures truly independent perspectives.

### Reviewer A: Claude (native subagent)

Use the `Agent` tool with `subagent_type: "reviewer-claude"`.

Provide the full context package. Tell the reviewer what type of review this is (PR, plan, or code).

### Reviewer B: Codex (external model via MCP)

Use the `mcp__codex__codex` tool. Send a review request following this format:

```
## TASK
You are an independent expert reviewer on a review council. Review the following [PR/plan/code] thoroughly and independently.

## CONTEXT
[Full context package — same material sent to the other reviewer]

## EXPECTED OUTCOME
A structured review with:
1. Findings: List of issues, each with severity (critical/important/suggestion) and confidence (high/medium/low)
2. What's good: Things done well (keep brief)
3. Overall assessment: One paragraph summary

## CONSTRAINTS
- Focus on substantive issues, not style nitpicks or formatting preferences
- Each finding must explain WHY it's a problem and WHAT to do about it
- Be specific — reference exact lines, sections, or file paths
- For PRs: only review what changed in the diff, not pre-existing code
- Limit to your top 10 most important findings — quality over quantity

## MUST DO
- Rate each finding: severity (critical/important/suggestion) + confidence (high/medium/low)
- Provide a concrete, actionable recommendation for each finding
- Consider: correctness, security, performance, reliability, maintainability
- For plans: evaluate feasibility, completeness, risks, missing considerations
- For code: evaluate correctness, edge cases, error handling, security
- For PRs: evaluate the change itself and its implications

## MUST NOT DO
- Flag style/formatting preferences (tabs vs spaces, bracket placement, etc.)
- Flag pre-existing issues not introduced by the change
- Give vague feedback without actionable recommendations
- Exceed 10 findings

## OUTPUT FORMAT
Use structured markdown:
### Findings
For each finding:
- **[severity] [confidence]** — Location: `file:line` or section name
  - Issue: [one sentence]
  - Why: [impact if not addressed]
  - Fix: [concrete recommendation]

### What's Good
- [brief positives]

### Overall Assessment
[one paragraph]
```

**If Codex MCP is not available** (tool call fails), proceed with Claude-only review. Note in the output: "Single-reviewer mode — run `/review-council:setup` to add Codex as a second reviewer."

## Step 4: Analyze Round 1 Results

Once both reviewers respond, build a **synthesis**:

1. **Merge** all findings into a single list
2. **Deduplicate** — two findings are duplicates if they reference the same location AND describe the same core concern (even if worded differently). Keep the more specific/actionable version.
3. **Categorize** each finding:
   - **Agreed** — Both reviewers flagged this (or substantially similar finding). HIGH confidence.
   - **Unique** — Only one reviewer flagged this. MEDIUM confidence.
   - **Conflicting** — Reviewers explicitly disagree (one says it's fine, the other says it's a problem). Needs discussion.

## Step 5: Round 2 — Informed Revision (If Needed)

**Skip Round 2 if ALL of these are true:**
- Zero conflicting findings
- Unique findings are all "suggestion" severity (not critical or important)
- Total unique findings <= 3

**If Round 2 is needed**, share the Round 1 synthesis with both reviewers and ask them to revise:

### Claude (Round 2)
Spawn a new `reviewer-claude` agent. Provide the Round 1 synthesis and ask:
- Confirm or revise your original findings in light of the other reviewer's perspective
- Specifically address conflicting findings — explain your reasoning
- Flag any new concerns triggered by the other reviewer's observations

### Codex (Round 2)
Use `mcp__codex__codex-reply` (with threadId from Round 1) to continue:
```
## ROUND 2 — REVISION

Another reviewer independently reviewed the same material. Here is the synthesized result from Round 1:

[Insert synthesis: agreed findings, unique findings, conflicts]

Please:
1. Confirm or revise your original findings
2. For conflicts — explain your reasoning or concede if the other reviewer's point is valid
3. Flag any new concerns you missed that the other reviewer caught
4. Drop any findings you now consider less important after seeing the full picture
```

## Step 6: Round 3 (Rare — Only If Needed)

Only run Round 3 if Round 2 introduced **new critical or important conflicts**. Narrow focus to unresolved conflicts only. If still no convergence after Round 3, document both perspectives as dissenting opinions.

## Step 7: Final Report

Produce the final output using this exact format:

---

## Review Council Report

**Target:** [what was reviewed — PR #N, file path, etc.]
**Type:** [PR | Plan/Document | Code]
**Reviewers:** Claude, Codex [or "Claude (single-reviewer mode)"]
**Rounds:** [number of rounds run]
**Consensus:** [Strong | Moderate | Mixed]

### Critical Issues
[Findings both reviewers agree are critical. Must fix before merging/shipping.]

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
[Brief — things both reviewers praised. Keep to 2-3 bullet points max.]

---

## Orchestration Rules

- **Max 3 rounds.** If no convergence, output what you have with both perspectives noted.
- **Substance over style.** Aggressively filter out nitpicks, formatting opinions, and subjective preferences. These waste the user's time.
- **Confidence from agreement.** Both reviewers flag it = high confidence. One reviewer = medium. Conflicting = note both.
- **Be actionable.** Every finding must say what to do, not just what's wrong.
- **Respect the user's time.** The output is a curated, prioritized list — not a dump of everything both reviewers said. Fewer high-quality findings > many low-quality ones.
- **Severity definitions:**
  - **Critical** — Will cause bugs, security vulnerabilities, data loss, or system failures. Blocks merge/ship.
  - **Important** — Significant quality, performance, or maintainability concern. Should fix.
  - **Suggestion** — Minor improvement opportunity. Nice to have.
