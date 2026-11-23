# 007 — The pre-interval forest mask: C-CAP 2010 (Hansen GFC was the provisional default)

**Date:** 2026-10-14; revised 2026-11-23
**Status:** Accepted 2026-11-23. The user chose C-CAP after the comparison (see
*Outcome*). The original Hansen default below is kept for the record.
**Bears on:** §2.11 pre-interval land cover mask, §3.2 forest type
classification, [covariates-plan.md](../covariates-plan.md)

## Decision

The forest/non-forest mask is built from Hansen Global Forest Change: forest
where `treecover2000` is at or above a threshold (30% as a placeholder, chosen
at analysis time) and `lossyear` records no loss through 2016. NOAA C-CAP for
Puerto Rico 2010 — the only vintage before Maria — is downloaded alongside it and
compared later. The mask and the forest-type classification come from separate
products: the mask needs recency, forest type needs ecologically meaningful
classes, and one product does not serve both.

## Alternatives considered

*PR GAP land cover (~2000) as both mask and forest type.* One product, internally
consistent. Rejected as the mask because it leaves 17 years of land-use change
before the 2017 acquisitions unmasked. It remains a forest-type candidate.

*C-CAP alone.* Captures regrowth up to its vintage (2010, if that is the latest),
but misses clearing between then and 2017.

*Union of C-CAP and Hansen 2000, minus Hansen loss through 2016.* Closes both
holes at the cost of a composite rule to defend in the methods. Deferred: both
inputs are downloaded, so this can be built if the comparison shows it is needed.

*10 m post-2017 products (ESA WorldCover, Esri/Impact Observatory annual).*
Rejected under §2.11: a post-Maria classification labels defoliated forest as
non-forest and removes the most heavily damaged pixels.

## Evidence

None measured yet. The known weakness is structural: Hansen's baseline is 2000
and it records gain poorly (the gain layer covers only 2000–2012). Puerto Rico
has been reforesting through farm abandonment, so a Hansen-only mask will label
young secondary forest that closed after 2000 as non-forest — biasing the sample
toward older stands within every forest type.

## Consequences

The Hansen/C-CAP comparison should quantify how much forest the default mask
drops that C-CAP calls forest, and where. If that area is substantial or
concentrated in particular forest types, switch to the union rule. The
threshold choice needs checking against south-coast dry forest, whose open
canopy may fall below 30% cover.

## Outcome (2026-11-23)

**Comparison.** `gap_covariates.py` (M6) sampled every 1 m column of the 1,805,219 gap
objects at 3 m (island run `df81889aa38eecef`) under each mask. The results are in
`runs/canopy/island/df81889aa38eecef/covariates/3m/mask_comparison.csv`. The table gives
the share of gaps whose forest fraction is ≥ 0.5:

| Holdridge zone | Gaps | Hansen ≥10% | Hansen ≥30% | Hansen ≥50% | C-CAP | Union (H30 ∪ C-CAP) | Intersection |
|---|---|---|---|---|---|---|---|
| All | 1,805,219 | 89.1% | 85.5% | 82.1% | 85.9% | 91.7% | 79.6% |
| Subtropical Dry | 60,868 | 64.4% | 57.2% | 51.0% | 60.0% | 71.7% | 45.5% |
| Subtropical Moist | 869,767 | 84.0% | 78.8% | 74.3% | 80.9% | 87.6% | 72.2% |
| Subtropical Wet | 739,754 | 95.4% | 93.3% | 91.0% | 91.5% | 96.8% | 88.0% |
| Rain and Lower Montane | 133,865 | 98.5–98.8% | 98.1–98.8% | 97.5–98.7% | 98.2–99.5% | 99.5–100% | 96.8–98.3% |

- The masks differ mainly in dry forest and, less so, in moist forest. This is the
  weakness this ADR predicted for Hansen: open dry forest, and regrowth since 2000.
- By gap volume, Hansen ≥30% keeps 90.2%, C-CAP 92.4% and the union 95.4%. In dry
  forest the figures are 57.7%, 65.8% and 76.1%.

**Decision (user, 2026-11-23).**
- The forest mask is **C-CAP 2010 (30 m)**: codes 9, 10, 11, 13 and 16, as `area.py`
  defines them (`CCAP_FOREST`).
- A gap is kept when **`forest_ccap_frac` ≥ 0.5**. That is the rule the comparison
  tabulated. The ≥ 0.5 cut-off was assumed when this was recorded, not stated by the
  user, so it should be confirmed.
- Area denominators use the same mask: `forest_ccap_ha` in `runs/canopy/area/<id>/areas.csv`.
- Hansen fractions (10, 30 and 50%) and the union and intersection stay in
  `gaps_covariates.parquet` for sensitivity checks.
- Known limitation: C-CAP's 2010 vintage misses clearing between 2010 and 2017.

