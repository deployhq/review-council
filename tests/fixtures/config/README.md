# Fixture: `config`

Tier-2 fixture. See `tests/run-fixtures.sh` (header) for how/when to run this —
LOCAL / on-demand only, never CI.

## What it exercises

`repo/.review-council/config.yml` (team defaults) + `config.local.yml`
(per-machine override) together exercise:

1. **Precedence, per key** (`env > config.local.yml > config.yml > built-in
   default`, per `rules/config.md`):
   - `settings.verify` is set to `false` in `config.yml` and `true` in
     `config.local.yml` — the local layer must win, so the **effective**
     value is `true`.
   - `settings.min_reviewers` is set to `3` in `config.yml` only —
     `config.local.yml` doesn't mention it, so it must still resolve to `3`
     (from `config.yml`), not silently fall back to the built-in default of
     `2`. This is the half of the precedence check that catches an
     implementation that treats "local file present" as "local wins on
     every key" instead of the correct **per-key** precedence.
2. **A lens pin**: `config.yml` pins `lenses.security.providers: [google]`.
   Per `rules/config.md`, an explicit `security.providers` pin also flips
   `lens.security.replaces_dedicated` to `true` (the pin replaces the
   dedicated `reviewer-security` subagent rather than adding to it).

## How to point the review at it

Point `/review-council:run` at `repo/src/example.py` with CWD set to `repo/`
so `.review-council/config.yml` / `config.local.yml` resolve relative to the
target repo (Step 0.1 of `skills/run/SKILL.md`). The review target's content
is irrelevant here — this fixture is about Step 0's echoed config, not
findings.

## Assertions (what `run-fixtures.sh` checks)

**Hard (marker-based — these are exact `key=value` lines `rc-config.sh`
emits, per `rules/config.md` and `scripts/rc-config.sh`, echoed verbatim by
Step 0.1 of `skills/run/SKILL.md`):**
- `settings.verify=true` (local-over-config precedence)
- `settings.min_reviewers=3` (config.yml value, NOT overridden locally, and
  NOT the built-in default of 2)
- `lens.security.providers=google` (the pin)
- `lens.security.replaces_dedicated=true` (pin flips the dedicated-replaces
  flag)
