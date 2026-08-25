"""Pins the cost function to known-good values.

The three reference edges below are hand-checked results of the tuned formula.
They are a regression guard, not a derivation: if they fail, the cost function
has drifted, and every baked cost in the graph is suspect. Fix it before
rebuilding or serializing anything.
"""

import pytest

from config import UPHILL_SUFFERING
from cost import edge_cost, tobler_time_s

TOLERANCE_S = 0.1
REFERENCE_LENGTH_M = 100.0
REFERENCE_SUFFERING = 0.5

# (label, delta_elev_m, expected_cost_s) over 100m at uphill_suffering=0.5.
# The jump from 90s to 588s between a 6% and an 18% grade is the squared misery
# term doing its job -- that gap is what pushes routes around SF's steep blocks.
REFERENCE_EDGES = [
    ("flat",         0.0,  71.5),
    ("normal climb", 6.0,  90.0),
    ("steep climb",  18.0, 587.8),
]


@pytest.mark.parametrize("label, delta_elev_m, expected_s", REFERENCE_EDGES)
def test_reference_edge_costs(label, delta_elev_m, expected_s):
    actual = edge_cost(REFERENCE_LENGTH_M, delta_elev_m, REFERENCE_SUFFERING)
    assert actual == pytest.approx(expected_s, abs=TOLERANCE_S)


def test_cost_never_below_walking_time():
    """The invariant the router's correctness depends on.

    The heuristic assumes no edge is cheaper than its honest walking time. If a
    misery multiplier ever dropped below 1, the router could return a route that
    is not actually the cheapest, silently. Checked across every dial value and
    both slope directions.
    """
    for suffering in UPHILL_SUFFERING:
        for delta_elev_m in range(-40, 41):
            length_m = REFERENCE_LENGTH_M
            assert edge_cost(length_m, float(delta_elev_m), suffering) >= (
                tobler_time_s(length_m, float(delta_elev_m))
            )
