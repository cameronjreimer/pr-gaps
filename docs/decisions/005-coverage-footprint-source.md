# 005 — Coverage footprints come from the CHM, not the published tile polygons

**Date:** 2026-09-22
**Status:** Accepted
**Bears on:** §3.1 spatial scope (week 3), §2.10 gap density denominators, the
week-3 usable-swath inventory

## Decision

Usable area per campaign is the non-NA extent of the delivered canopy height
model, polygonised at 10 m (`gl_chm_footprint()`). The polygons G-LiHT publishes
in `lidar/shp/*_tiles.shp` are used only as a first-pass upper bound for
scoping, and every area that enters an analysis — above all the per-stratum
denominators behind gap density — is computed from the CHM. Any figure derived
from tile polygons carries its `tile_source` flag with it.

## Alternatives considered

*Published tile polygons alone.* Free, already downloaded with the metadata, no
raster work. Rejected on magnitude: they are a rectangular grid over the
campaign bounding box, or a per-strip envelope, while a G-LiHT swath is a few
hundred metres wide and crosses tiles diagonally.

*Buffering the flight trajectory by half the swath width.* Cheap and
geometrically honest in principle. Rejected because the published trajectory is
the whole day's ground track, including transits between blocks, and because the
swath width varies with altitude AGL, which differs across campaigns (the
`high_alt`/`low_alt` pairs from 2017-03-17 make this explicit).

*The 26 m metrics grids* (`lidar/geotiff/metrics/`, ~10 KB per campaign). These
looked like a 700× cheaper proxy for the same mask. Rejected on evidence, below.

## Evidence

Measured on `PR_15March2017_EV1`, whose CHM covers a 4,113 ha bounding box:

| Source | Area (ha) |
|---|---|
| Full tile grid (40 tiles) | 4,107 |
| Tiles with a delivered LAS (13 of 40) | 1,335 |
| CHM valid-data extent | 268 |
| `all_p90` metrics grid valid extent | 136 |

Across the 14 Luquillo EV campaigns the CHM footprint is 20–52% of the tile
footprint (median ~0.39). Strip-delivered campaigns are better but still
generous: `PR_1March2017_FIA15` is 3,005 ha of strip polygons against 1,354 ha
of CHM, a ratio of 0.45. The metrics grids are valid over roughly half the CHM's
area (136 ha against 268 ha, where CHM cells that are ≥99% full already total
230 ha), so they encode some point-density or vegetation criterion of their own
rather than a coverage mask, and cannot be substituted.

The error is one-directional — tile polygons never understate coverage — so
island-wide tier-1 numbers are usable as an upper bound for the scoping
decision, and only for that. The tier-1 figure of ~84,000 ha of 2017 × 2018
overlap should be read as consistent with a true value nearer 30,000–40,000 ha
until refined.

## Consequences

Refining all 242 repeat-coverage campaigns means downloading ~7 GB of CHM and
about two hours of raster work; this must happen before any density figure is
quoted, and ideally before the week-3 scope decision rather than after. The
Luquillo EV blocks are already refined. Because the bias is one-directional and
large, a scope chosen on tier-1 areas will be systematically over-optimistic
about how much usable area exists — the failure mode in §7's "benchmark shows
island-wide is infeasible" row, arriving late.

Related: [006-repeat-coverage-definition.md](006-repeat-coverage-definition.md).
