# 009 — How the gap definition for the full run is chosen

**Date:** 2026-11-02
**Status:** Proposed. The rule is set; the threshold it selects is provisional until
the tests under *Consequences* have run. Update this file to Accepted, with the date
and the selected values, before island-wide gap results are examined.
**Bears on:** plan §2.4 threshold, §2.5 minimum gap size, §2.12 parameter freeze,
§3.3 vertical criterion, §4 confounds 2–4; Q1–Q4, Q11;
[point-gaps-plan.md](../point-gaps-plan.md) §2.1, §2.5

## Decision

`canopy.py` has three gap-definition settings: the C2C threshold, connectivity (26 or
6), and segmentation (connected components, or the seeded split). All three act only
on the cached distances (step 2), so step 1 runs once per campaign whatever is
chosen. They are chosen by the rule below, not by inspecting island-wide results.

**1. Two products, defined separately.**

- **Damage extent** (gap area, area-based damage and rates, Q4): gap area at
  **2 m**. Connectivity does not matter for this product (quadrat R² changes by at
  most 0.03 between 26 and 6), and it needs no separate objects.
- **Gap objects** (individual gap sizes, size–frequency fits, Q1–Q3): the threshold
  chosen by rule 2.

**2. The gap-object threshold is the lowest candidate that passes all three tests
in every prototype window.** Candidates: 2, 3, 4, 5 m. Thresholds below 2 m are
excluded beforehand: ground returns already sit up to 0.77 m from their nearest
2018 return (p99 at LFDP). Lower is preferred because a higher cut detects less
damage and trims every gap's edge further.

| Test | Pass if | Evaluated on |
|---|---|---|
| **Noise** | In a null comparison, the gap area at T is ≤ **10%** of the Maria-interval gap area at T over the same ground | same-epoch null: two 2017 flights of the same ground, days apart |
| **Separation** | The largest gap holds ≤ **10%** of gap volume | every prototype window |
| **Field agreement** | 40 m quadrat R² of gap area against stem loss **and** against basal-area loss is ≥ 90% of the best candidate's | LFDP (the only census) |

The two 10% values are proposals. Confirm or change them here, dated, **before**
the null is run. Prototype windows are 500 × 500 m (25 ha) study areas, LFDP-scale,
each run as a `canopy.py` site. Separation is a share of gap volume, so it falls
with area by itself and must be judged on windows of a fixed size, never on EV1 or
a campaign as a whole. Choose at least one window per forest-type stratum from
`derived/inventory/pr_repeat_tiles.csv` and the forest-type layer before looking at
any gap output from them.

**3. Connectivity is fixed at 26 beforehand, not chosen by the tests.** It is the
existing default and, from 3 m up, it changes little. Choosing it per threshold
would let the rule pick 6-connectivity at 2 m, which passes separation (8.7%) right
at the edge where changed voxels start linking up (45% at 1.5 m): exactly where
differences in point density between strata would decide the result.

**4. Segmentation is connected components.** The seeded split's boundaries between
neighbouring cores are a convention ("midway between them"), and at a threshold
that passes separation the gaps are already separate objects.

**5. The sensitivity set is fixed now.** It is run from the same caches and reported
alongside the primary results, never substituted for them:

- the selected T with 6-connectivity;
- T ± 1 m (within the candidate set);
- the seeded split at 2 m with 5 m seeds, plus 4 m and 6 m seeds;
- the extent product at 3 m.

**6. If no candidate passes in some stratum,** that stratum is flagged and the
failure is reported (plan §7). There is no stratum-specific threshold: it would put
the detection limit, not ecology, into the cross-stratum comparison (plan §2.5).

## Alternatives considered

*The threshold with the best field R².* One site and one forest type. The best
area-R² threshold (2 m) is also where 26-connected gaps merge into one component
holding 35% of the volume, so it fails as a definition of gap objects. Field
agreement is a test here, not the objective.

*Choosing threshold and connectivity jointly by the tests.* Selects 6-connectivity
at 2 m, a definition that sits at the merging transition (rule 3).

*The seeded split as primary.* It keeps 2 m extent with separate objects, but makes
the 2 m size distribution depend on how far apart the cores are and on the seed
threshold. Kept as a sensitivity run.

*Stratum-specific thresholds.* Rejected (rule 6).

*Choosing by how plausible the size distribution looks.* Rejected as tuning toward
the expected answer (plan §2.12).

*A spatially varying detection limit* (plan §2.4; point-gaps-plan §2.3). Still the
target. When it is implemented, this rule applies to its multiplier k instead of a
fixed T.

## Evidence

LFDP + 50 m (25 ha, EV1 5 Mar 2017 → 25 Apr 2018), default method, 1 m voxels,
MIN_POINTS 10. Full tables: [derived/validation/lfdp/](../../derived/validation/lfdp/README.md).

| T | Largest gap's share of gap volume (26 / 6) | 40 m quadrats, 26: R² area ~ stem loss | R² area ~ basal-area loss | Separation (26) | Field (26) |
|---|---|---|---|---|---|
| 2 m | 35% / 8.7% | 0.556 (best) | 0.445 | fail | pass |
| 3 m | 5.2% / 2.4% | 0.511 | 0.463 (best) | pass | pass |
| 4 m | 3.1% / 3.0% | 0.398 | 0.391 | pass | fail |
| 5 m | 4.2% / 4.1% | 0.262 | 0.291 | pass | fail |

Field thresholds (90% of best): stem loss ≥ 0.500, basal-area loss ≥ 0.417.

At 2 m, gap area tracks census damage close to 1:1. In 40 m quadrats the slope is
0.89 and the intercept −1.2, with mean gap area 52% and mean stem loss 45% (ρ 0.75).
This is the evidence for the 2 m extent product.

**Provisional outcome at LFDP alone:** T = **3 m** for gap objects (2 m fails
separation; 4 and 5 m fail field agreement), pending the noise test and windows in
the other strata.

## Consequences

Before the rule can select final values:

1. **Same-epoch null:** e.g. `PR_5March2017_EV1` against `PR_15March2017_EV1` on
   tile `c4r2` (both flown in March 2017), run as a `canopy.py` site; gap area at
   2–5 m against the Maria interval on the same ground.
2. **Prototype windows:** 25 ha study areas in each forest-type stratum, at minimum
   dry, montane and lowland secondary forest, plus several in EV1, each swept with
   `python/sweep.py --thresholds 2 3 4 5`. Short dry forest is the likely failure
   (plan §4, confound 3).
3. **Fill in the selected values** and change Status to Accepted.

Step 1 for all campaigns can start before then, because none of these settings
changes it. One exception: the planned observability flag and post-canopy height
(point-gaps-plan §2.2, §2.4) collect data while the 2018 points are read. If they
are to be adopted, implement them before the island-wide step-1 run.

Storage: each threshold kept costs 4 bytes per 2017 point in point labels, plus its
exports, so the sensitivity set is kept to the list in rule 5.
