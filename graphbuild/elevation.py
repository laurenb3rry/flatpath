"""Attaches a ground elevation to every node.

Bilinearly samples 1-meter elevation rasters at each node's coordinates. One
meter of resolution is the point: coarser data averages away the block-by-block
steepness this whole app is built to detect, turning a wall of a street into a
gentle ramp.

This runs once, offline. The app never samples elevation -- it only reads the
slopes already baked into edge costs.

Interpolation is bilinear rather than nearest-neighbor because nearest-neighbor
snaps every node to the center of its pixel, which adds up to a meter of
horizontal error. On a 30% grade that is a third of a meter of invented
elevation change, and adjacent nodes can pick up such errors in opposite
directions, manufacturing slopes that are not there.

Rasters are consulted one at a time and each is only read once. They are large
enough that holding several open in memory at once is the difference between
comfortable and not.
"""

import numpy as np
import rasterio
from rasterio.warp import transform as warp_transform

# How far to look for usable data when a node's own pixel has none, in pixels.
# Coastline nodes routinely land a few pixels into the water, where the raster
# holds a nodata value; a short search finds the shore rather than discarding the
# node. Kept small so it can only ever borrow from immediately adjacent ground.
_NEAREST_SEARCH_RADIUS_PX = 8

# Last-resort elevation, used only for nodes that have no raster data and no
# connected neighbor that does. In practice this means a stretch of path over
# water that touches nothing on land.
_SEA_LEVEL_M = 0.0


def _bilinear_sample(band, valid, rows, cols):
    """Interpolate `band` at fractional pixel positions, skipping nodata.

    Each sample mixes the four surrounding pixel centers. Any of the four that
    holds nodata is dropped from the mix and the remaining weights are
    renormalized, so a node next to water leans on the land pixels beside it
    instead of averaging in a sentinel value. Samples with no usable neighbor at
    all come back as NaN for the caller to resolve.
    """
    height, width = band.shape

    row0 = np.floor(rows).astype(np.int64)
    col0 = np.floor(cols).astype(np.int64)
    drow = (rows - row0)[:, None]
    dcol = (cols - col0)[:, None]

    row_idx = np.clip(np.stack([row0, row0, row0 + 1, row0 + 1], axis=1), 0, height - 1)
    col_idx = np.clip(np.stack([col0, col0 + 1, col0, col0 + 1], axis=1), 0, width - 1)

    weights = np.concatenate([
        (1 - drow) * (1 - dcol),
        (1 - drow) * dcol,
        drow * (1 - dcol),
        drow * dcol,
    ], axis=1)

    values = band[row_idx, col_idx]
    usable = valid[row_idx, col_idx]

    weights = np.where(usable, weights, 0.0)
    total = weights.sum(axis=1)

    with np.errstate(invalid="ignore", divide="ignore"):
        result = (weights * np.where(usable, values, 0.0)).sum(axis=1) / total

    return np.where(total > 0, result, np.nan)


def _nearest_valid_sample(band, valid, rows, cols, radius):
    """Value of the closest usable pixel within `radius`, or NaN.

    The fallback for nodes whose four neighbors are all nodata. Searches outward
    ring by ring and takes the first hit, so the answer is the nearest ground
    rather than an average of whatever happened to be in range.
    """
    height, width = band.shape
    result = np.full(rows.shape, np.nan, dtype=np.float64)

    row_c = np.clip(np.rint(rows).astype(np.int64), 0, height - 1)
    col_c = np.clip(np.rint(cols).astype(np.int64), 0, width - 1)

    unresolved = np.ones(rows.shape, dtype=bool)
    for ring in range(radius + 1):
        if not unresolved.any():
            break
        for drow in range(-ring, ring + 1):
            for dcol in range(-ring, ring + 1):
                if max(abs(drow), abs(dcol)) != ring:
                    continue
                r = np.clip(row_c[unresolved] + drow, 0, height - 1)
                c = np.clip(col_c[unresolved] + dcol, 0, width - 1)
                hit = valid[r, c]
                if not hit.any():
                    continue
                targets = np.flatnonzero(unresolved)[hit]
                result[targets] = band[r[hit], c[hit]]
                unresolved[targets] = False

    return result


