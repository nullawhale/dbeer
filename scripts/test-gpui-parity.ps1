$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot 'prototypes/gpui/verification/run.py'
# Keep Python's --flags as arguments instead of PowerShell named parameters.
& python $runner @args
if ($LASTEXITCODE -ne 0) { throw 'GPUI verification did not complete successfully.' }
