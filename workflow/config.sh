# Settings for the island-wide workflow (docs/hpc-scaling-plan.md §5). Sourced by
# submit.sh and stage.sbatch. Export a variable before running to override it.

export PR_GAPS_DATA="${PR_GAPS_DATA:-/ibstorage/cam/G-LiHT/data}"
export PR_GAPS_GLIHT="${PR_GAPS_GLIHT:-$PR_GAPS_DATA/raw/gliht}"
export PR_GAPS_PLAN="${PR_GAPS_PLAN:-$PR_GAPS_DATA/interim/work_units}"
export PR_GAPS_RETILED="${PR_GAPS_RETILED:-$PR_GAPS_DATA/interim/retiled}"
# Task lists, logs and attempt records live here; status.csv is written here too.
export PR_GAPS_WORKFLOW="${PR_GAPS_WORKFLOW:-$PR_GAPS_DATA/workflow}"
PYTHON="${PYTHON:-.venv/bin/python}"
PARTITION="${PARTITION:-}"   # empty = the cluster default (R128C40)

# Stages in run order. A stage waits (afterok) for every stage in its AFTER list that
# is submitted in the same submit.sh call.
STAGES=(retile dtm step1 area voxels label join points qc gapcov gapcovjoin)

# CPUs, memory and time limit per task, and how many tasks may run at once (%M).
# Estimates until the pilot (M3) measures them; see status.csv for actual use.
declare -A CPUS=([retile]=1 [dtm]=1 [step1]=8 [area]=2 [voxels]=2 [label]=2 [join]=8 [points]=2 [qc]=8 [gapcov]=1 [gapcovjoin]=1)
declare -A MEM=([retile]=4G [dtm]=8G [step1]=16G [area]=16G [voxels]=8G [label]=4G [join]=64G [points]=8G [qc]=64G [gapcov]=4G [gapcovjoin]=32G)
declare -A TIME=([retile]=02:00:00 [dtm]=06:00:00 [step1]=04:00:00 [area]=08:00:00 [voxels]=02:00:00
                 [label]=01:00:00 [join]=06:00:00 [points]=02:00:00 [qc]=04:00:00
                 [gapcov]=01:00:00 [gapcovjoin]=04:00:00)
declare -A LIMIT=([retile]=40 [dtm]=1 [step1]=20 [area]=1 [voxels]=40 [label]=80 [join]=4 [points]=40 [qc]=1 [gapcov]=80 [gapcovjoin]=1)
declare -A AFTER=([retile]="" [dtm]="" [step1]="retile dtm" [area]="step1" [voxels]="step1" [label]="voxels"
                  [join]="label" [points]="join" [qc]="points"
                  [gapcov]="join" [gapcovjoin]="gapcov")
