# Fixture: `crossfile`

Tier-2 fixture. See `tests/run-fixtures.sh` (header) for how/when to run this —
LOCAL / on-demand only, never CI.

## What it exercises

A small **contract change** (`repo/src/pricing.py`: `calculate_total` now
returns a `PricingResult` object instead of a bare `float`) that:

1. Contains a **planted, plausible-but-false null-deref finding** inside the
   changed file itself: `order.discount_pct` on `pricing.py:24` looks like it
   could be `None`/missing, but `repo/src/models.py` proves
   `Order.discount_pct` has a hard default of `0.0` — there is no code path
   where it's ever `None`. A refuter that actually traces `Order` (Read/Grep)
   should return **REFUTED** with that as positive counter-evidence, per the
   shared spec's refutation template ("do NOT default to REFUTED — absence of
   proof is INCONCLUSIVE, never REFUTED. Only positive counter-evidence is
   REFUTED.").
2. Contains a **real cross-file break** reachable only through an **unshown
   caller**: `repo/src/checkout.py::render_receipt` is not part of the
   reviewed diff, but it still formats `calculate_total(order)`'s return value
   with `f"${total:.2f}"`, which now raises `TypeError` because the return
   value is a `PricingResult`, not a `float`. Finding this requires tracing
   the call site (`grep -rn "calculate_total(" src/`), exactly the kind of
   check the shared spec's Cross-file lens / refutation pass is meant to
   catch.

## How to point the review at it

Point `/review-council:run` at `repo/src/pricing.py` (or the whole `repo/`
directory) with CWD set to `repo/` so `.review-council/` (none needed here —
defaults are fine) and the source tree resolve correctly. See
`tests/run-fixtures.sh` for the exact invocation used by the harness.

## Assertions (what `run-fixtures.sh` checks)

**Hard (marker-based, per the shared spec's artifact contract):**
- The **`Refutation routing`** table is printed (Step 4 — literal header
  `Refutation routing (verify cap N):`; each candidate finding routed to a
  repo-capable, different-family verifier).
- The **judge ledger** is printed (Step 5 — a row per surviving finding with
  the `fingerprint | origin-families | verdict | suppression? | tool? |
  final-severity | final-confidence` shape) BEFORE the prose report.

**Soft / best-effort (content-level — see the concerns note in
`tests/run-fixtures.sh`'s header; wording here is genuinely LLM-mediated and
can't be pinned with certainty by grep):**
- Some evidence the `discount_pct` / `pricing.py` decoy was marked `REFUTED`
  and does **not** survive into the `Critical`/`Important` sections of the
  final report.
- The real `checkout.py` / `render_receipt` / `PricingResult` break **does**
  land in the `Critical` section of the final report.
