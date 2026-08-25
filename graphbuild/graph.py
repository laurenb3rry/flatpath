"""Turns parsed ways and node elevations into a directed graph with baked costs.

Every walkable segment becomes two edges, one per direction. This is not
optional: slope is signed, so uphill and downhill over the same ground cost
different amounts, and collapsing them into one symmetric edge would quietly
produce wrong routes.

Each directed edge stores its length, its elevation change, and one cost per
hill-aversion setting, so the app can switch between route options by index
without recomputing anything.

Not yet implemented.
"""
