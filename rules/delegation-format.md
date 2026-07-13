# Delegation Format

When delegating to external models (Codex, Antigravity, Gemini, Perplexity, etc.), use this structured format to ensure consistent, comparable output regardless of the model's defaults.

## Template

```
## TASK
[What to review and in what capacity]

## REVIEW PROCESS
Follow these steps in order:
1. **Understand intent** — What is this PR/code/plan trying to achieve? Read carefully before judging.
2. **Evaluate correctness** — Does it achieve its stated goal? Are there logic errors, missed edge cases, or incorrect assumptions?
3. **Identify risks** — What could go wrong in production? Consider security, performance, reliability, data integrity, and failure modes.
4. **Check completeness** — What's missing? Error handling, tests, documentation, migration steps, rollback plans.
5. **Assess design** — Is this the right approach? Is there a simpler way? Will this be maintainable in 6 months?

## CONTEXT
[Full context: diff, file contents, plan text, etc.]

## EXPECTED OUTCOME
[What the output should look like]

## CONSTRAINTS
[Focus areas, what to ignore, limits]
- For PRs: focus on what the change introduces, what it might break, and whether it achieves its stated goal
- For plans: focus on feasibility, completeness, risks, and missing considerations
- For code: focus on correctness, security, performance, error handling, and maintainability

## MUST DO
- Provide a specific `location` (file:line or section reference) and `symbol` (enclosing function/class/section — write "N/A" if none applies) for every finding
- Explain WHY each finding matters — include the impact, not just the symptom (e.g., "This will crash because user can be null when session expires" not just "This could be better")
- Suggest a concrete fix or alternative for each finding
- Give a concrete, human-runnable `how_to_verify` step (a command/input/trace to run, plus the expected observation) for each finding
- Rate `severity` (critical/important/suggestion) and `confidence` (high/medium/low) — your own, pre-synthesis judgment
- Also assess test adequacy: are the change's new/changed behaviors covered by tests, and are the important edge cases tested? Flag material gaps (not trivial coverage).
- Quality over quantity — if the code/plan is good, say so and keep findings minimal
- Cap **suggestions** at ~5 per review; do **not** cap `critical` or `important` findings — report every one you find

## MUST NOT DO
- Flag theoretical risks that require unlikely preconditions
- Flag defense-in-depth suggestions when the primary defense is already adequate
- Flag pure style / formatting / naming preferences
- Flag pre-existing issues outside the change's blast radius — review what the change *affects* (including unshown callers), not unrelated legacy code
- Flag speculative "could be a problem" concerns with no concrete trigger
- Flag anything matching a recalled learnings suppression (`.review-council/learnings.md`), unless you can argue the context has changed
- Provide vague feedback without actionable recommendations

## OUTPUT FORMAT
Structured markdown with: Findings, What's Good, Overall Assessment.

Each finding must use these exact field names:
- `severity`:       critical | important | suggestion
- `confidence`:     high | medium | low (your own, pre-synthesis judgment)
- `location`:       <relpath>:<line>
- `symbol`:         <enclosing function/class/section, if any — write "N/A" if none applies>
- `concern`:        <short free-form kebab-case slug hinting at the issue, e.g. missing-null-check> — a HINT only, not a canonical fingerprint
- `issue`:          one sentence — what's wrong
- `why_it_matters`: impact if left unaddressed
- `recommendation`: concrete fix or alternative
- `how_to_verify`:  a concrete, HUMAN-runnable check (command/input/trace) + the expected observation — nothing executes this automatically in this phase
- `source`:         <your reviewer-id>

If you find no issues, write "No issues found" in Findings. Keep the What's Good and Overall Assessment sections.
```

## LENS

Immediately after the `## TASK` line, the orchestrator prepends a short lens block to each reviewer's delegation payload — it sits at the top of the review payload, right alongside the task, before `## REVIEW PROCESS`:

```
## LENS
Your emphasis this review: <lens-name> — <focus areas>
```

For example: `performance — hot paths, loops, queries, caching, concurrency`, or `cross_file — exported signatures, response shapes, API-contract breaks`. The lens assigned to each reviewer for a given run — and its focus areas — come from the lens catalog in `rules/config.md`'s `lenses:` block, classified against the diff being reviewed; this file only defines the wire format of the block itself, not the assignment logic.

**Lens = emphasis, not blinders.** The lens tells a reviewer where to look first and dig deepest — it never narrows what the reviewer is allowed to flag. Every reviewer still runs the full `## REVIEW PROCESS` over the complete context, and still has a floor obligation to flag any `critical`-severity finding it notices outside its assigned lens.

When `settings.personas` is `false`, omit the `## LENS` block entirely — every reviewer receives the identical, non-lens prompt (legacy behavior).

## Why This Format

Different models have different defaults for verbosity, structure, and focus. This format:
- Forces structured output that can be programmatically compared
- Sets clear boundaries on scope and quantity
- Ensures every finding is actionable (not just "this looks wrong")
- Makes deduplication possible across reviewers
- Gives every reviewer the same structured methodology, not just the same constraints

## Round 2 — Revision Template

When the orchestrator triggers a second round, send this to each provider along with the original context and Round 1 synthesis:

```
## ROUND 2 — REVISION

Other reviewers independently reviewed the same material. Here is the synthesized result from Round 1:

[Insert synthesis: agreed findings, unique findings, conflicts]

Please:
1. Confirm or revise your original findings — retain original `location` (and `symbol`) anchors for traceability
2. For conflicts — explain your reasoning or concede if another reviewer's point is valid
3. Flag any new concerns you missed that other reviewers caught
4. Drop any findings you now consider less important after seeing the full picture

Use the same output format as Round 1 (see OUTPUT FORMAT above). Keep original `location` values stable so the orchestrator can track findings across rounds.
```

(The confirm/revise/rebut mechanics above are a placeholder — the actual refutation pass is designed in PR 1c.)

## Adding New Providers

When adding a new model provider, the delegation format stays the same. Only the transport changes. See `rules/providers.md` for the full provider registry with detection, CLI invocation, MCP fallback, and env requirements for each provider.
