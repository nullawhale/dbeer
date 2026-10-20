[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Gui,
    [Parameter(Mandatory=$true)][string]$Helper,
    [Parameter(Mandatory=$true)][string]$Identity,
    [Parameter(Mandatory=$true)][string]$Notices,
    [string]$Output
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows) -or
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'Package the DBeer Windows x64 client natively on Windows. macOS uses build-app.sh.'
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$arguments = @('-3', '-B', (Join-Path $repoRoot 'prototypes/gpui/packaging/package.py'), 'package',
    '--target', 'windows-x86_64-msvc', '--gui', $Gui, '--helper', $Helper,
    '--identity', $Identity, '--notices', $Notices)
if ($Output) { $arguments += @('--output', $Output) }
& py @arguments
if ($LASTEXITCODE -ne 0) { throw 'DBeer packaging failed; no existing package is overwritten.' }
