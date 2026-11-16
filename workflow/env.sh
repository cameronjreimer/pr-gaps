# Environment for every workflow task (docs/hpc-scaling-plan.md §5.2). Sourced from the
# repository root after config.sh.

# The Linux CloudComPy wheel needs GCC >= 13.2's C++ runtime; the system's is older.
# PR_GAPS_NO_MODULES=1 skips this where there is no module system (local tests).
if [[ -z "${PR_GAPS_NO_MODULES:-}" ]]; then
    module load gcc/15.2.0
    export LD_LIBRARY_PATH="$(dirname "$(gcc -print-file-name=libstdc++.so.6)"):${LD_LIBRARY_PATH:-}"
fi
export QT_QPA_PLATFORM=offscreen     # no display in a batch job

# Code version: refuse uncommitted code, so every output can name the commit that made it.
code_version() {
    local dirty
    dirty="$(git status --porcelain -- python scripts workflow R)"
    if [[ -n "$dirty" ]]; then
        echo "Uncommitted changes in the code; commit them first (or set PR_GAPS_ALLOW_DIRTY=1 to test):" >&2
        echo "$dirty" >&2
        [[ -n "${PR_GAPS_ALLOW_DIRTY:-}" ]] || return 1
    fi
    git rev-parse HEAD
}
