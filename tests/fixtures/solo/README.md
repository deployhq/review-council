# Fixture: `solo`

Tier-2 fixture. See `tests/run-fixtures.sh` (header) for how/when to run this —
LOCAL / on-demand only, never CI.

## What it exercises

`repo/.review-council/config.yml` sets
`reviewers.{codex,google,perplexity}.enabled: false`, which — per Step 0.3 of
`skills/run/SKILL.md` ("Drop any provider whose `reviewer.<p>.enabled=false`
— it does not participate even if installed") — forces the roster down to
Claude (+ the always-on dedicated `reviewer-security`) **deterministically**,
regardless of which CLIs/API keys actually exist on the machine running the
harness. This is what lets `solo` be reproducible across machines instead of
depending on which providers happen to be absent.

Per the shared spec (§Refutation pass): "Skip entirely in solo-Claude mode
(only Claude available); do NOT self-verify (correlated-error theatre)." The
judge tags such findings `[1 reviewer · unverified]` in the report.

Note the distinction from the `budget` fixture: here the skip is because
**too few reviewer families exist to cross-verify** (solo mode is
unconditional — it skips even with a full/default `run_budget_seconds`); the
`budget` fixture instead exercises the **budget-exhausted** skip path with
the roster otherwise left alone.

## How to point the review at it

Point `/review-council:run` at `repo/src/example.py` with CWD set to `repo/`
so `.review-council/config.yml` resolves relative to the target repo.

## Assertions (what `run-fixtures.sh` checks)

**Hard (marker-based):**
- The literal phrase "single-reviewer mode" is announced (Step 0.3's
  existing, already-shipped wording for the solo-mode announcement).
- At least one of the unverified tags appears somewhere in the output:
  `[unverified]` or the canonical `[1 reviewer · unverified]` (exact wording is
  still LLM-mediated, so the harness matches on the tag shape, not an exact
  string).

**Soft / best-effort:**
- No routing-table / verifier-family chatter suggesting refutation actually
  ran (a full skip, not a degraded-but-still-ran pass).
