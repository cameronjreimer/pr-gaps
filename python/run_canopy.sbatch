#!/bin/bash -l
# Slurm job for canopy.py. Submit from the repository root (pr-gaps/):
#
#   sbatch python/run_canopy.sbatch ev1      # site: lfdp (default), ev1, fia12
#   PR_GAPS_CONNECTIVITY=6 sbatch python/run_canopy.sbatch ev1   # faces-only gaps
#
# Edit the two paths below (or export them before sbatch, which passes your
# environment on). The log is written to <job-name>-<jobid>.out in the submit
# directory (sbatch -J canopy-ev1 ... to name it by site). Afterwards, time and
# peak memory (the per-km² benchmark) are in:
#
#   sacct -j <jobid> --format=JobID,Elapsed,MaxRSS,State
#
# Resources are sized for ev1 (711 M points, untiled); lfdp needs far less.
#SBATCH --job-name=canopy
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=04:00:00
#SBATCH --output=%x-%j.out
##SBATCH --partition=...      # uncomment if the cluster requires one
##SBATCH --account=...

set -euo pipefail

SITE="${1:-lfdp}"
export PR_GAPS_DATA="${PR_GAPS_DATA:-/ibstorage/cam/G-LiHT/data}"   # runs/ and interim/ live here
export PR_GAPS_GLIHT="${PR_GAPS_GLIHT:-/ibstorage/cam/G-LiHT/data/raw/gliht}"        # holds <campaign>/lidar/las/...
# export PR_GAPS_DTM=/path/to/PR_5March2017_EV1_DTM.tif        # only if not unpacked under PR_GAPS_GLIHT

cd "${SLURM_SUBMIT_DIR:-.}"
if [[ ! -f python/canopy.py ]]; then
    echo "Submit from the pr-gaps repository root (python/canopy.py not found in $PWD)" >&2
    exit 1
fi
for dir in "$PR_GAPS_DATA" "$PR_GAPS_GLIHT"; do
    if [[ ! -d "$dir" ]]; then
        echo "Not a directory: $dir (set PR_GAPS_DATA / PR_GAPS_GLIHT)" >&2
        exit 1
    fi
done

# The Linux CloudComPy wheel needs GCC >= 13.2's C++ runtime; the system's is older.
module load gcc/15.2.0
export LD_LIBRARY_PATH="$(dirname "$(gcc -print-file-name=libstdc++.so.6)"):${LD_LIBRARY_PATH:-}"
export QT_QPA_PLATFORM=offscreen     # no display in a batch job
export PR_GAPS_SITE="$SITE"          # PR_GAPS_THREADS follows --cpus-per-task

echo "[$(date '+%F %T')] $SITE on $(hostname), ${SLURM_CPUS_PER_TASK:-?} cpus, job ${SLURM_JOB_ID:-?}"
.venv/bin/python -u python/check_env.py   # seconds; fails fast on a broken environment
.venv/bin/python -u python/canopy.py
echo "[$(date '+%F %T')] finished"
