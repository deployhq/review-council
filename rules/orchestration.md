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
