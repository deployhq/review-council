"""Legacy third-party adapter — intentionally loosely typed (see ADR-012).

Reviewing this file is designed to RE-TRIGGER the same "unchecked Any /
missing input validation" finding that
`.review-council/learnings.md` already records as a known false positive,
under the fingerprint `src/adapters/*::*::unchecked-any`. Per the shared
spec (§Judge → recalibration), the judge should **suppress** a finding that
matches a learnings-Suppression fingerprint, count it in
`Suppressions applied: N`, and it should NOT appear in the final report.
"""

from typing import Any


def normalize_payload(payload: Any) -> dict:
    # No type/shape validation before use on an external payload — this is
    # exactly the shape of finding the team already triaged and suppressed
    # for this directory (see the Convention above and ADR-012).
    return {"id": payload["id"], "name": payload["name"]}
