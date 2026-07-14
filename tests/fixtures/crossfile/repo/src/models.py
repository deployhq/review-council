"""Order model — NOT part of the reviewed change, but reachable by tools.

Included so a reviewer/verifier that Reads/Greps around `pricing.py` can
confirm `discount_pct` always has a concrete float value (see pricing.py's
docstring). This is the positive counter-evidence a refuter needs to mark
the decoy null-deref finding REFUTED (never assume it from absence alone).
"""

from dataclasses import dataclass


@dataclass
class Order:
    subtotal: float
    discount_pct: float = 0.0
