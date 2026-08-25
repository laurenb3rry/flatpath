"""Tunable constants for the graph build: cost-function parameters, and later the
SF bounding box and pipeline file paths.

The cost constants below are tuned. Changing them changes every baked edge cost,
so the graph must be rebuilt and the app's bundled binary replaced.
"""

# --- Cost function ---

# Grade above which climbing starts to feel like suffering rather than walking.
# Below 5%, a hill costs only the extra time it takes; above it, misery compounds.
UPHILL_MISERY_GRADE = 0.05

# Grade above which descending starts to punish the knees. Much higher than the
# uphill threshold: gentle descents are free, only genuinely steep ones hurt.
DOWNHILL_MISERY_GRADE = 0.20  # TUNE: validate against SF's steep descents

# How strongly to penalize excess uphill grade. One cost is baked per value, in
# this order, giving three routes of increasing hill-aversion: the app runs the
# router once per index and offers the distinct survivors as route options.
#
# Never add 0.0 to this list. At zero the router degenerates into a pure
# shortest-time search -- the same route Google Maps gives, straight over the
# hill -- which is the thing this app exists to avoid. 0.15 is the floor.
UPHILL_SUFFERING = [0.15, 0.5, 1.5]

# How strongly to penalize excess downhill grade. Lower than any uphill value:
# steep descents are unpleasant, but never as costly as the equivalent climb.
DOWNHILL_SUFFERING = 0.15

# Fastest a walker can move on any edge, in m/s (Tobler's 6 km/h peak, hit at a
# slight downhill). The router's heuristic divides straight-line distance by this
# to get a lower bound on remaining time, so it must not be exceeded by any real
# edge speed or the search can return a suboptimal route.
MAX_SPEED_MS = 1.667
