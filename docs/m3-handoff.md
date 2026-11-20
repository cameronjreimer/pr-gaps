# Handoff: M3 (ADR 009 windows and nulls) on the HPC

For a Claude session working on the cluster. Read this first, then
`docs/hpc-scaling-plan.md` (§5 Slurm layout, §7 milestones, §7.1 M3, §10 open questions)
and `docs/decisions/009-gap-definition-rule.md`. Written 2026-11-20.

## The project in one paragraph

pr-gaps maps canopy gaps created by Hurricane Maria in Puerto Rico from G-LiHT lidar.
Each 2017 (pre-storm) return gets a cloud-to-cloud (C2C) distance to the 2018
(post-storm) cloud (CloudComPy). Returns farther away than a threshold T are "changed".
Changed 1 m voxels are joined into 3D gap objects (26-connectivity, connected
components). The island is cut into work units, each one flight pair (2017 → 2018)
within a 1 km tile (EPSG:32620):

- step 1 caches the distances per unit;
- step 2 builds voxels, labels each tile, joins the tiles, then labels the points;
- QC and area accounting run after.

## Where things stand

- **The full island run is done** (M4, and M5 at all thresholds):
  - plan `833917a203ca7ff1`: 2,440 units, 1,821 tiles, 764 jobs;
  - step 1, area, step 2 at 2, 3, 4 and 5 m (island run `df81889aa38eecef`), and QC.
- **QC:**
  - units: 2,257 PASS, 138 WARN, 45 FAIL (all DTM / height-above-ground issues);
  - 16 of 225 pairs flagged for moderate registration problems, kept and flagged;
  - no 2017 record in two units;
  - 55,763.9 of 58,944.4 owned ha covered.
- **Rank 5:** the 2018 FIA11 campaign is in ellipsoidal heights. It is corrected by
  +41.82 m (`derived/registration/vertical_offsets.csv`) and verified after the rerun:
  ground_dz −0.18 m, ground C2C median 0.30 m, no longer flagged.
- **Rule: the island-wide gap results must not be examined until ADR 009 is Accepted.**
  Only counts have been looked at.

## Decisions already made (2026-11-20; don't reopen them)

- **The two 10% limits are confirmed:**
  - noise: null gap area ≤ 10% of the Maria gap area;
  - separation: largest gap ≤ 10% of gap volume per 25 ha window.
- **Observability is not part of the gap definition.** It becomes a per-gap covariate.
- **Dry-forest windows use the same eligibility rules** as the other strata. Expect
  about 3 chosen of about 4 eligible.
- **Connectivity is fixed at 26 and segmentation is connected components** (ADR 009
  rules 3–4).

## The M3 task

`python/windows.py`, documented in its docstring and in plan §7.1:

- `select` chooses 15 windows (500 × 500 m tile quarters):
  - 3 each in the dry, moist, wet and montane strata, plus 3 in EV1 (rank 30);
  - drawn at random with seed 20170920;
  - it reads no gap output, and refuses to run twice.
- `null NAME PRE POST` builds a same-epoch null plan: the same 2017 points as the Maria
  units, with another 2017 flight standing in for 2018.
- `report` writes `runs/canopy/adr009/`: the largest-gap share for each window and
  threshold, and the null ÷ Maria gap area for each threshold, with PASS/FAIL.

Each of these is a small plan folder run through the normal workflow. Point
`PR_GAPS_PLAN` at it and use a separate `PR_GAPS_WORKFLOW`. Unit IDs are prefixed
(`W01_`, `null-ev1_`), so the full run's caches are never replaced.

### Steps (run from the repo, `/ibstorage/cam/G-LiHT/pr-gaps`)

