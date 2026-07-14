# Fixture: `suppression`

Tier-2 fixture. See `tests/run-fixtures.sh` (header) for how/when to run this —
LOCAL / on-demand only, never CI.

## What it exercises

`repo/.review-council/learnings.md` carries a **Suppressions** entry:

```text
fingerprint: src/adapters/*::*::unchecked-any | reason: intentional, see ADR-012 | added: 2026-07-10
```

(This is the exact example fingerprint format from the shared spec's
`.review-council/learnings.md` format: `<relpath>::<normalized-symbol-or-hunk>::<normalized-concern>`,
with `*` glob segments.)

`repo/src/adapters/legacy_adapter.py::normalize_payload` re-triggers the same
shape of finding: it accepts `payload: Any` and indexes into it
(`payload["id"]`, `payload["name"]`) with no shape/type validation — a
textbook "unchecked Any" / missing-input-validation finding that a reviewer
with no memory of the suppression would flag again.

Per the shared spec (§Judge → recalibration): "Suppress a finding if it
matches a learnings Suppression fingerprint (from Step 0.5). Count them,"
and the ledger step must print a `Suppressions applied: N` line.

## How to point the review at it

Point `/review-council:run` at `repo/src/adapters/legacy_adapter.py` (or the
whole `repo/` directory) with CWD set to `repo/` so
`.review-council/learnings.md` and `.review-council/config.yml` (absent here
— defaults are fine; `settings.learn` defaults to `true`) resolve relative to
the target repo, per Step 0.5 of `skills/run/SKILL.md`.

## Assertions (what `run-fixtures.sh` checks)

**Hard (marker-based, per the shared spec's artifact contract):**
- The line `Suppressions applied: 1` appears in the judge ledger output.

**Soft / best-effort (content-level — see the concerns note in
`tests/run-fixtures.sh`'s header):**
- The suppressed finding (the `legacy_adapter.py` / `normalize_payload` /
  "unchecked-any" concern) does **not** appear as a surviving finding in the
  `Critical`/`Important`/`Suggestions` sections of the final report.
