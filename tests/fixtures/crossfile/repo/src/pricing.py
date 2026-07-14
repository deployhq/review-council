"""Pricing contract — THIS is the file under review (the "diff").

CHANGED: `calculate_total` used to return a bare `float`. It now returns a
`PricingResult` object so callers can also see whether a discount applied.
The reviewed diff is exactly this signature/contract change — a caller
elsewhere in the repo (src/checkout.py, NOT shown as part of the diff) still
assumes the old `float` return shape. That unshown caller is the fixture's
real cross-file break.
"""

from dataclasses import dataclass

from .models import Order


@dataclass
class PricingResult:
    total: float
    discount_applied: bool = False


def calculate_total(order: Order) -> PricingResult:
    """Compute the order total as a PricingResult (was: a bare float).

    NOTE for reviewers: `order.discount_pct` cannot be None/missing here —
    `Order.discount_pct` (see src/models.py) has a hard default of `0.0`,
    and every in-repo constructor goes through that dataclass. Flagging
    the line below as a null-deref risk is the fixture's PLANTED false
    positive: it looks plausible in isolation, but tracing `Order` proves
    there is no code path where `discount_pct` is `None`.
    """
    discount = order.discount_pct  # <- plausible-but-FALSE null-deref target
    total = order.subtotal * (1 - discount)
    return PricingResult(total=total, discount_applied=discount > 0)
