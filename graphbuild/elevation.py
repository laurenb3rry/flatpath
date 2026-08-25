"""Attaches a ground elevation to every node.

Bilinearly samples a 1-meter USGS 3DEP raster at each node's lat/lon. One meter
of resolution matters here: coarser data smooths away the block-by-block
steepness that the whole app is built to detect.

This runs once, offline. The app never samples elevation -- it only reads the
slopes already baked into edge costs.

Not yet implemented.
"""
