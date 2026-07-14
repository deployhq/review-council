"""Trivial review target for the `config` fixture.

This fixture asserts Step 0's ECHOED CONFIG, not review findings — the
content here is intentionally uninteresting. Any small file works; the
review target just needs to exist so Step 1 (detect target) resolves
unambiguously to a code review.
"""


def add(a, b):
    return a + b
