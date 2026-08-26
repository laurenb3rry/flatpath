"""Pins the cost function to known-good values.

The three reference edges below are hand-checked results of the tuned formula.
They are a regression guard, not a derivation: if they fail, the cost function
has drifted, and the router -- which carries its own copy of this formula and is
what actually evaluates it -- is computing something other than what this file
says it should.
"""

import pytest

from cost import edge_cost, tobler_time_s

TOLERANCE_S = 0.1
REFERENCE_LENGTH_M = 100.0

# The dial values the reference edges are quoted at. A middling pair: enough
# grade aversion to bend a route around a steep block, and an exchange rate
# between time and climb close to the one Naismith's rule implies for an
# ordinary walker.
REFERENCE_SUFFERING = 0.5
REFERENCE_ASCENT_WEIGHT = 4.0

# (label, delta_elev_m, expected_cost_s) over 100 m at the reference dials.
#
# The jump from 71 s to 156 s between flat ground and an ordinary San Francisco
# block is the change worth watching: an unremarkable 6% grade now costs more
# than twice what it used to, roughly half of that from the misery multiplier
# finding the block steep at all and half from the six meters it gains. Routes
# made of nothing but blocks like this are what the cost function used to price
# at nothing.
REFERENCE_EDGES = [
    ("flat",         0.0,    71.5),
    ("normal climb", 6.0,   156.3),
    ("steep climb",  18.0, 1883.7),
]

# Enough of the dial range to make the invariant below mean something: the
# gentlest and harshest settings the router sweeps, and a few in between.
DIAL_RANGE = [(0.3, 2.0), (1.0, 6.0), (4.0, 22.0), (12.0, 60.0)]


@pytest.mark.parametrize("label, delta_elev_m, expected_s", REFERENCE_EDGES)
def test_reference_edge_costs(label, delta_elev_m, expected_s):
    actual = edge_cost(
        REFERENCE_LENGTH_M, delta_elev_m, REFERENCE_SUFFERING, REFERENCE_ASCENT_WEIGHT
    )
    assert actual == pytest.approx(expected_s, abs=TOLERANCE_S)


def test_cost_never_below_walking_time():
    """The invariant the router's correctness depends on.

    The heuristic assumes no edge is cheaper than its honest walking time. If a
    misery multiplier ever dropped below 1, or the climb charge ever went
    negative on a descent, the router could return a route that is not actually
    the cheapest, silently. Checked across the dial range and both slope
    directions.
    """
    for suffering, ascent_weight in DIAL_RANGE:
        for delta_elev_m in range(-40, 41):
            length_m = REFERENCE_LENGTH_M
            assert edge_cost(
                length_m, float(delta_elev_m), suffering, ascent_weight
            ) >= tobler_time_s(length_m, float(delta_elev_m))


def test_climbing_costs_more_than_the_same_walk_on_the_level():
    """A gentle grade is priced even where no block is steep enough to notice.

    The whole reason for the climb charge. At a 4% grade the misery multiplier
    barely registers, so before there was a charge per meter gained a route made
    of these cost no more than a flat one of the same length -- and the walker
    arrived two hundred feet higher having been told the way was level.
    """
    gentle_climb = edge_cost(REFERENCE_LENGTH_M, 4.0, 0.3, 2.0)
    level = edge_cost(REFERENCE_LENGTH_M, 0.0, 0.3, 2.0)

    assert gentle_climb > level * 1.1
