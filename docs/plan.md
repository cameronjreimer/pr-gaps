# Canopy Gap Delineation in Puerto Rico — 13-Week Plan

**Window:** late August – late November 2026
**Capacity:** 20–30 hrs/week (~300 hours total)
**Primary deliverable:** dissertation chapter, ecology-forward
**Checkpoint:** AGU talk, week 13
**Deferred:** code and gap polygon release (post-chapter)

---

## Ecological questions

### Primary — answerable from the Maria interval alone

**Q1. What functional form describes the canopy gap size-frequency distribution produced by a major hurricane across a tropical island?**
A model-selection question, not a curve-fitting one. Candidate set: single power law, truncated power law, piecewise power law, lognormal, exponential, Weibull. The claim that a piecewise form fits best is only meaningful against that set.
*Depends on:* sufficient large gaps for the tail; §2.7.

**Q2. If the distribution is piecewise, where does the breakpoint fall, and does it mean anything?**
An ecologically real breakpoint would mark a transition between damage mechanisms — individual crown and branch loss at small sizes, multi-tree blowdown and landslide-scale patch damage at large ones. An artifactual breakpoint tracks the detection floor. Distinguishing these is the single most load-bearing analysis in the chapter.
*Depends on:* the size-dependent detection function from synthetic gap insertion; §2.6.

**Q3. Does gap size scaling vary across forest types and along environmental gradients?**
A steeper exponent means damage concentrated in small gaps; a shallower one means relatively more large gaps. Gradients of interest: moisture, elevation, topographic exposure.
*Depends on:* enough large gaps per stratum — the constraint most likely to bite; §2.9, §3.1.

**Q4. Does disturbance rate vary independently of disturbance shape?**
Gap density and fraction of area in gaps per unit time are a separate axis from the exponent. Two landscapes can share a slope while one is disturbed ten times as much. Whether shape and rate covary across the island is itself a result, and rate is the quantity Earth system models most need.
*Depends on:* accurate per-stratum area accounting; §2.10.

**Q5. Does land use legacy or recovery stage mediate hurricane damage?**
Puerto Rico's forests are largely secondary, and stand age and prior land use shape composition, stem density, and wood properties. If younger stands show different gap scaling or higher gap density, disturbance susceptibility is partly a function of recovery stage — which speaks directly to how demographic models should couple disturbance to stand structure.
*Depends on:* whether land use is separable from elevation and moisture; §3.4.

**Q6. Is structure or composition the better predictor?**
Pre-hurricane canopy height and structural heterogeneity are measurable from the same LiDAR. If they predict gap scaling better than climate-based forest type does, the mechanism is structural rather than compositional, and disturbance can be parameterized from structure alone — a substantially more portable result for modeling.
*Depends on:* covariate stack assembled in week 2.

**Q7. How much does topographic exposure explain relative to forest type?**
If windward aspect and slope position dominate, the disturbance regime is primarily a function of storm interaction with terrain rather than of vegetation. This is a genuine alternative hypothesis to the chapter's framing and should be tested rather than assumed away.
*Depends on:* exposure metrics in the covariate stack; confounded with terrain slope, so §4 confound 1 applies directly.

### Stretch — require the recovery interval (week-9 gate)

**Q8. Do hurricane and recovery-period disturbance produce different size-frequency distributions?**
The between-interval contrast in the abstract. A higher relative frequency of large gaps under hurricane forcing would indicate that disturbance regime is agent-specific rather than a fixed landscape property.

**Q9. How do Maria's gaps evolve over 2018–2020 — closing, persisting, or expanding?**
Requires tracking individual gap polygons across intervals. Gap closure rate as a function of gap size is a distinct and valuable result, and expansion would indicate delayed mortality along gap edges.

**Q10. Do the same environmental controls govern both intervals?**
If the gradients that predict hurricane damage also predict recovery-period disturbance, the regime is a property of the landscape. If not, it is a property of the agent.

### Methodological, subordinate but reportable

**Q11.** Does point-wise change detection delineate gaps more consistently across forest types than CHM differencing, and what is its detection function? Consistency is not accuracy, so this needs an operational criterion — see §2.6.

