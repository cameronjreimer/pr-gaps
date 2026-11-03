#!/bin/bash -l
# Slurm job for backfill_lowest.py: adds the lowest 2018 return per 1 m column to a
# cache made before step 1 recorded it. Submit from the repository root (pr-gaps/):
#
#   sbatch python/run_backfill.sbatch ev1
#
# Reads only the cache's 2018 files; distances are untouched. Paths and environment
# as in run_canopy.sbatch. Check the result afterwards with:
#
#   .venv/bin/python python/check_run.py ev1
#
#SBATCH --job-name=backfill
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --output=%x-%j.out

set -euo pipefail

SITE="${1:-lfdp}"
export PR_GAPS_DATA="${PR_GAPS_DATA:-/ibstorage/cam/G-LiHT/data}"
export PR_GAPS_GLIHT="${PR_GAPS_GLIHT:-/ibstorage/cam/G-LiHT/data/raw/gliht}"

cd "${SLURM_SUBMIT_DIR:-.}"
if [[ ! -f python/backfill_lowest.py ]]; then
    echo "Submit from the pr-gaps repository root (python/backfill_lowest.py not found in $PWD)" >&2
    exit 1
fi

module load gcc/15.2.0
export LD_LIBRARY_PATH="$(dirname "$(gcc -print-file-name=libstdc++.so.6)"):${LD_LIBRARY_PATH:-}"
export QT_QPA_PLATFORM=offscreen
export PR_GAPS_SITE="$SITE"

echo "[$(date '+%F %T')] backfill $SITE on $(hostname), job ${SLURM_JOB_ID:-?}"
.venv/bin/python -u python/backfill_lowest.py
echo "[$(date '+%F %T')] finished"