def sample(lats, lons, dem_paths):
    """Elevation in meters for each coordinate, in the order given.

    Returns (elevations, missing_count), where unresolved entries are NaN. They
    are left that way rather than defaulted so the caller can fill them from
    context; see fill_gaps.
    """
    lats = np.asarray(lats, dtype=np.float64)
    lons = np.asarray(lons, dtype=np.float64)

    elevations = np.full(lats.shape, np.nan, dtype=np.float64)

    for path in dem_paths:
        pending = np.flatnonzero(np.isnan(elevations))
        if pending.size == 0:
            break

        with rasterio.open(path) as src:
            xs, ys = warp_transform(
                "EPSG:4326", src.crs, lons[pending].tolist(), lats[pending].tolist()
            )
            xs = np.asarray(xs)
            ys = np.asarray(ys)

            # Pixel-corner coordinates, then shifted to be relative to pixel
            # centers, which is where the sampled values actually live.
            inverse = ~src.transform
            cols, rows = inverse * (xs, ys)
            cols = np.asarray(cols) - 0.5
            rows = np.asarray(rows) - 0.5

            inside = (
                (cols >= -0.5) & (cols <= src.width - 0.5)
                & (rows >= -0.5) & (rows <= src.height - 0.5)
            )
            if not inside.any():
                continue

            targets = pending[inside]
            band = src.read(1)
            nodata = src.nodata
            valid = np.isfinite(band)
            if nodata is not None:
                valid &= band != nodata

            sampled = _bilinear_sample(band, valid, rows[inside], cols[inside])

            gaps = np.isnan(sampled)
            if gaps.any():
                sampled[gaps] = _nearest_valid_sample(
                    band,
                    valid,
                    rows[inside][gaps],
                    cols[inside][gaps],
                    _NEAREST_SEARCH_RADIUS_PX,
                )

            found = ~np.isnan(sampled)
            elevations[targets[found]] = sampled[found]

    return elevations, int(np.isnan(elevations).sum())


def fill_gaps(elevations, ways):
    """Infer elevations the rasters could not supply, from connected neighbors.

    Bare-earth rasters have no data over water, so anything crossing it comes
    back empty -- most visibly the Golden Gate Bridge, whose deck is some 67
    meters up. Defaulting those to sea level would carve a cliff into both ends
    of the bridge and a matching climb back out, and the router would price a
    flat walk as the steepest thing in the city.

    Values spread outward from nodes that do have data, one step along the
    network per round, each filled node taking the mean of whichever neighbors
    were already known. Averaging rather than copying keeps a span level when it
    is being filled from both ends, which is what a bridge deck actually is.

    Returns (elevations, filled_count, stranded_count).
    """
    elevations = np.asarray(elevations, dtype=np.float64)
    unknown = np.isnan(elevations)
    if not unknown.any():
        return elevations, 0, 0

    neighbors = _adjacency(ways, len(elevations))
    to_fill = set(np.flatnonzero(unknown).tolist())
    filled = 0

    while to_fill:
        # Only nodes bordering something already known can be resolved this
        # round; the rest wait for the frontier to reach them.
        resolvable = []
        for node in to_fill:
            known = [elevations[n] for n in neighbors[node] if not np.isnan(elevations[n])]
            if known:
                resolvable.append((node, sum(known) / len(known)))

        if not resolvable:
            break

        for node, value in resolvable:
            elevations[node] = value
            to_fill.discard(node)
        filled += len(resolvable)

    stranded = len(to_fill)
    if stranded:
        elevations[np.isnan(elevations)] = _SEA_LEVEL_M

    return elevations, filled, stranded


def _adjacency(ways, node_count):
    """Neighbor lists keyed by node index, built from way node sequences."""
    neighbors = [[] for _ in range(node_count)]
    for indices, _name in ways:
        for a, b in zip(indices, indices[1:]):
            if a == b:
                continue
            neighbors[a].append(b)
            neighbors[b].append(a)
    return neighbors