**Q12.** How sensitive are gap scaling exponents to the definition of a gap? Testing absolute against relative vertical criteria (§3.3) yields a direct answer, which is useful to anyone comparing exponents across the published literature.

### What this project cannot answer

Stated plainly here so the limitations section writes itself, and so no claim drifts beyond the evidence.

- **Gaps are canopy openings, not mortality.** Defoliation, branch loss, and crown snap all produce gaps without killing the tree; a dead standing tree produces little canopy change. The abstract's language about integrating damage and mortality overstates what repeat LiDAR alone can distinguish. Field plots can calibrate this relationship locally, not island-wide.
- **Biomass loss is not quantified** without allometry and stem-level data. Gap area is a proxy with a poorly constrained conversion.
- **Species-level susceptibility** is out of reach without co-located composition data.
- **A single hurricane is a signature, not a regime.** Regime language requires either the recovery interval or explicit framing as a single-event characterization.

---

## 1. Decisions locked

| Decision | Resolution |
|---|---|
| Chapter framing | Ecology-forward; method supports rather than headlines |
| Temporal scope | 2017–2018 (Maria) is the chapter core; 2018–2020 is a week-9 go/no-go |
| Spatial scope | Set by week-3 swath inventory × week-2 benchmark — **open** |
| Change detection | Absolute point-wise distance detects change; a separate signed rule classifies loss vs gain |
| Threshold | Spatially varying, from registration residual + local point density |
| Vertical criterion | Test absolute vs relative on prototype sites; pick one at freeze — **open** |
| Minimum gap size | Uniform floor matched to published studies, held constant across strata |
| Validation | Synthetic gap insertion + split-cloud nulls + stable-surface targets; field plots as independent check |
| Fitting | MLE (Clauset-style), candidate model set, custom piecewise likelihood with bootstrapped breakpoint |
| Model structure | Hierarchical: one categorical grouping, age and environment continuous |
| Response variables | Size-frequency distribution **and** gap density per unit area per unit time |
| Masking | Pre-interval land cover; masked area recorded per stratum |
| Parameter freeze | End of week 6 — no tuning after, only documentation and sensitivity tests |

---

## 2. Why these decisions

### 2.1 Ecology-forward framing

**Reasoning.** The chapter has to survive any outcome. Framed as "slopes differ by forest type," a null result guts it. Framed as "we quantify tropical disturbance regimes with a method robust to acquisition differences, and here is what the distributions look like," a single power law, an absent forest-type effect, or a breakpoint that proves to be a detection artifact are all reportable.

**Pros.** Outcome-robust. Speaks to the demographic and Earth system modeling audience the abstract invokes. Keeps the writing focused on ecological interpretation, which is what a committee evaluates.

**Cons.** Undersells genuine methodological novelty, which might merit its own paper. Reviewers may still demand full method validation while the framing gives it less room. If the method comparison turns out to be the more surprising result, the framing fights the finding.

**Revisit if.** Week 5–6 validation shows the point-wise versus CHM difference is large and systematic. That would be a methods paper, and it would be worth restructuring for.

### 2.2 Maria interval as the core, recovery deferred

**Reasoning.** The unsigned-distance problem is most damaging in the regrowth interval, where growth dominates the change signal. Loss dominates 2017–2018, so the same classification error costs far less there.

**Pros.** Roughly halves the risk surface. Concentrates limited validation effort on one interval. Still yields a complete story: the structural signature of a category-4 hurricane across an island-wide moisture and stature gradient.

**Cons.** Loses the between-interval contrast that made the abstract compelling. "Disturbance regime" arguably requires more than one interval — a single event is a signature, not a regime, and the framing should say so honestly if recovery is dropped. Reviewers may read a single interval as a snapshot.

**Guidance at the week-9 gate.** Extend to recovery only if all three hold: the signed classifier's false-positive rate in growth-dominated areas is characterized and acceptable, the Maria interval analysis is complete, and three or more weeks remain. If any fails, present recovery as preliminary in the talk and reframe the chapter around the hurricane signature.

### 2.3 Hybrid detection and classification

