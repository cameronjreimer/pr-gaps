# 006 — What counts as repeat coverage

**Date:** 2026-09-22
**Status:** Accepted
**Bears on:** §3.1 spatial scope (week 3), §2.2 the week-9 recovery gate

## Decision

Campaigns are grouped into three epochs by acquisition year — `2017_pre`
(March 2017), `2018_post` (April–May 2018), `2020_recovery` (March 2020) — and
each epoch's coverage is the dissolved union of its campaign footprints. Repeat
coverage is the self-intersection of those three polygons, giving one piece per
combination of epochs that cover it (`gl_repeat_coverage()`). Three rules
qualify that:

1. **Mosaic campaigns are excluded.** `PR_March2020_EV1_all`,
   `PR_March2020_EV3_all` and `PR_April2018_BG_all` are pre-merged products
   covering ground already counted in the dated flights they were built from.
2. **A tile counts as reflown by another epoch at ≥50% areal overlap**
   (`n_other_epochs` in `pr_repeat_tiles.csv`). The full fraction is retained
   per epoch, so the threshold can be changed without recomputing.
3. **Campaign pairs are reported separately** from the epoch overlay
   (`pr_repeat_campaign_pairs.csv`), because the download and processing unit is
   an individual flight, not an epoch.

## Alternatives considered

*Grouping by campaign rather than epoch.* More faithful to acquisition, but the
question the chapter asks is about intervals, and 296 campaigns give 43,000
pairs where three epochs give four meaningful combinations. The pairs table
keeps the campaign-level detail available without making it the primary view.

*Requiring full tile coverage before calling a tile reflown.* Rejected as
premature: at tier-1 granularity the fraction is itself uncertain (see
[005](005-coverage-footprint-source.md)), so a hard threshold would encode
precision that the geometry does not have. 50% with the fractions retained is
the reversible choice.

*Treating 2018 and 2020 as one post-hurricane epoch.* Rejected because §2.2
makes the 2018 → 2020 interval a distinct question — recovery-period disturbance
against hurricane disturbance — and merging them would foreclose it.

## Evidence

Epoch grouping is unambiguous in the data: the three campaign clusters are
separated by 13 months and 22 months, and within-cluster spans are 17 days
(2017), 11 days (2018) and 2 days (2020). No campaign falls between clusters, so
no judgement call arises at the boundaries.

Tier-1 repeat areas, which are upper bounds:

| Epochs | Area (ha) |
|---|---|
| 2017 + 2018 + 2020 | 28,402 |
| 2017 + 2018 | 83,713 |
| 2018 + 2020 | 6,018 |
| 2017 + 2020 | 137 |

Most 2018 and 2020 flights were deliberate reflights of 2017 blocks: overlap
fractions in the pairs table are overwhelmingly 1.00, at intervals of ~413 days
(2017 → 2018) and ~1,109 days (2017 → 2020). The 137 ha in the 2017 + 2020 row
is small not because those blocks were missed in 2018, but because nearly all of
them were also flown in 2018 and therefore fall in the three-epoch row instead.

The CHM-refined numbers for the Luquillo EV blocks — the only ones refined so
far — are 1,710 ha covered by 2017 and 2018, and a further 858 ha covered by all
three epochs.

## Consequences

The 2018 → 2020 interval has an order of magnitude less repeat area than the
Maria interval (6,018 + 28,402 ha against 83,713 + 28,402 ha, both tier-1). That
is a real constraint on the week-9 recovery gate and on Q8–Q10, and it is
structural rather than something better processing will recover: the 2020
campaign was 21 flights over two days against 148 flights over 13 days in 2017.
Worth knowing before week 9 rather than at it.

Five of the 296 campaign directories are empty on the server
(`PR_15March2017_112`, `PR_26April2018_131`, `PR_27April2018_197`,
`PR_27April2018_198`, `PR_April2018_BG_all`) and contribute no footprint.