```bash
git pull
.venv/bin/python python/windows.py select
.venv/bin/python python/windows.py null ev1 PR_5March2017_EV1 PR_15March2017_EV1
.venv/bin/python python/windows.py null fia18 PR_12March2017_FIA18 PR_14March2017_FIA18

D=/ibstorage/cam/G-LiHT/data
PR_GAPS_PLAN=$D/interim/windows/plan PR_GAPS_WORKFLOW=$D/workflow_windows \
  workflow/submit.sh step1 voxels label join
PR_GAPS_PLAN=$D/interim/nulls/ev1/plan PR_GAPS_WORKFLOW=$D/workflow_null_ev1 \
  workflow/submit.sh step1 voxels label join points
PR_GAPS_PLAN=$D/interim/nulls/fia18/plan PR_GAPS_WORKFLOW=$D/workflow_null_fia18 \
  workflow/submit.sh step1 voxels label join points
```

Check progress with the same environment variables:

```bash
PR_GAPS_PLAN=... PR_GAPS_WORKFLOW=... .venv/bin/python python/status.py
```

When all three runs are done:

```bash
.venv/bin/python python/windows.py report
```

### What to expect, and what to check

- **`select`:** a local trial (with QC ignored) found about 4 eligible dry windows in
  3 pairs, 9 montane windows in 4 pairs, and about 100 each for moist and wet.
  - On the cluster it uses the real QC, so counts may be a little lower.
  - If a stratum ends up with fewer than 3 windows, report it. Don't relax the rules
    without the user's decision.
- **Null sizes:** the `ev1` null is 9 units (~484 ha owned) and the `fia18` null is 46
  units (~1,917 ha owned). Their actual coverage is smaller, about 989 ha of two-flight
  overlap for FIA18.
- **Nothing in this pipeline has run end to end yet.** Possible failure points:
  - a null unit with no 15 March points in its columns (empty cache);
  - `report`'s check that the null and Maria caches hold the same 2017 points (it
    compares counts and the first 1,000 xyz). If it fails, the caches keep different
    point sets, and the comparison has to work by column rather than by point.
  - The island QC flags are looked up by plan hash, so `join` on these plans logs "no
    island QC … main_pair_flags left empty". That is expected.
- **Applying the rule (ADR 009 rule 2):** the gap-object threshold is the lowest
  candidate (2, 3, 4, 5 m) that passes both noise tests and separation in every
  window. Field agreement at LFDP already passed at 2 and 3 m and failed at 4 and 5 m.
  - The provisional answer from LFDP is 3 m.
  - If no threshold passes in some stratum, that stratum is flagged (rule 6). There is
    no stratum-specific threshold.
  - Then fill in the selected values in ADR 009 and set its Status to Accepted, dated.
- **Also measure for M3:** per-unit time and memory, from `sacct` or `status.csv`, to
  replace the estimates in plan §5 / `workflow/config.sh`.

## Still open after this (plan §10)

- D7: whether any of the 16 flagged pairs is corrected or excluded. Decided after the
  noise test. Only 0.04% of 2 m gaps lie on flagged pairs.
- The between-flight test at pair borders (§4.1, item 4).
- Then M5's sensitivity set (ADR 009 rule 5) and M6.

## How to work

- **Code:** the repo is `github.com/cameronjreimer/pr-gaps`, cloned both on the
  user's Windows PC and on the cluster. The user commits and pushes; the cluster
  `git pull`s. If you edit code on the cluster, say so clearly, so the user can commit
  it there and the two clones don't diverge.
- **Cluster:** Slurm.
  - Partition R128C40: 8 nodes × 40 CPUs × 128 GB. Partition R256C128: 2 nodes.
  - `MaxArraySize` is 30001.
  - Data is in `/ibstorage/cam/G-LiHT/data`. Python is `.venv/bin/python`, set up by
    `workflow/env.sh` (needs gcc ≥ 13; it keeps `/usr/lib64` off `LD_LIBRARY_PATH`).
- **Workflow:**
  - `workflow/submit.sh [--retry-failed] STAGE...` chains stages with `afterok` only
    within one call.
  - A task that fails twice is held until `--retry-failed`.
  - Attempts are logged in `$PR_GAPS_WORKFLOW/attempts/` and logs in
    `$PR_GAPS_WORKFLOW/logs/`.
- **Record every decision**, dated, in the ADR or plan doc it affects. The user makes
  the methodological choices; recommend, don't decide.