**Reasoning.** Absolute point-wise distance is a good detector — it is less sensitive to canopy surface interpolation error than CHM differencing, which is where its real advantage lies. It is a poor classifier, because it is unsigned. Splitting the two roles keeps the stated novelty and confines the new machinery to a well-defined second stage.

**Pros.** Two-stage story is easy to explain and defend. Detection stage retains the robustness advantage over CHM differencing. Modular: the classifier can be swapped without redoing detection. Does not require rewriting the method described in the submitted abstract.

**Cons.** Two thresholds instead of one, each needing separate justification and sensitivity testing. Errors compound across stages, and the compound error rate is harder to characterize than a single-stage method's. It is not one coherent statistical framework, which a methodologically-minded reviewer may find inelegant. If the classifier ends up being essentially CHM-based, some of the claimed advantage over CHM differencing quietly evaporates — worth checking honestly.

**Alternatives considered.**

*Column-wise vertical profile comparison.* For each cell, test whether the return height distribution shifted down or up. Cleaner and single-stage, handles canopy well since it needs no surface normals. Rejected because it redefines what the method is, four months after the abstract described it — but it is the better long-term design, and worth building if this becomes a methods paper.

*Asymmetric point-to-cloud distances.* Points present at t1 with no t2 neighbour indicate removal; the reverse indicates accretion. Elegant and directly signed. Rejected because asymmetry is highly sensitive to point density differences between campaigns, which is precisely the confound the design is trying to avoid.

### 2.4 Spatially varying threshold

**Reasoning.** Registration residual and point density vary across the island and covary with terrain slope, which covaries with forest type. A single fixed threshold inherits every one of those spatial patterns as apparent ecology.

**Pros.** Removes the largest confound. Standard practice in geomorphic change detection, so it comes with precedent and a vocabulary. Makes the detection limit an explicit, reportable quantity rather than an unstated assumption.

**Cons.** A variable detection limit means a variable lower truncation, which is why the uniform minimum gap size is required alongside it — the two decisions are a package. More complex to implement and to explain in a talk. Depends on reliable residual estimates; if the week-2 alignment assessment produces noisy residuals, the threshold surface inherits that noise.

### 2.5 Uniform minimum gap size at a literature floor

**Reasoning.** The piecewise breakpoint sits near the small end of the distribution. If the truncation point varies by stratum, the breakpoint comparison is measuring the detection limit, not ecology.

**Pros.** Cross-stratum comparability, which the chapter's central comparison requires. Comparability with published scaling exponents. Protects the breakpoint claim.

**Cons.** Discards real small gaps in high-quality areas, reducing sample size where data are best. Creates a conflict if the worst-case detection limit exceeds the literature floor — resolvable only by raising the floor (losing comparability) or dropping swaths (losing area). Both are real costs and one must be paid.

### 2.6 Validation without truth data

**Reasoning.** Field validation of gap delineation at island scale is not achievable in three months. Synthetic and internal-consistency approaches are, and they answer the specific questions that threaten the chapter.

**Pros.** Fully controlled, arbitrarily replicable, no permissions or lead time. Synthetic insertion yields a size-dependent detection function, which is the only thing that can demonstrate the breakpoint is not an artifact of the detection floor. Split-cloud nulls give a false-positive rate stratified by slope, density, and forest type, addressing the dominant confound directly. Both run on data in hand.

**Cons.** Synthetic gaps are idealized — removing points is not the same as a real treefall, which leaves debris, leaning boles, and partially damaged crowns, so detection rates from synthetic tests are probably optimistic. Split-cloud halves the density, so it characterizes error at half the operational density rather than at full density; treat the result as an upper bound and note the direction of the bias. Stable-surface targets are non-forest, so they capture registration and processing error but not canopy-specific error. Field plots partially cover these gaps, which is why they stay in as an independent check.

### 2.7 MLE fitting

**Reasoning.** Log-log binned regression is biased, and binning choices move the exponent. It also is not a likelihood, so "best described by a piecewise power law" cannot be tested with it.

**Pros.** Standard, defensible, enables honest model comparison across the candidate set. Makes the lower-bound choice explicit instead of hidden in binning.

