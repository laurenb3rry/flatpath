"""What it costs to walk one directed edge, in seconds.

Two numbers come out of this module:

  tobler_time_s  -- honest walking time, what a clock would measure.
  edge_cost      -- that time scaled by how unpleasant the grade is.

The router minimizes edge_cost; the route cards report tobler_time_s. Keeping
them separate is why a route can be labeled "24 min" while the router treats it
as much more expensive than 24 minutes of flat walking.

Costs are direction-dependent. Slope is signed, so the A->B and B->A edges over
the same ground get different costs, and both must be stored.

Invariant: edge_cost >= tobler_time_s always, because the misery multiplier is
never below 1. The router's heuristic assumes every edge costs at least its
straight-line time at peak walking speed, so if a multiplier could dip below 1
the search would start returning suboptimal routes. Any change to the misery
branches must preserve this -- test_cost.py checks it across the whole dial range.
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


def edge_cost(length_m, delta_elev_m, uphill_suffering,
              uphill_misery_grade=UPHILL_MISERY_GRADE,
              downhill_misery_grade=DOWNHILL_MISERY_GRADE,
              downhill_suffering=DOWNHILL_SUFFERING):
    """Cost of traversing one directed edge, in seconds.

    Walking time multiplied by a misery factor that grows with the square of how
    far the grade exceeds the comfortable threshold. Squared, not linear, so mild
    hills stay nearly free while genuinely steep blocks become expensive fast: at
    uphill_suffering=0.5 a 6% grade costs about 2% extra, an 18% grade over 4x.

    uphill_suffering is the dial that distinguishes one route option from another.
    Higher values buy flatter routes at the price of longer ones.
    """
    slope = delta_elev_m / length_m                        # signed: + uphill, - downhill

    time_s = tobler_time_s(length_m, delta_elev_m)

    if slope >= 0:
        excess = max(0.0, slope - uphill_misery_grade)
        misery = 1.0 + uphill_suffering * (excess / uphill_misery_grade) ** 2
    else:
        excess = max(0.0, abs(slope) - downhill_misery_grade)
        misery = 1.0 + downhill_suffering * (excess / downhill_misery_grade) ** 2

    return time_s * misery
