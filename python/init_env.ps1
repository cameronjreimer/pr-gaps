<#
.SYNOPSIS
    Set up the Python environment for canopy.py on Windows: a venv with CloudComPy
    and the geospatial packages in requirements.txt.

.DESCRIPTION
    Safe to re-run. If the environment already passes python\check_env.py, nothing
    changes. Otherwise the script:
      1. finds a CloudComPy wheel (-Wheel, $env:CLOUDCOMPY_WHEEL, python\wheels\, or
         your Downloads folder). CloudComPy is not on PyPI, and its download page asks
         you to accept the GPL, so this step is yours: if no wheel is found, the page
         opens and the script stops;
      2. gets the Python version the wheel was built for, using uv if present
         (offering to install it if neither uv nor that Python is available), or
         the py launcher otherwise;
      3. creates the venv (default pr-gaps\.venv, override with $env:PR_GAPS_VENV),
         installs the wheel and requirements.txt, and runs check_env.py.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File python\init_env.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File python\init_env.ps1 -Wheel C:\path\to\cloudcompy-2.13.90-cp312-cp312-win_amd64.whl -Force
#>
param(
    [string]$Wheel = $env:CLOUDCOMPY_WHEEL,
    [string]$Venv = $env:PR_GAPS_VENV,
    # Rebuild the venv even if it already passes the check.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$WheelPage = 'https://www.simulation.openfields.fr/index.php/cloudcompy-downloads/3-cloudcompy-binaries/13-experimental-pypi-wheels-install-with-pip/15-windows-wheel-files'
$Here = $PSScriptRoot
$Repo = Split-Path $Here -Parent
if (-not $Venv) { $Venv = Join-Path $Repo '.venv' }
$Py = Join-Path $Venv 'Scripts\python.exe'
$Check = Join-Path $Here 'check_env.py'
$Requirements = Join-Path $Here 'requirements.txt'

function Invoke-Native {
    # Run a native command and stop on a nonzero exit, which $ErrorActionPreference ignores.
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

# ---------------------------------------------------------------- already set up?
if ((Test-Path $Py) -and -not $Force) {
    Write-Host "Checking existing environment: $Venv"
    & $Py $Check
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nEnvironment already set up. Run: $Py python\canopy.py"
        exit 0
    }
    Write-Host "`nExisting environment failed the check; rebuilding it."
}

# ---------------------------------------------------------------- 1. CloudComPy wheel
if (-not $Wheel) {
    $folders = @((Join-Path $Here 'wheels'), (Join-Path $env:USERPROFILE 'Downloads')) | Where-Object { Test-Path $_ }
    $found = @($folders | ForEach-Object { Get-ChildItem $_ -Filter 'cloudcompy-*-win_amd64.whl' } |
        Sort-Object LastWriteTime -Descending)
    if ($found.Count) { $Wheel = $found[0].FullName }
}
if (-not $Wheel -or -not (Test-Path $Wheel)) {
    Write-Host @"
No CloudComPy wheel found. CloudComPy is not on PyPI; download it yourself:

  1. On the page now opening, pick cloudcompy-<version>-cp312-cp312-win_amd64.whl
     (any of cp310-cp314 works; 3.12 matches the production builds), accept the
     GPL and download it (~160 MB).
  2. Leave it in Downloads or move it to python\wheels\, then re-run this script.

  $WheelPage
"@
    Start-Process $WheelPage
    exit 1
}
$WheelName = Split-Path $Wheel -Leaf
if ($WheelName -notmatch '-cp3(\d+)-cp3\d+-win_amd64\.whl$') {
    throw "Not a Windows CloudComPy wheel: $Wheel"
}
$PyVersion = "3.$($Matches[1])"
Write-Host "Using $WheelName (Python $PyVersion)"

# ---------------------------------------------------------------- 2. Python
$uv = Get-Command uv -ErrorAction SilentlyContinue
$launcher = $null
if (-not $uv -and (Get-Command py -ErrorAction SilentlyContinue)) {
    & py "-$PyVersion" -c 'import sys' 2>$null
    if ($LASTEXITCODE -eq 0) { $launcher = 'py' }
}
if (-not $uv -and -not $launcher) {
    $answer = Read-Host "Python $PyVersion not found. Install uv (https://docs.astral.sh/uv) into your user profile; it will fetch Python $PyVersion? [y/N]"
    if ($answer -notmatch '^[yY]') {
        Write-Host "Install Python $PyVersion (python.org or 'winget install astral-sh.uv'), then re-run."
        exit 1
    }
    powershell -NoProfile -ExecutionPolicy Bypass -Command 'irm https://astral.sh/uv/install.ps1 | iex'
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) { throw 'uv installed but not found on PATH; open a new terminal and re-run.' }
}

# ---------------------------------------------------------------- 3. venv + packages
if (Test-Path $Venv) {
    if (-not (Test-Path (Join-Path $Venv 'pyvenv.cfg'))) {
        throw "$Venv exists but is not a Python venv; refusing to replace it."
    }
    Write-Host "Removing old environment: $Venv"
    Remove-Item -Recurse -Force $Venv
}
if ($uv) {
    Invoke-Native 'uv' @('venv', '--python', $PyVersion, $Venv)
    Invoke-Native 'uv' @('pip', 'install', '--python', $Py, $Wheel, '-r', $Requirements)
} else {
    Invoke-Native 'py' @("-$PyVersion", '-m', 'venv', $Venv)
    Invoke-Native $Py @('-m', 'pip', 'install', '--upgrade', 'pip')
    Invoke-Native $Py @('-m', 'pip', 'install', $Wheel, '-r', $Requirements)
}

Write-Host "`nChecking the new environment"
& $Py $Check
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nThe environment was built but failed the check above."
    exit 1
}
Write-Host "`nReady. Run from the repository root:`n  $Py python\canopy.py"
