# Fixture: `budget`

Tier-2 fixture. See `tests/run-fixtures.sh` (header) for how/when to run this —
LOCAL / on-demand only, never CI.

## What it exercises

`repo/.review-council/config.yml` sets `settings.run_budget_seconds: 1` — a
budget so small it is guaranteed to already be spent (per the orchestrator's
measured elapsed from the Round-1 CLI invocations) by the time Step 4
(refutation) runs its "Budget check FIRST" (§budget in the shared spec).

Per the shared spec (§Refutation pass / §Budget):
- "if `run_budget_seconds` is already spent ..., skip refutation, tag
  findings `[unverified]`, print `stopped at budget: <n>s`, go straight to
  the judge."
- "**Never hard-abort.**" — the run must still degrade gracefully and
  produce a complete final report, not crash or stop short.

Note the distinction from the `solo` fixture: here the roster is left at
its normal/default reviewer set (no `reviewers.*.enabled` overrides) — the
**budget**, not a thin roster, is what should force the degrade. (Caveat: if
the machine running this also happens to lack Codex/Google/Perplexity, the
roster collapses to solo anyway — the `stopped at budget: <n>s` marker
below is what distinguishes "budget forced it" from "solo forced it" in
that case.)

## How to point the review at it

Point `/review-council:run` at `repo/src/example.py` with CWD set to `repo/`
so `.review-council/config.yml` resolves relative to the target repo.

## Assertions (what `run-fixtures.sh` checks)

**Hard (marker-based, exact per the shared spec):**
- The line `stopped at budget: <n>s` appears in the output (any `<n>`).
- The run still completes and produces a full report (the "Review Council
  Report" header / equivalent is present) — i.e. it degraded, not aborted.

**Soft / best-effort:**
- Findings in the report carry an `[unverified]` tag (refutation was
  skipped for the budget reason, not evaluated).
