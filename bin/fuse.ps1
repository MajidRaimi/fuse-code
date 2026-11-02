Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PayloadDir = Split-Path -Parent $PSScriptRoot
Import-Module ([IO.Path]::Combine($PayloadDir, 'lib', 'FuseCode.psm1'))

$MaintenanceCommands = [string[]]@('--refresh-models', '--reset-models', '--self-update', '--uninstall')
$ChoiceFreeFlags = [string[]]@('-p', '--print', '-v', '--version', '-h', '--help')
$ClearedVariables = [string[]]@('ANTHROPIC_API_KEY', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'FUSE_API_KEY', 'FUSE_ENV_FILE', 'FUSE_SETTINGS_FILE')

function Stop-Fuse {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("fuse: $Message")
    exit 1
}

function Invoke-Maintenance {
    param([Parameter(Mandatory)][string]$Command)
    $installer = [IO.Path]::Combine($PayloadDir, 'install.ps1')
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { Stop-Fuse 'fuse-code files are missing. Run the fuse-code installer again.' }
    Invoke-NativeCommand -FilePath (Get-WindowsPowerShellPath) -ArgumentList ((Get-PowerShellHostArguments) + @('-File', $installer, $Command))
}

function Read-LauncherConfig {
    param([Parameter(Mandatory)][string]$EnvFile, [Parameter(Mandatory)][string]$FuseSettings)
    if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) { Stop-Fuse "missing $EnvFile. Run the fuse-code installer again." }
    if (-not (Test-Path -LiteralPath $FuseSettings -PathType Leaf)) { Stop-Fuse "missing $FuseSettings. Run fuse --refresh-models." }
    $config = Read-FuseEnv -Path $EnvFile
    foreach ($name in 'FUSE_API_KEY', 'FUSE_BASE_URL') {
        if (-not $config[$name]) { Stop-Fuse "$name is empty in $EnvFile." }
    }
    if (-not $config['FUSE_DEFAULT_MODEL']) { Stop-Fuse 'FUSE_DEFAULT_MODEL is empty. Run fuse --refresh-models.' }
    $config
}

function Clear-InheritedEnvironment {
    foreach ($name in $ClearedVariables) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
}

function Set-SessionEnvironment {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$Slots)
    $session = [ordered]@{
        ANTHROPIC_BASE_URL                       = $Config['FUSE_BASE_URL']
        ANTHROPIC_AUTH_TOKEN                     = $Config['FUSE_API_KEY']
        ANTHROPIC_MODEL                          = $Slots.Main
        ANTHROPIC_DEFAULT_OPUS_MODEL             = $Slots.Main
        ANTHROPIC_DEFAULT_FABLE_MODEL            = $Slots.Main
        ANTHROPIC_DEFAULT_SONNET_MODEL           = $Slots.Sonnet
        ANTHROPIC_DEFAULT_HAIKU_MODEL            = $Slots.Small
        ANTHROPIC_SMALL_FAST_MODEL               = $Slots.Small
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    }
    foreach ($entry in $session.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
}

function Invoke-SettingsCheck {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Path, [AllowNull()][object]$Fallback = $null)
    try {
        & $Action
    }
    catch {
        [Console]::Error.WriteLine("fuse: could not check the model and theme in ${Path}: $($_.Exception.Message)")
        $Fallback
    }
}

function Start-SettingsWatcher {
    param([Parameter(Mandatory)]$Guard, [AllowEmptyCollection()][System.Collections.IDictionary]$Previous)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Get-WindowsPowerShellPath
    $startInfo.Arguments = ConvertTo-CommandLine -ArgumentList ((Get-PowerShellHostArguments -NonInteractive) + @('-File', [IO.Path]::Combine($PSScriptRoot, 'fuse-guard.ps1')))
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['FUSE_GUARD_HANDOFF'] = ConvertTo-GuardHandoff -Guard $Guard -Previous $Previous -LauncherId $PID
    [System.Diagnostics.Process]::Start($startInfo).Dispose()
}

$arguments = [string[]]$args
if ($arguments.Count -gt 0 -and $MaintenanceCommands -ccontains $arguments[0]) { exit (Invoke-Maintenance -Command $arguments[0]) }

$paths = Get-FusePaths
$envFile = Select-FirstValue @($env:FUSE_ENV_FILE, $paths.EnvFile)
$fuseSettings = Select-FirstValue @($env:FUSE_SETTINGS_FILE, $paths.FuseSettings)
$config = Read-LauncherConfig -EnvFile $envFile -FuseSettings $fuseSettings

$claude = Resolve-ClaudePath
if (-not $claude) { Stop-Fuse 'Claude Code is not installed. Install it with: irm https://claude.ai/install.ps1 | iex' }

$slots = [pscustomobject]@{
    Main   = $config['FUSE_DEFAULT_MODEL']
    Sonnet = Select-FirstValue @($config['FUSE_SONNET_MODEL'], $config['FUSE_DEFAULT_MODEL'])
    Small  = Select-FirstValue @($config['FUSE_SMALL_MODEL'], $config['FUSE_DEFAULT_MODEL'])
}
$guard = New-SettingsGuard -UserSettingsPath $paths.UserSettings -FuseSettingsPath $fuseSettings -SlotModels @($slots.Main, $slots.Sonnet, $slots.Small)
Invoke-SettingsCheck -Path $guard.Path -Action { Restore-UserSettings -Guard $guard -Previous @{} }
$before = Invoke-SettingsCheck -Path $guard.Path -Action { Get-UserChoices -Guard $guard } -Fallback ([ordered]@{})

Clear-InheritedEnvironment
$mayChangeChoices = @($arguments | Where-Object { $ChoiceFreeFlags -ccontains $_ }).Count -eq 0
if ($mayChangeChoices) { Invoke-SettingsCheck -Path $guard.Path -Action { Start-SettingsWatcher -Guard $guard -Previous $before } }

Set-SessionEnvironment -Config $config -Slots $slots
$status = 1
try {
    $status = Invoke-NativeCommand -FilePath $claude -ArgumentList $arguments
}
finally {
    Invoke-SettingsCheck -Path $guard.Path -Action { Restore-UserSettings -Guard $guard -Previous $before }
}
exit $status
