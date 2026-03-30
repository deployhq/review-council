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
3. **Gemini**: Run `which gemini 2>/dev/null`. If found, mark as available (CLI). If not, check if Gemini MCP tool is available. Otherwise, unavailable.
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

Launch **all available reviewers in parallel**. They must not see each other's output — this ensures truly independent perspectives.

### Reviewer: Claude (native subagent) — Always

Use the `Agent` tool with `subagent_type: "reviewer-claude"`.

Provide the full context package. Tell the reviewer what type of review this is (PR, plan, or code).

### Reviewer: Codex — If Available

**CLI mode** (preferred): Use the `Bash` tool to invoke Codex CLI. Write the delegation prompt (from `rules/delegation-format.md`) to a temp file, then run:

```bash
codex exec --full-auto -q "$(cat /tmp/rc-codex-prompt.md)"
```

**MCP mode** (fallback): Use the `mcp__codex__codex` tool. Send the delegation prompt following the format in `rules/delegation-format.md`.

**If invocation fails** (CLI exits non-zero, MCP tool errors): Note in output that Codex was skipped this round. Do not retry — proceed with other reviewers.

### Reviewer: Gemini — If Available

**CLI mode** (preferred): Use the `Bash` tool to invoke Gemini CLI:

```bash
gemini -p "$(cat /tmp/rc-gemini-prompt.md)" -o text
```

**MCP mode** (fallback): Use the Gemini MCP tool if configured.

**If invocation fails**: Note in output that Gemini was skipped. Proceed with other reviewers.

### Reviewer: Perplexity — If Available

Use the `Bash` tool to call the Sonar API:

```bash
curl -s https://api.perplexity.ai/chat/completions \
  -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/rc-perplexity-payload.json
```

Where `/tmp/rc-perplexity-payload.json` contains:
```json
{
  "model": "sonar",
  "messages": [{"role": "user", "content": "DELEGATION_PROMPT_HERE"}]
}
```

Parse the response JSON to extract `.choices[0].message.content`.

**If invocation fails**: Note in output that Perplexity was skipped. Proceed with other reviewers.

### Delegation Prompt

For all non-Claude reviewers, use the delegation format from `rules/delegation-format.md`. The prompt is identical for every provider — only the transport differs.

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

**CLI mode**: Fresh `codex exec` call with the full original context + Round 1 synthesis. Include the Round 2 revision instructions from `rules/delegation-format.md`.

**MCP mode**: Use `mcp__codex__codex-reply` with `threadId` from Round 1 to continue the thread.

### Gemini (Round 2)
Fresh CLI/MCP call with full context + Round 1 synthesis + revision instructions.

### Perplexity (Round 2)
Fresh curl call with full context + Round 1 synthesis + revision instructions.

## Step 6: Round 3 (Rare — Only If Needed)

Only run Round 3 if Round 2 introduced **new critical or important conflicts**. Narrow focus to unresolved conflicts only. If still no convergence after Round 3, document both perspectives as dissenting opinions.

## Step 7: Final Report

Produce the final output using this exact format:

---

## Review Council Report

**Target:** [what was reviewed — PR #N, file path, etc.]
**Type:** [PR | Plan/Document | Code]
**Reviewers:** [list of reviewers that participated] ([N] of 4 available — [skipped: reasons])
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
