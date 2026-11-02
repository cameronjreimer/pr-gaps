#!/bin/bash -l
# Slurm array job: canopy rugosity for every 2017 G-LiHT campaign
# (scripts/03_download_covars.R --rugosity). Submit from the repository root
# (pr-gaps/):
#
#   sbatch scripts/run_rugosity.sbatch
#
# Each array task takes every N-th campaign (--slice k/N), so the 8 tasks below
# split ~148 campaigns between them. Re-submitting is safe: finished rasters are
# skipped, so only what is missing is computed. Outputs:
#   $PR_GAPS_DATA/interim/covariates/rugosity/<campaign>_CHM_rugosity_41m.tif
#
# CHMs are read from $PR_GAPS_GLIHT/<campaign>/lidar/geotiff/: the unpacked
# <campaign>_CHM.tif or <campaign>_CHM/ folder that 02_download.R leaves, or, if
# that is absent, the packed _CHM.tif.gz / _CHM.tar.gz as the G-LiHT server
# publishes it (unpacked into $PR_GAPS_SCRATCH and deleted afterwards). Point
# PR_GAPS_GLIHT at whichever tree holds all 2017 campaigns.
#
# Afterwards: sacct -j <jobid> --format=JobID,Elapsed,MaxRSS,State
#SBATCH --job-name=rugosity
#SBATCH --array=1-8
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --time=08:00:00
#SBATCH --output=%x-%A_%a.out
##SBATCH --partition=...      # uncomment if the cluster requires one
##SBATCH --account=...

set -uo pipefail

export PR_GAPS_DATA="${PR_GAPS_DATA:-/ibstorage/cam/G-LiHT/data}"            # interim/ is written here
export PR_GAPS_GLIHT="${PR_GAPS_GLIHT:-/ibstorage/cam/G-LiHT/data/raw/gliht}"  # <campaign>/lidar/geotiff/
# terra's intermediates (several GB per large mosaic) and unpacked archives.
export PR_GAPS_SCRATCH="${PR_GAPS_SCRATCH:-${TMPDIR:-/tmp}/rugosity_${SLURM_JOB_ID:-$$}_${SLURM_ARRAY_TASK_ID:-0}}"
mkdir -p "$PR_GAPS_SCRATCH"
trap 'rm -rf "$PR_GAPS_SCRATCH"' EXIT

cd "${SLURM_SUBMIT_DIR:-.}"
if [[ ! -f scripts/03_download_covars.R ]]; then
    echo "Submit from the pr-gaps repository root (scripts/03_download_covars.R not found in $PWD)" >&2
    exit 1
fi

module load R        # <- whatever 'module avail R' lists; it needs terra (and sf, curl, jsonlite)

SLICE="${SLURM_ARRAY_TASK_ID:-1}/${SLURM_ARRAY_TASK_COUNT:-1}"
echo "[$(date '+%F %T')] rugosity slice $SLICE on $(hostname), job ${SLURM_JOB_ID:-?}"

# terra::focal() has crashed R intermittently on Windows; retry in case Linux
# does too. Each attempt skips the rasters already finished.
for attempt in 1 2 3 4 5; do
    Rscript scripts/03_download_covars.R --rugosity --slice "$SLICE" && break
    echo "[$(date '+%F %T')] attempt $attempt exited with $?; retrying" >&2
done
echo "[$(date '+%F %T')] finished"
