#!/bin/bash
# Submit workflow stages as Slurm arrays (docs/hpc-scaling-plan.md §5.1). From the
# repository root (pr-gaps/):
#
#   workflow/submit.sh retile dtm        # named stages
#   workflow/submit.sh all               # every built stage, in order
#   workflow/submit.sh --dry-run retile  # write the task lists, submit nothing
#   workflow/submit.sh --retry-failed step1   # also resubmit tasks that failed twice
#
# For each stage, python/status.py lists the tasks that are not done, running or (by
# default) failed twice; only those are submitted. A stage waits (afterok) for the
# stages it depends on when they are submitted in the same call, so a failure stops
# the chain: fix it and run the same command again. Check progress with
#
#   .venv/bin/python python/status.py

set -euo pipefail
cd "$(dirname "$0")/.."
source workflow/config.sh
PR_GAPS_NO_MODULES=1 source workflow/env.sh   # only for code_version here

DRY=""
RETRY=""
REQUESTED=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --retry-failed) RETRY="--retry-failed" ;;
        all) REQUESTED+=("${STAGES[@]}") ;;
        *) REQUESTED+=("$arg") ;;
    esac
done
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
    sed -n '2,15p' "$0"
    exit 1
fi
code_version > /dev/null   # fail now, not in every task

declare -A SUBMITTED=()
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$PR_GAPS_WORKFLOW/tasks"
for stage in "${STAGES[@]}"; do
    [[ " ${REQUESTED[*]} " == *" $stage "* ]] || continue
    LIST="$PR_GAPS_WORKFLOW/tasks/$stage.$STAMP.txt"
    if ! "$PYTHON" python/status.py --pending "$stage" --out "$LIST" $RETRY > "$LIST.log" 2>&1; then
        echo "$stage: not submitted: $(tail -n 1 "$LIST.log")"
        continue
    fi
    N="$(wc -l < "$LIST" | tr -d ' ')"
    if [[ "$N" -eq 0 ]]; then
        echo "$stage: nothing to do"
        continue
    fi
    DEPENDS=()
    for before in ${AFTER[$stage]}; do
        [[ -n "${SUBMITTED[$before]:-}" ]] && DEPENDS+=("${SUBMITTED[$before]}")
    done
    # Until a task redirects its own output (stage.sbatch), Slurm's goes here.
    mkdir -p "$PR_GAPS_WORKFLOW/logs/$stage"
    ARGS=(--parsable -J "$stage" --array="1-$N%${LIMIT[$stage]}"
          --cpus-per-task="${CPUS[$stage]}" --mem="${MEM[$stage]}" --time="${TIME[$stage]}"
          --output="$PR_GAPS_WORKFLOW/logs/$stage/slurm-%A_%a.out")
    [[ -n "$PARTITION" ]] && ARGS+=(--partition="$PARTITION")
    if [[ ${#DEPENDS[@]} -gt 0 ]]; then
        ARGS+=(--dependency="afterok:$(IFS=:; echo "${DEPENDS[*]}")")
    fi
    if [[ -n "$DRY" ]]; then
        echo "$stage: $N task(s) in $LIST (dry run: sbatch ${ARGS[*]} workflow/stage.sbatch $stage $LIST)"
        continue
    fi
    JOB="$(sbatch "${ARGS[@]}" workflow/stage.sbatch "$stage" "$LIST")"
    SUBMITTED[$stage]="$JOB"
    AFTER_NOTE=""
    [[ ${#DEPENDS[@]} -gt 0 ]] && AFTER_NOTE=" (after job ${DEPENDS[*]})"
    echo "$stage: $N task(s) submitted as job $JOB$AFTER_NOTE"
done