**Cons.** Sensitive to lower-bound selection. The piecewise variant has no off-the-shelf implementation and must be hand-built with a bootstrapped breakpoint interval — budget a week. Assumes independent observations, which gaps from a single hurricane are not: they cluster by storm track, terrain exposure, and forest condition. Naive confidence intervals will be too narrow. Mitigation: block bootstrap by watershed or tile rather than resampling gaps independently. This should be stated explicitly in the methods, since it is the kind of thing a statistically-inclined committee member will ask about and few gap papers address.

**Also.** Finite study area censors the largest gaps. Either fit a truncated model or state the censoring explicitly; do not let an upper-tail claim rest on an uncensored fit.

### 2.8 Slopes at both estimated and fixed lower bounds

**Reasoning.** KS-minimizing lower-bound selection picks a different bound per stratum, so the resulting slopes are not comparable — which undoes the comparability bought by the uniform floor.

**Pros.** The two numbers answer different questions: estimated bound characterizes each distribution on its own terms; fixed bound enables the cross-stratum comparison.

**Cons.** Two sets of numbers to present and explain, with real potential to confuse a reader or an audience. Pick one for the headline figure and put the other in a table.

### 2.9 Hierarchical model, one categorical grouping

**Reasoning.** Tail exponents are estimated from the largest gaps, so precision depends on the number of large gaps, not total gaps. Some strata will not support an independent fit. Partial pooling lets them contribute without pretending to a precision they don't have.

**Pros.** Every gap informs every parameter. Under-sampled strata get wide, honest intervals rather than no estimate. Sharpens the ecological question from "do types differ" to "how does gap scaling vary along the moisture and recovery gradients." Avoids the cell-thinning that crossing two categorical factors would cause.

**Cons.** Substantially less standard than fitting distributions per stratum. Requires modeling gap size with a covariate-dependent exponent — a truncated Pareto likelihood with the exponent as a function of covariates and a stratum-level random effect — which needs building and defending. Priors require justification. Harder to present in a twelve-minute talk than a panel of fitted lines.

**Guidance.** Build the simple version first: fit distributions independently per stratum, with intervals, and treat that as a check on the hierarchical model. If the two disagree qualitatively, the disagreement is diagnostic and should be investigated before either is trusted. The stratum-wise version is also the better talk figure.

### 2.10 Reporting both distribution and density

**Reasoning.** Size-frequency describes shape, not rate. Two landscapes can share a slope while one experiences ten times the disturbance. The Earth system modeling audience cares more about rate.

**Pros.** Directly addresses the biogeochemical framing in the abstract. Density is easier to communicate and harder to get wrong than an exponent. Provides a fallback result if the distribution fitting proves inconclusive.

**Cons.** Requires accurate per-stratum usable-area denominators, net of masking and unusable swaths, tracked through the pipeline from the start. Density is sensitive to mask errors in a way that the size distribution is not — a mask that removes 20% of a stratum inflates density by 25% if unaccounted.

### 2.11 Pre-interval land cover mask

**Reasoning.** A post-Maria classification will misclassify defoliated forest as non-forest, removing precisely the most heavily damaged pixels and truncating the large-gap tail.

**Pros.** Avoids a bias that acts directly against the chapter's main signal.

**Cons.** Date mismatch means land use change within the interval is unmasked — a field cleared in 2017 still counts as forest. Classification errors propagate directly into the density denominator. Consider a coarse visual audit of the largest detected gaps, which is cheap and catches the suspiciously rectangular ones.

### 2.12 Parameter freeze at week 6

**Reasoning.** With no committee deadline and a written expectation already on record, nothing else structurally prevents tuning toward the anticipated answer.

**Pros.** Protects the analysis from the anchoring problem. Forces the schedule to be real. Gives a clean answer when asked how thresholds were set.

**Cons.** May lock in a suboptimal choice. Slips if the week-3 inventory is late, and a slipped freeze cascades into everything downstream. Treat week 6 as a hard date and reduce scope rather than extend it.

---

## 3. Open decisions: options and guidance

### 3.1 Spatial scope — decide week 3

**Options.** Island-wide across all usable repeat coverage; or a stratified sample of watersheds.

