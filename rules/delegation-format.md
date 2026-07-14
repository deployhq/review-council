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

## Refutation Template (Step 4)

The refutation pass (Step 4 of `skills/run/SKILL.md`) replaces the old anchoring "share the synthesis, revise toward it" round. Instead of showing a reviewer the merged result and asking it to converge, the orchestrator hands candidate findings to a **fresh, cross-family** verifier that has **never seen** any other reviewer's output or any synthesis, and asks it to try to **refute** each finding against the actual code. That isolation is the whole point: an UPHELD is then independent corroboration, and a REFUTED is a genuine counter-finding — neither is social agreement with a shown conclusion.

Send this block, with the assigned findings pasted in (each given a short `<finding-id>` so verdicts map back):

```
## REFUTATION

Here are the candidate findings assigned to you. You are NOT shown any other reviewer's output or any synthesis — judge each finding only against the actual code.

For each finding, try to **REFUTE** it: Read/Grep the cited `location`, trace the enclosing `symbol` and its callers/callees, and gather evidence about whether the concern is real. Return exactly one verdict per finding, citing the specific line or traced symbol as evidence:

- **UPHELD** — you found positive supporting evidence that the finding is real (cite the line / traced symbol).
- **REFUTED** — you found positive **counter-evidence** that it is NOT a bug (cite it — e.g. the guard that already handles the case, the caller that never passes null).
- **INCONCLUSIVE** — you lack the means to decide (e.g. it's a runtime/race condition you cannot execute here, or the needed context isn't in reach).

Do **NOT** default to REFUTED — absence of proof is **INCONCLUSIVE**, never REFUTED. Only positive counter-evidence is REFUTED.

Return one line per finding:
  <finding-id> | UPHELD | REFUTED | INCONCLUSIVE — <one-sentence evidence, with the cited location>
```

This pass is **isolated per verifier**: each verifier sees only the findings routed to it, plus the baseline context — never the full council output. The orchestrator batches all findings routed to a given family into **one** fresh subagent (see Step 4). A verdict is only valid from a fresh Agent spawn; a finding with no spawn is `[unverified]`, not refuted.

## Adding New Providers

When adding a new model provider, the delegation format stays the same. Only the transport changes. See `rules/providers.md` for the full provider registry with detection, CLI invocation, MCP fallback, and env requirements for each provider.
