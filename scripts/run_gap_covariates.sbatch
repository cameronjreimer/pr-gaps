#!/bin/bash -l
# Slurm job for scripts/04_gap_covariates.R. Submit from the repository root
# (pr-gaps/), after canopy.py has finished for the site:
#
#   sbatch scripts/run_gap_covariates.sbatch ev1      # site: lfdp (default), ev1
#
# Needs R with the sf and terra packages (see the module line below), and under
# $PR_GAPS_DATA/interim/covariates/ the ccap, gap_landcover, prism and holdridge
# folders copied from the machine that ran 03_download_covars.R --reproject.
# Light: ~2 GB of memory (each 1 m EV1 raster is read into memory once, ~330 MB).
#SBATCH --job-name=gapcov
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --time=01:00:00
#SBATCH --output=%x-%j.out
##SBATCH --partition=...      # uncomment if the cluster requires one
##SBATCH --account=...

set -euo pipefail

SITE="${1:-lfdp}"
export PR_GAPS_DATA="${PR_GAPS_DATA:-/ibstorage/cam/G-LiHT/data}"          # runs/ and interim/ live here
export PR_GAPS_GLIHT="${PR_GAPS_GLIHT:-/ibstorage/cam/G-LiHT/data/raw/gliht}"  # <campaign>/lidar/geotiff/*.tif

cd "${SLURM_SUBMIT_DIR:-.}"
if [[ ! -f scripts/04_gap_covariates.R ]]; then
    echo "Submit from the pr-gaps repository root (scripts/04_gap_covariates.R not found in $PWD)" >&2
    exit 1
fi

module load R        # <- whatever 'module avail R' lists; it must have sf and terra

echo "[$(date '+%F %T')] gap covariates for $SITE on $(hostname), job ${SLURM_JOB_ID:-?}"
Rscript scripts/04_gap_covariates.R --site "$SITE"
echo "[$(date '+%F %T')] finished"