**Decision rule.** Multiply the week-2 per-km² benchmark by the week-3 usable area. Add the batch conversion and QC overhead. If the full run cannot complete with at least three weeks of slack before the week-9 gate, sample.

**If sampling, design guidance.** Stratify by forest type and elevation so the gradient is spanned rather than sampled proportionally — proportional sampling will underrepresent dry forest, which is already your thin stratum. Use whole watersheds as sampling units so large gaps aren't clipped by unit boundaries. Randomize within strata and record inclusion probabilities, because density estimates are only unbiased if you can weight by them. Document the design before drawing the sample.

**Pros of sampling.** Faster, cheaper, leaves time for validation and writing. Allows deliberate over-sampling of under-represented strata. **Cons.** Weakens the "across Puerto Rico" claim in the abstract. Requires defending the design. Reduces total gap counts, which are already the binding constraint on the tail fits.

### 3.2 Forest type classification — decide week 2

**Options.** Holdridge life zones; an aggregated land cover classification; forest age and land use classes.

**Non-negotiable criterion.** Independent of LiDAR structure. A structure-derived classification builds part of the answer into the predictor, and since Maria altered structure, the classification would differ depending on which campaign produced it.

**Holdridge.** *Pros:* standard for Puerto Rico, climate-based so fully independent of the response, maps cleanly onto the moisture gradient, small number of classes keeps cells populated, comparable to prior work. *Cons:* coarse, and boundaries are climatic rather than vegetational, so within-zone structural heterogeneity is high.

**Aggregated land cover.** *Pros:* finer vegetational resolution, closer to actual composition. *Cons:* aggregation choices are yours to defend and they affect the result; more classes means thinner cells; some classes reflect management rather than ecology.

**Guidance.** Choose based on which better explains variation in pre-hurricane canopy structure — a quick check you can run in week 2 with the covariate stack. If they perform comparably, take Holdridge for its independence and its precedent.

### 3.3 Vertical criterion — decide at freeze, week 6

**Options.** Absolute height-drop threshold; absolute post-change height threshold (Brokaw-comparable); relative criterion scaled to local canopy height.

**The tension.** Absolute criteria are comparable to published work but biased across a stature gradient spanning roughly 5 m dry forest to 25 m montane forest. Relative criteria are comparable across strata but not directly comparable to the literature, and "40% canopy height loss" is a less intuitive object than "gap to within 2 m of the ground."

**Guidance.** Given that cross-stratum comparison is the chapter's core and stature range is wide, relative should be the default primary. Run both in weeks 4–5. If the two give qualitatively similar answers about stratum differences, use relative as primary and absolute as sensitivity, and say the result is robust to the definition. If they diverge, that divergence is a finding — report it prominently rather than choosing the more agreeable one, because it tells the field something about how sensitive published gap distributions are to definition.

**Do not** carry both definitions through the full analysis. It doubles every fit and leaves readers unsure which numbers are the result.

### 3.4 Age variable form and prior land use — decide week 2

Rule fixed in advance:

- Age enters as a continuous covariate if the layer has three or more ordered levels. Use bin midpoints offset to the acquisition date, and state the coarseness in the methods.
- If age is effectively binary, it becomes a factor and competes with forest type for the single categorical slot.
- Prior land use enters only if it is mapped across the usable area, retains sufficient gaps per class after masking, and is not collinear with forest type, elevation, or rainfall.
- If the land use × forest type cross-tabulation is near-diagonal, keep only one. Default to prior land use, which carries compositional information relevant to damage susceptibility.

**Why collinearity is the likely outcome.** Puerto Rican land use history is arranged along elevation — cane on the coastal plain, coffee in the mid-elevation montane belt, uncleared remnants on the steepest high ground. Prior land use may be close to a relabeling of the moisture gradient already in the model. Including both then produces uninterpretable coefficients.

### 3.5 Common lower bound value — decide week 8

**Options.** Set equal to the minimum gap size floor; set at the largest estimated stratum-wise bound; set at a value from the comparison literature.

