# Environment for every workflow task (docs/hpc-scaling-plan.md §5.2). Sourced from the
# repository root after config.sh.

# The Linux CloudComPy wheel needs GCC >= 13.2's C++ runtime; the system's is older.
# PR_GAPS_NO_MODULES=1 skips this where there is no module system (local tests).
if [[ -z "${PR_GAPS_NO_MODULES:-}" ]]; then
    module load gcc/15.2.0
    if (( $(gcc -dumpversion | cut -d. -f1) < 13 )); then
        echo "gcc/15.2.0 did not load (gcc is $(gcc -dumpversion)); CloudComPy needs GCC >= 13.2's runtime" >&2
        exit 1
    fi
    # GCC 15's runtime first, and no system library folder ahead of CloudComPy's own
    # libraries. An inherited /usr/lib64 (e.g. gcc 11's .../11/../../../../lib64, from a
    # shell that set LD_LIBRARY_PATH before loading gcc/15.2.0) makes its GDAL load the
    # system libjson-c: "version `JSONC_PRIVATE' not found".
    keep=()
    IFS=: read -ra inherited <<< "${LD_LIBRARY_PATH:-}"
    for folder in "${inherited[@]}"; do
        [[ -z "$folder" ]] && continue
        case "$(realpath -m "$folder" 2>/dev/null || echo "$folder")" in
            /usr/lib64|/lib64|/usr/lib|/lib) continue ;;
        esac
        keep+=("$folder")
    done
    LD_LIBRARY_PATH="$(dirname "$(gcc -print-file-name=libstdc++.so.6)")"
    if (( ${#keep[@]} )); then
        LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$(IFS=:; echo "${keep[*]}")"
    fi
    export LD_LIBRARY_PATH
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
