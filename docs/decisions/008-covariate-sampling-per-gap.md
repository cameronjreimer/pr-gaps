# 008 — Covariates are sampled per gap at native resolution, from harmonized copies

**Date:** 2026-10-14
**Status:** Accepted
**Bears on:** §5 week 2 covariate stack, Q3, Q6, §2.9 hierarchical model,
[covariates-plan.md](../covariates-plan.md)

## Decision

Environmental covariates are summarized per gap polygon. Each layer is used at
its native resolution; there is no common analysis grid. Raw downloads stay
untouched in `raw/covariates/`, and a copy of each layer is reprojected to
EPSG:32161 in `interim/covariates/` — nearest neighbour for categorical rasters,
bilinear for continuous ones, vectors reprojected directly — keeping roughly the
native cell size. Downstream sampling code reads only the interim copies.

## Alternatives considered

*One common grid for every layer.* Keeps per-stratum area accounting
consistent with the mask, which gap density (Q4, §2.10) needs. Rejected because
Q4 is out of scope for now, and a common grid forces a cell-size choice that is
either huge island-wide (1 m) or coarser than the gaps (10 m+).

*Raw only, transforming gap polygons into each layer's CRS at sampling time.*
Avoids resampling entirely, so categorical boundaries stay exactly where the
source drew them. Rejected in favour of one CRS downstream; the resampling it
avoids is small at native cell size and is documented here.

## Consequences

If Q4 comes back into scope, the stratifying layers (mask, forest type) will need
area-correct coverage over the usable footprint and this decision should be
revisited. Coarse layers (PRISM, Hansen at 30 m) will give neighbouring gaps
identical values; that is a property of the sources, not an error.