**Guidance.** The fixed bound must be at or above every stratum's detection limit, otherwise the comparison reintroduces exactly the truncation confound it exists to remove. Among values satisfying that, prefer one used in published work. Report how sensitive the slope comparison is to this choice — it is a natural target for the sensitivity block, and a comparison that survives it is considerably more convincing.

### 3.6 Tile size — decide week 4, before the freeze

**Options.** Small tiles (memory-friendly, more edge effects); large tiles (fewer edges, memory-hungry).

**Guidance.** Tile edge length should comfortably exceed the largest expected gap dimension — Maria produced very large contiguous damage patches, and a gap split across tiles becomes two smaller gaps, truncating the upper tail your abstract makes a claim about. Use buffered tiles with a merge step for gaps crossing boundaries, and verify by checking whether the gap size distribution changes when tile size is doubled on a test area. If it does, tiles are too small.

### 3.7 Target journal — decide before week 11

**Guidance.** Choose before drafting, since structure and length differ substantially between a remote sensing venue and an ecology venue. The framing decision in 2.1 points toward ecology, but if the week-5 validation elevates the method, reconsider. Decide once and write to it.

---

## 4. The structural risk

Puerto Rico's forest types differ in canopy stature, terrain slope, and sampling density — the exact properties the method is sensitive to. Four distinct confounds all alias onto forest type, and all push toward the result the placeholder abstract already predicts:

1. **Co-registration error × terrain slope.** Horizontal misalignment converts to apparent vertical change on steep ground. Steep ground is wet montane forest.
2. **Point density × campaign.** Sparser clouds yield larger nearest-neighbour distances. Density differs between campaigns, which is the between-interval comparison.
3. **Vertical criterion × canopy stature.** Any absolute height rule is unsatisfiable in short dry forest and lenient in tall wet forest.
4. **Detection limit × lower truncation.** A spatially varying detection floor shifts the small-gap cutoff by stratum, moving the piecewise breakpoint.

Because a written expectation exists, a confirming result is weak evidence. Countermeasures: the dated pre-specification (week 5–6), the stratified false-positive tests (week 4–5), and the sensitivity block (week 10).

---

## 5. Schedule

### Weeks 1–3 — Foundation and scoping

**Week 1**
- Confirm bulk transfer path off the login/data-transfer node; verify restartability under time limits
- Compile flight metadata for all three campaigns: altitude AGL, scan angle range, pulse rate, acquisition dates, flight-line geometry
- Benchmark change detection wall-time per km² on a prototype site; extrapolate against candidate scopes
- Check drought indices for each acquisition window
- Begin literature (see §6) — runs in background all quarter, not as a block

**Week 2**
- Alignment assessment: residual offsets in x, y, z on stable hard surfaces across the elevation and slope range; test whether residual magnitude correlates with terrain slope
- Point density comparison across campaigns: returns/m² gridded over the overlap, comparing distributions rather than means
- Assemble covariate stack: pre-interval land cover mask, forest type layer, forest age layer, elevation, mean annual rainfall, topographic exposure, pre-hurricane canopy height
- Decide forest type classification (§3.2)
- Inspect age layer; cross-tabulate prior land use × forest type; apply the rule in §3.4

**Week 3**
- Deliver **usable-swath inventory**: area per interval surviving alignment and density screening, with per-stratum area accounting net of masking
- Resolve the floor conflict if worst-case detection limit exceeds the literature minimum gap size
- **Set spatial scope** (§3.1)
- **Send #1 to advisor:** scope memo + inventory (feedback returns wk 4–5)

### Weeks 4–6 — Method, validation, freeze

**Week 4**
- Implement signed loss/gain classification on prototype sites
- Run both vertical criteria side by side on prototype sites
- Set tile scheme (§3.6)

**Week 5**
- Split-cloud resampling null, stratified by slope, density, and forest type
- Stable-surface between-campaign null
- Synthetic gap insertion → size-dependent detection function
- Simulation-based power analysis: what slope difference is detectable given expected counts?
- Construct noise-model threshold from week-2 residuals

**Week 6**
- Write and date the **pre-specification**: parameter values, model structure, predictions. Commit to repo
- Select primary vertical criterion (§3.3)
- **PARAMETER FREEZE**

### Weeks 7–9 — Scale and fit

