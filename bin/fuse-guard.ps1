Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine((Split-Path -Parent $PSScriptRoot), 'lib', 'FuseCode.psm1'))

if (-not $env:FUSE_GUARD_HANDOFF) { exit 0 }
$handoff = ConvertFrom-GuardHandoff -Json $env:FUSE_GUARD_HANDOFF
$launcher = Get-Process -Id $handoff.LauncherId -ErrorAction SilentlyContinue
if ($launcher) { $launcher.WaitForExit() }
Restore-UserSettings -Guard $handoff.Guard -Previous $handoff.Previous
