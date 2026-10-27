[CmdletBinding()]
param(
    [switch]$Test,
    [switch]$Package
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows) -or
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'Build DBeer natively on Windows x64 with MSVC. macOS uses build-app.sh (SwiftUI).'
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$arguments = @('-3', '-B', (Join-Path $repoRoot 'prototypes/gpui/packaging/build.py'),
    '--target', 'windows-x86_64-msvc')
if ($Test) { $arguments += '--test' }
if ($Package) { $arguments += '--package' }
& py @arguments
if ($LASTEXITCODE -ne 0) {
    throw 'DBeer paired native build failed; existing candidates are preserved.'
}