**Week 7**
- Convert manual scripts to tiled batch workflow: restartable, logged, per-tile parameter provenance, per-stratum area accounting
- Decide repository structure and license now

**Week 8**
- Full run at chosen scope; QC outputs; generate gap polygons
- Fit distributions: MLE with candidate set; hand-built two-segment likelihood; block bootstrap by watershed for intervals
- Slopes at both estimated and fixed lower bounds (§3.5)

**Week 9**
- Stratum-wise fits first, then the hierarchical model; compare the two
- Gap density per unit area per unit time by stratum
- **GO/NO-GO on the recovery interval** (§2.2)
- **Send #2 to advisor:** results memo (feedback returns wk 10–11)

### Weeks 10–13 — Sensitivity, writing, talk

**Week 10**
- Sensitivity block: alternative vertical criterion, lower bound, minimum gap size, tile size, threshold specification
- Verify the breakpoint is not tracking the detection floor
- Field plot comparison as independent check

**Week 11**
- Figures; methods and results draft
- **Send #3 to advisor:** chapter draft (feedback returns wk 12–13)

**Week 12**
- Build AGU talk; pick the single core figure
- Circulate method claims to G-LiHT collaborators if co-authorship is expected

**Week 13**
- Rehearse talk; incorporate feedback; revise chapter draft

---

## 6. Literature — distributed, not blocked

Roughly 2–3 hours/week against five targets:

1. **Gap size-frequency theory and measurement** — Brokaw's gap definition and its descendants; LiDAR-based gap mapping and scaling exponents; how studies set minimum gap size and lower bounds. Needed by week 3.
2. **Point cloud change detection** — distance-based methods and level-of-detection formulations; critiques of CHM differencing. Needed by week 4.
3. **Heavy-tailed distribution fitting** — maximum likelihood estimation and model comparison for power laws; piecewise and truncated variants; dependence and bootstrap approaches. Needed by week 8.
4. **Hurricane Maria and Puerto Rican forest response** — damage patterns, mortality, structural recovery rates. Needed weeks 9–11.
5. **Puerto Rican land use legacy** — forest age mapping, secondary forest structure, recovery-stage effects on structure. Needed by week 2.

The `literature-search` skill enforces web verification of every citation; worth using for targets 1 and 4.

---

## 7. Failure modes and responses

| If | Then |
|---|---|
| Registration residuals are large and slope-correlated | Rigidly align before detection, rerun prototypes. Costs ~1 week. Must precede the freeze |
| Benchmark shows island-wide is infeasible | Stratified watershed sample per §3.1. Take it without agonizing |
| False-positive rate varies by forest type | Cross-stratum comparison is compromised. Report the error structure; consider restricting to strata with comparable rates |
| Breakpoint tracks the detection floor | Report it as a detection artifact. This is a legitimate methodological result |
| Vertical criteria disagree | Report the disagreement as a finding about definitional sensitivity |
| Slopes don't differ by stratum | Chapter stands under the §2.1 framing. Do not search for a parameterization that produces a difference |
| Hierarchical and stratum-wise fits disagree | Diagnose before trusting either. Usually indicates a stratum with pathological sample size or an outlier gap |
| Method isn't defensible by week 6 | The ecology-forward chapter doesn't happen this cycle. Better known in October than December |

---

## 8. Open items by date

| Decision | Due | Section |
|---|---|---|
| Forest type classification | Week 2 | §3.2 |
| Age form; prior land use in or out | Week 2 | §3.4 |
| Spatial scope | Week 3 | §3.1 |
| Tile size | Week 4 | §3.6 |
| Primary vertical criterion | Week 6 | §3.3 |
| Common lower bound | Week 8 | §3.5 |
| Recovery interval in or out | Week 9 | §2.2 |
| Target journal | Week 11 | §3.7 |

---

## Appendix A. Repository and data layout

Three principles drive this: raw data is immutable, code and data live apart, and every pipeline run is a self-describing immutable artifact rather than a directory you overwrite.

### A.1 Code repository (git, small, backed up)

