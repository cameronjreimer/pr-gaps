#!/usr/bin/env bash
# Set up the Python environment for canopy.py on Linux (x86_64, glibc >= 2.31):
# a venv with CloudComPy and the geospatial packages in requirements.txt.
#
#   bash python/init_env.sh [--force] [path/to/cloudcompy-*-linux_x86_64.whl]
#
# Safe to re-run. If the environment already passes python/check_env.py, nothing
# changes. Otherwise it finds a CloudComPy wheel (argument, $CLOUDCOMPY_WHEEL,
# python/wheels/, or ~/Downloads), creates the venv (default pr-gaps/.venv,
# override with $PR_GAPS_VENV) with the wheel's Python version, using uv if
# present and python3.X otherwise, installs everything, and runs check_env.py.
#
# CloudComPy is not on PyPI, and its download page asks you to accept the GPL,
# so downloading the wheel is left to you; the script stops with the URL if it
# finds none. An existing conda CloudComPy setup (e.g. ~/cloudcompy_env.sh)
# is not touched.
set -euo pipefail

WHEEL_PAGE="https://www.simulation.openfields.fr/index.php/cloudcompy-downloads/3-cloudcompy-binaries/13-experimental-pypi-wheels-install-with-pip/14-linux-wheel-files"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
VENV="${PR_GAPS_VENV:-$REPO/.venv}"
PY="$VENV/bin/python"
WHEEL="${CLOUDCOMPY_WHEEL:-}"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) WHEEL="$arg" ;;
    esac
done

# ---------------------------------------------------------------- already set up?
if [[ -x "$PY" && $FORCE -eq 0 ]]; then
    echo "Checking existing environment: $VENV"
    if "$PY" "$HERE/check_env.py"; then
        printf '\nEnvironment already set up. Run: %s python/canopy.py\n' "$PY"
        exit 0
    fi
    printf '\nExisting environment failed the check; rebuilding it.\n'
fi

# ---------------------------------------------------------------- 1. CloudComPy wheel
if [[ -z "$WHEEL" ]]; then
    WHEEL="$(ls -t "$HERE"/wheels/cloudcompy-*-linux_x86_64.whl \
        "$HOME"/Downloads/cloudcompy-*-linux_x86_64.whl 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$WHEEL" || ! -f "$WHEEL" ]]; then
    cat <<EOF
No CloudComPy wheel found. CloudComPy is not on PyPI; download it yourself:

  1. From the page below, pick cloudcompy-<version>-cp312-cp312-linux_x86_64.whl
     (any of cp310-cp314 works; 3.12 matches the production builds), accept the
     GPL and download it.
  2. Put it in python/wheels/ (or pass its path), then re-run this script.

  $WHEEL_PAGE
EOF
    exit 1
fi
name="$(basename "$WHEEL")"
if [[ ! "$name" =~ -cp3([0-9]+)-cp3[0-9]+-.*linux_x86_64\.whl$ ]]; then
    echo "Not a Linux x86_64 CloudComPy wheel: $WHEEL" >&2
    exit 1
fi
PY_VERSION="3.${BASH_REMATCH[1]}"
echo "Using $name (Python $PY_VERSION)"
glibc="$(ldd --version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
if [[ -n "$glibc" ]] && [[ "$(printf '%s\n2.31\n' "$glibc" | sort -V | head -n 1)" != "2.31" ]]; then
    echo "glibc $glibc is older than the 2.31 the CloudComPy wheels need." >&2
    exit 1
fi

# ---------------------------------------------------------------- 2-3. venv + packages
if [[ -e "$VENV" ]]; then
    if [[ ! -f "$VENV/pyvenv.cfg" ]]; then
        echo "$VENV exists but is not a Python venv; refusing to replace it." >&2
        exit 1
    fi
    echo "Removing old environment: $VENV"
    rm -rf "$VENV"
fi
if command -v uv >/dev/null 2>&1; then
    uv venv --python "$PY_VERSION" "$VENV"
    uv pip install --python "$PY" "$WHEEL" -r "$HERE/requirements.txt"
elif command -v "python$PY_VERSION" >/dev/null 2>&1; then
    "python$PY_VERSION" -m venv "$VENV"
    "$PY" -m pip install --upgrade pip
    "$PY" -m pip install "$WHEEL" -r "$HERE/requirements.txt"
else
    cat >&2 <<EOF
Neither uv nor python$PY_VERSION is available. Install uv, which fetches Python
itself, into your home directory and re-run:

  curl -LsSf https://astral.sh/uv/install.sh | sh
EOF
    exit 1
fi

printf '\nChecking the new environment\n'
if ! "$PY" "$HERE/check_env.py"; then
    printf '\nThe environment was built but failed the check above.\n'
    exit 1
fi
printf '\nReady. Run from the repository root:\n  %s python/canopy.py\n' "$PY"
