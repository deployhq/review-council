"""Trivial review target for the `budget` fixture.

This fixture asserts the budget-degrade behavior, not finding quality — a
small file with one modest, genuine issue is enough to give reviewers
something to report.
"""


def divide(a, b):
    return a / b  # no guard for b == 0 -> ZeroDivisionError on bad input