```
pr-gaps/
  README.md
  environment.yml            # or requirements.txt; container definition if available
  .gitignore                 # excludes all data paths
  docs/
    plan.md                  # this document
    prespecification.md      # written and committed at the week-6 freeze, dated
    decisions/               # one short file per decision, ADR-style
      001-forest-type-classification.md
      002-age-and-land-use.md
      003-spatial-scope.md
      004-vertical-criterion.md
      ...
  config/
    base.yaml                # the frozen parameter set
    sensitivity/
      vertical-absolute.yaml
      xmin-alternative.yaml
      tile-doubled.yaml
      mmu-raised.yaml
  src/
    ingest/                  # download, metadata parsing, checksums
    align/                   # residual assessment, rigid alignment
    detect/                  # point-wise distance
    classify/                # signed loss vs gain
    delineate/               # thresholding, MMU, connectivity, cross-tile merge
    validate/                # synthetic gaps, split-cloud null, stable surfaces
    stats/                   # MLE, piecewise likelihood, hierarchical model, bootstrap
    figures/
    utils/
  workflow/                  # Snakemake/Nextflow rules or SLURM submit scripts
  notebooks/                 # exploration only — never on the pipeline path
  tests/
```

### A.2 Data root (large storage, referenced by an environment variable)

```
$PR_GAPS_DATA/
  raw/                       # chmod a-w after ingest. Nothing writes here, ever.
    gliht/{2017,2018,2020}/
    covariates/              # land cover, forest age, DEM, rainfall, exposure
    field/                   # plot data
    MANIFEST.md              # source URLs, download dates, checksums
  interim/
    aligned/                 # post-registration clouds
    tiles/                   # tiled, density-normalised clouds
  runs/
    2026-10-14_baseline_a1b2c3/
      config.yaml            # exact copy of the config used
      manifest.json          # git commit, package versions, input checksums, timestamp
      logs/                  # per-tile
      tiles/                 # per-tile outputs
      gaps/                  # merged polygons
      area/                  # per-stratum usable area, net of masking
    2026-10-22_sens-vertical-absolute_d4e5f6/
    ...
  derived/
    inventory/               # week-3 usable-swath inventory
    validation/              # detection function, false-positive rates by stratum
  results/                   # fits, model objects, tables — back this up
  figures/
```

### A.3 Conventions that matter

**Raw is read-only.** Set the permission bit rather than relying on discipline. Every reprocessing decision then has to produce a new file somewhere else, which is what you want.

**One run, one directory, never overwritten.** Run IDs as `date_name_confighash` sort chronologically and are self-identifying. The sensitivity block in week 10 produces five or six runs that must be comparable; if they overwrite each other you cannot compare them, and if they are named `final`, `final2`, `final_actually` you will not know in December which produced which figure.

**`manifest.json` is the provenance record.** Git commit hash, package versions, input file checksums, wall time, and the config hash. This is what makes the freeze verifiable — you can demonstrate that the run producing your results used the parameters committed at week 6, rather than asserting it.

**Area accounting travels with the run,** not with the project. Masking and scope decisions change the denominator, so a density estimate is only interpretable next to the area file from the same run.

**Decisions get a file each.** Two paragraphs: what was decided, what the alternatives were, what evidence settled it, date. Section 3 of this plan gives you eight of them prewritten. These become your methods section and your defence answers, and they take five minutes each if written when the decision is made rather than reconstructed in November.

**Data root as an environment variable,** never hardcoded paths. You will move this data at least once — between scratch and project storage, if nothing else.

### A.4 Storage tier caution

If your cluster purges scratch on a timer, `raw/` does not belong there, or it belongs there only alongside a `MANIFEST.md` complete enough to re-download unattended. `interim/` is the natural scratch resident since it is reproducible from raw. `results/`, `derived/`, and `runs/*/manifest.json` should live on backed-up storage — they are small and they are the expensive part to regenerate.

### A.5 Release path

Deferring the release is fine as long as the layout makes it a copy rather than an excavation. When the time comes: the code repository, one run directory, `derived/`, and `results/`, plus the raw manifest so others can obtain the inputs. If runs are self-describing from week 7, this is an afternoon. If they aren't, it is a week of reconstructing what produced what.
