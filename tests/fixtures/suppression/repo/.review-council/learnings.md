# Review Council — Learnings   (committed; team-shared; edit freely)

## Conventions   (injected once into the Step-2 baseline context package)
- Adapters in `src/adapters/` intentionally accept loosely-typed external
  payloads (`Any`, no shape validation) — this is a deliberate boundary
  decision (ADR-012), not a correctness gap. Do not flag untyped/unchecked
  `Any` params in that directory as a finding.

## Suppressions   (known false positives — the judge down-weights/skips matches by fingerprint)
- fingerprint: src/adapters/*::*::unchecked-any | reason: intentional, see ADR-012 | added: 2026-07-10
