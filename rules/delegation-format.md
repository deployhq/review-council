# Delegation Format

When delegating to external models (Codex, Gemini, Perplexity, etc.), use this structured format to ensure consistent, comparable output regardless of the model's defaults.

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

## MUST DO
- Provide specific line/section references
- Explain WHY each finding matters
- Suggest a concrete fix for each finding
- Rate severity (critical/important/suggestion) and confidence (high/medium/low)

## MUST NOT DO
- Flag style/formatting nitpicks
- Flag pre-existing issues not in the diff
- Provide vague feedback without actionable recommendations
- Exceed 10 findings (focus on the most important)

## OUTPUT FORMAT
Structured markdown with: Findings (severity, confidence, location, issue, recommendation), What's Good, Overall Assessment.
```

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
1. Confirm or revise your original findings — retain original `file:line` anchors for traceability
2. For conflicts — explain your reasoning or concede if another reviewer's point is valid
3. Flag any new concerns you missed that other reviewers caught
4. Drop any findings you now consider less important after seeing the full picture

Use the same output format as Round 1. Keep original finding locations (`file:line`) stable so the orchestrator can track findings across rounds.
```

## Adding New Providers

When adding a new model provider, the delegation format stays the same. Only the transport changes. See `rules/providers.md` for the full provider registry with detection, CLI invocation, MCP fallback, and env requirements for each provider.
