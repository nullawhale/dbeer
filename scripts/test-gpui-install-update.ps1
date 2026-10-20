param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
& py -3 (Join-Path $repoRoot 'prototypes/gpui/acceptance/run.py') @Arguments
exit $LASTEXITCODE
