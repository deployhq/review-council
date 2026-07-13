"""Checkout/receipt flow.

Deliberately NOT part of the reviewed diff (pricing.py's change doesn't
touch this file) — a reviewer only finds the break here by tracing the
caller, e.g. `grep -rn "calculate_total(" src/`. That is exactly the
"unshown caller" cross-file scenario this fixture exercises.
"""

from .pricing import calculate_total


def render_receipt(order):
    total = calculate_total(order)
    # REAL BUG: calculate_total now returns a PricingResult (see pricing.py),
    # not a float. Formatting it with ":.2f" raises TypeError at runtime:
    #   TypeError: unsupported format string passed to PricingResult.__format__
    # This is the genuine cross-file break the contract change introduces.
    return f"Total: ${total:.2f}"
