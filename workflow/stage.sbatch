#!/bin/bash -l
# One task of a workflow stage (docs/hpc-scaling-plan.md §5.1). Submitted by submit.sh,
# which sets the resources and the array:
#
#   sbatch --array=1-N%M ... workflow/stage.sbatch <stage> <task list>
#
# Array index N runs line N of the task list. The task's output goes to
# $PR_GAPS_WORKFLOW/logs/<stage>/<task>.<jobid>_<index>.out, and a start and an end
# record go to $PR_GAPS_WORKFLOW/attempts/<stage>/<task>.jsonl, which status.py reads.
# Anything printed before that redirect (a broken environment) is in
# $PR_GAPS_WORKFLOW/logs/<stage>/slurm-<jobid>_<index>.out.

set -euo pipefail

STAGE="$1"
LIST="$2"
cd "${SLURM_SUBMIT_DIR:-.}"
source workflow/config.sh
source workflow/env.sh

INDEX="${SLURM_ARRAY_TASK_ID:-1}"
TASK="$(sed -n "${INDEX}p" "$LIST")"
if [[ -z "$TASK" ]]; then
    echo "No line $INDEX in $LIST" >&2
    exit 1
fi
SAFE="${TASK//\//__}"
JOB="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-local}}_${INDEX}"
LOG="$PR_GAPS_WORKFLOW/logs/$STAGE/$SAFE.$JOB.out"
ATTEMPTS="$PR_GAPS_WORKFLOW/attempts/$STAGE/$SAFE.jsonl"
mkdir -p "$(dirname "$LOG")" "$(dirname "$ATTEMPTS")"
exec > "$LOG" 2>&1

COMMIT="$(code_version)"
export PR_GAPS_CODE_VERSION="$COMMIT"   # recorded in the scripts' done markers
record() {  # one JSON line per event; values never contain quotes
    printf '{"event": "%s", "job": "%s", "time": "%s", "commit": "%s", "log": "%s"%s}\n' \
        "$1" "$JOB" "$(date -u +%FT%TZ)" "$COMMIT" "$LOG" "${2:-}" >> "$ATTEMPTS"
}
record start
trap 'status=$?; record end ", \"exit\": $status"' EXIT

echo "[$(date '+%F %T')] $STAGE $TASK on $(hostname), ${SLURM_CPUS_PER_TASK:-?} cpus, job $JOB, commit $COMMIT"
case "$STAGE" in
    retile) "$PYTHON" -u python/retile.py "$TASK" ;;
    dtm)    "$PYTHON" -u python/campaign_dtm.py ;;
    step1)  "$PYTHON" -u python/canopy.py --job "$TASK" ;;
    voxels) "$PYTHON" -u python/island_gaps.py voxels --job "$TASK" ;;
    label)  "$PYTHON" -u python/island_gaps.py label --tile "$TASK" ;;
    join)   "$PYTHON" -u python/island_gaps.py join --threshold "$TASK" ;;
    points) "$PYTHON" -u python/island_gaps.py points --job "$TASK" ;;
    qc)     "$PYTHON" -u python/island_qc.py ;;
    *)      echo "Unknown stage $STAGE" >&2; exit 1 ;;
esac
echo "[$(date '+%F %T')] finished"
