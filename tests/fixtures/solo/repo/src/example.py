"""Trivial review target for the `solo` fixture.

This fixture asserts the solo-mode / refutation-skip behavior, not finding
quality — a small file with one modest, genuine issue is enough to give the
lone Claude reviewer something to report (so the report has at least one
`[unverified]` / `[single-reviewer · unverified]`-tagged finding to grep
for) without costing extra tokens on an elaborate scenario.
"""


def divide(a, b):
    return a / b  # no guard for b == 0 -> ZeroDivisionError on bad input
