"""What it costs to walk one directed edge, in seconds.

Two numbers come out of this module:

  tobler_time_s  -- honest walking time, what a clock would measure.
  edge_cost      -- that time scaled by how unpleasant the grade is, plus a
                    charge for every meter the edge climbs.

Only the first of the two is baked into the graph. The router carries its own
copy of edge_cost and evaluates it on the phone, so that the dials below can be
retuned without rebuilding and reshipping a twenty-megabyte binary. This file
remains the statement of what the formula is, and test_cost.py pins it; the
router's copy must agree, and the two have to be changed together.

The router minimizes edge_cost; the route cards report tobler_time_s. Keeping
them separate is why a route can be labeled "24 min" while the router treats it
as much more expensive than 24 minutes of flat walking.

Costs are direction-dependent. Slope is signed, so the A->B and B->A edges over
the same ground get different costs, and both must be stored.

The cost has two terms and they answer different questions. The misery
multiplier asks how steep the ground is -- what it feels like underfoot, block
by block. The ascent term asks how much of the walk is climbing at all, and it
is what makes "flat" mean less total ascent rather than merely no steep block:
priced by grade alone, two hundred feet gained at a steady 4% is free, because
no single block is steep enough to notice.

Invariant: edge_cost >= tobler_time_s always. The misery multiplier is never
below 1 and the ascent term is never negative, so no edge can cost less than the
time it takes to walk. The router's heuristic assumes exactly that -- it bounds
the remaining cost by straight-line distance at peak walking speed -- so if
either term could go the other way the search would quietly start returning
routes it has not proved cheapest. Any change to the branches below must
preserve it; test_cost.py checks it across the whole range of both dials.
"""

import math

from config import (
    DOWNHILL_MISERY_GRADE,
    DOWNHILL_SUFFERING,
    UPHILL_MISERY_GRADE,
)


def tobler_time_s(length_m, delta_elev_m):
    """Honest walking time for an edge, in seconds.

    Tobler's hiking function: walking speed falls off exponentially as the ground
    tilts away from a gentle downhill. The +0.05 inside the absolute value puts
    the peak at a 5% descent rather than at flat, which is what makes the curve
    asymmetric -- a 5% climb is slower than a 5% descent.
    """
    slope = delta_elev_m / length_m                        # signed: + uphill, - downhill
    speed_kmh = 6.0 * math.exp(-3.5 * abs(slope + 0.05))
    speed_ms = speed_kmh / 3.6
    return length_m / speed_ms


def edge_cost(length_m, delta_elev_m, uphill_suffering, ascent_weight,
              uphill_misery_grade=UPHILL_MISERY_GRADE,
              downhill_misery_grade=DOWNHILL_MISERY_GRADE,
              downhill_suffering=DOWNHILL_SUFFERING):
    """Cost of traversing one directed edge, in seconds.

    Walking time multiplied by a misery factor that grows with the square of how
    far the grade exceeds the comfortable threshold, plus a flat charge per meter
    of rise. Squared, not linear, so a grade a little past comfortable stays
    nearly free while genuinely steep blocks become expensive fast.

    The two dials are what separates one route option from another, and they buy
    different things. `uphill_suffering` buys gentler blocks: raise it and the
    route refuses the steep ones. `ascent_weight` buys less climbing overall,
    in seconds per meter gained: raise it and the route gives up time to avoid
    gaining height at all, however gently. Naismith's rule -- an hour per 600 m
    of ascent -- puts a walker's own exchange rate around 6 s/m, which is a
    reference point rather than a ceiling; a walker who came here to avoid hills
    will happily pay several times that.
    """
    slope = delta_elev_m / length_m                        # signed: + uphill, - downhill

    time_s = tobler_time_s(length_m, delta_elev_m)

    if slope >= 0:
        excess = max(0.0, slope - uphill_misery_grade)
        misery = 1.0 + uphill_suffering * (excess / uphill_misery_grade) ** 2
    else:
        excess = max(0.0, abs(slope) - downhill_misery_grade)
        misery = 1.0 + downhill_suffering * (excess / downhill_misery_grade) ** 2

    return time_s * misery + ascent_weight * max(0.0, delta_elev_m)
