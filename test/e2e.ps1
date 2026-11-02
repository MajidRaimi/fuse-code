Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoDir = Split-Path -Parent $PSScriptRoot
$MockKey = 'test-fuse-key'
$WrongKey = 'wrong-key'
$CommandTimeoutSeconds = 900
$SessionTimeoutSeconds = 240
$MockReadySeconds = 30
$DefaultMain = 'moonshotai/Kimi-K3[1m]'
$DefaultSonnet = 'zai-org/GLM-5.3-Flash[1m]'
$DefaultSmall = 'Qwen/Qwen3.8-Flash-Next'
$PinnedMain = 'deepseek-ai/DeepSeek-V4.1-Flash'
$RejectedModel = 'tarjama/llmx-1.0'
$ExpectedOptionModels = 'moonshotai/Kimi-K3[1m],zai-org/GLM-5.3-Flash[1m],deepseek-ai/DeepSeek-V4.1-Flash,Qwen/Qwen3.8-Flash-Next,acme/new-chat-9'
$PayloadItems = @('install.ps1', 'install.cmd', 'models.tsv', 'slots.tsv', 'bin', 'lib', 'themes')
$WindowsPowerShell = [IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')

$script:Passes = 0
$script:Failures = 0

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw [System.Exception]::new($Message) }
}

function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Check)
    try {
        & $Check
        $script:Passes++
        Write-Host "ok - $Name"
    }
    catch {
        $script:Failures++
        Write-Host "not ok - $Name"
        foreach ($line in ($_.Exception.Message -split "`r?`n")) { Write-Host "    | $line" }
    }
}

function ConvertTo-ArgumentText {
    param([AllowEmptyCollection()][string[]]$Arguments)
    @($Arguments | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
}

function Start-Captured {
    param([Parameter(Mandatory)][string]$FilePath, [AllowEmptyCollection()][string[]]$Arguments = @(), [hashtable]$Environment = @{}, [string]$WorkingDirectory = $RepoDir)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ConvertTo-ArgumentText -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $WorkingDirectory
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -eq $entry.Value) { $startInfo.EnvironmentVariables.Remove($entry.Key) }
        else { $startInfo.EnvironmentVariables[$entry.Key] = [string]$entry.Value }
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Close()
    [pscustomobject]@{ Process = $process; Output = $process.StandardOutput.ReadToEndAsync(); Errors = $process.StandardError.ReadToEndAsync() }
}

function Stop-Tree {
    param([Parameter(Mandatory)][int]$ProcessId)
    & taskkill.exe /PID $ProcessId /T /F | Out-Null
}

function Complete-Captured {
    param([Parameter(Mandatory)]$Started, [int]$TimeoutSeconds = $CommandTimeoutSeconds)
    $exited = $Started.Process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) { Stop-Tree -ProcessId $Started.Process.Id }
    $Started.Process.WaitForExit()
    $output = $Started.Output.Result
    $errors = $Started.Errors.Result
    [pscustomobject]@{
        ExitCode = if ($exited) { $Started.Process.ExitCode } else { -1 }
        Output   = $output
        Text     = "$output`n$errors"
    }
}

function Invoke-Captured {
    param([Parameter(Mandatory)][string]$FilePath, [AllowEmptyCollection()][string[]]$Arguments = @(), [hashtable]$Environment = @{}, [string]$WorkingDirectory = $RepoDir, [int]$TimeoutSeconds = $CommandTimeoutSeconds)
    Complete-Captured -Started (Start-Captured -FilePath $FilePath -Arguments $Arguments -Environment $Environment -WorkingDirectory $WorkingDirectory) -TimeoutSeconds $TimeoutSeconds
}

function Format-Transcript {
    param([Parameter(Mandatory)]$Result)
    $lines = @($Result.Text -split "`r?`n" | Where-Object { $_ })
    "exit code $($Result.ExitCode)`n" + (($lines | Select-Object -Last 40) -join "`n")
}

function Assert-Succeeded {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$What)
    Assert-True ($Result.ExitCode -eq 0) "$What failed, $(Format-Transcript $Result)"
}

function Assert-Contains {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Expected)
    Assert-True ($Result.Text.Contains($Expected)) "output does not contain '$Expected', $(Format-Transcript $Result)"
}

function Wait-Until {
    param([Parameter(Mandatory)][scriptblock]$Condition, [Parameter(Mandatory)][int]$TimeoutSeconds, [Parameter(Mandatory)][string]$Message)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (& $Condition)) {
        Assert-True ([DateTime]::UtcNow -lt $deadline) $Message
        Start-Sleep -Milliseconds 250
    }
}

function Get-FreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}

function Read-EnvValue {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
        if ($line.StartsWith("$Name=", [StringComparison]::Ordinal)) { return $line.Substring($Name.Length + 1) }
    }
    $null
}

function Assert-EnvValue {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Expected)
    $actual = Read-EnvValue -Name $Name
    Assert-True ($actual -ceq $Expected) "$Name is '$actual', expected '$Expected'"
}

function Read-FuseSettings {
    [IO.File]::ReadAllText($FuseSettings) | ConvertFrom-Json
}

function Test-StartsWithBom {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
}

function Write-UserSettings {
    param([Parameter(Mandatory)][string]$Json)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($UserSettings))
    [IO.File]::WriteAllText($UserSettings, $Json)
}

function Read-UserSettingsText {
    if (-not (Test-Path -LiteralPath $UserSettings)) { return '' }
    [IO.File]::ReadAllText($UserSettings)
}

function Invoke-Fuse {
    param([AllowEmptyCollection()][string[]]$Arguments, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = $CommandTimeoutSeconds)
    Invoke-Captured -FilePath $FuseCommand -Arguments $Arguments -Environment $Environment -WorkingDirectory $ProjectDir -TimeoutSeconds $TimeoutSeconds
}

function Invoke-Installer {
    param([hashtable]$Environment = @{})
    Invoke-Captured -FilePath ([IO.Path]::Combine($RepoDir, 'install.cmd')) -Environment $Environment
}

function Get-ProcessTree {
    param([Parameter(Mandatory)][int]$RootId)
    $all = @(Get-CimInstance -ClassName Win32_Process)
    $pending = New-Object System.Collections.Generic.Queue[int]
    $pending.Enqueue($RootId)
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($process in @($all | Where-Object { $_.ParentProcessId -eq $parentId })) {
            $process
            $pending.Enqueue([int]$process.ProcessId)
        }
    }
}

function Find-ProcessByCommandLine {
    param([AllowEmptyCollection()][object[]]$Processes, [Parameter(Mandatory)][string]$Pattern)
    @($Processes | Where-Object { $_.CommandLine -and $_.CommandLine -match $Pattern }) | Select-Object -First 1
}

function Read-UserPathValue {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try { [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Close() }
}

function Save-UserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        $value = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = if ($null -ne $value) { $key.GetValueKind('Path') } else { $null }
        [pscustomobject]@{ Value = $value; Kind = $kind }
    }
    finally { $key.Close() }
}

function Restore-UserPath {
    param([Parameter(Mandatory)]$Saved)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        if ($null -eq $Saved.Value) { $key.DeleteValue('Path', $false) }
        else { $key.SetValue('Path', $Saved.Value, $Saved.Kind) }
    }
    finally { $key.Close() }
}

function New-PayloadArchive {
    param([Parameter(Mandatory)][string]$Destination)
    $root = [IO.Path]::Combine($WorkDir, 'archive', 'fuse-code-main')
    [void][IO.Directory]::CreateDirectory($root)
    foreach ($item in $PayloadItems) { Copy-Item -LiteralPath ([IO.Path]::Combine($RepoDir, $item)) -Destination $root -Recurse }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($root, $Destination, [IO.Compression.CompressionLevel]::Optimal, $true)
}

function New-FakeClaude {
    $fakeBin = [IO.Path]::Combine($WorkDir, 'fake bin')
    [void][IO.Directory]::CreateDirectory($fakeBin)
    [IO.File]::WriteAllText([IO.Path]::Combine($fakeBin, 'claude.cmd'), "@`"$WindowsPowerShell`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-claude.ps1`" %*`r`n")
    $script = @(
        '$settings = [IO.Path]::Combine($env:USERPROFILE, ''.claude'', ''settings.json'')'
        "[IO.File]::WriteAllText(`$settings, '{`"theme`":`"dark`",`"model`":`"$DefaultMain`"}')"
        'Start-Sleep -Seconds 300'
    ) -join "`r`n"
    [IO.File]::WriteAllText([IO.Path]::Combine($fakeBin, 'fake-claude.ps1'), $script)
    $fakeBin
}

function Start-MockFuse {
    $bun = (Get-Command -Name bun -CommandType Application | Select-Object -First 1).Path
    $env:MOCK_FUSE_PORT = [string]$MockPort
    $env:MOCK_FUSE_KEY = $MockKey
    $env:MOCK_FUSE_LOG = '1'
    $env:MOCK_FUSE_ARCHIVE = $ArchivePath
    $mock = Start-Process -FilePath $bun -ArgumentList ('"' + [IO.Path]::Combine($RepoDir, 'test', 'mock-fuse.ts') + '"') -PassThru -NoNewWindow -RedirectStandardOutput ([IO.Path]::Combine($WorkDir, 'mock.out')) -RedirectStandardError ([IO.Path]::Combine($WorkDir, 'mock.log'))
    $deadline = [DateTime]::UtcNow.AddSeconds($MockReadySeconds)
    while ([DateTime]::UtcNow -lt $deadline -and -not $mock.HasExited) {
        try {
            [void](Invoke-WebRequest -Uri "$MockUrl/v1/models" -Headers @{ Authorization = "Bearer $MockKey" } -UseBasicParsing -TimeoutSec 2)
            return $mock
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }
    throw [System.Exception]::new('the mock FUSE server did not start')
}

foreach ($name in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(FUSE_|ANTHROPIC_|CLAUDE)' } | ForEach-Object { $_.Name })) {
    Remove-Item -LiteralPath "Env:$name"
}
$WorkDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "fuse e2e $([Guid]::NewGuid().ToString('N').Substring(0, 8))")
$TestHome = [IO.Path]::Combine($WorkDir, 'home')
$ProjectDir = [IO.Path]::Combine($WorkDir, 'project')
[void][IO.Directory]::CreateDirectory($TestHome)
[void][IO.Directory]::CreateDirectory($ProjectDir)
$env:USERPROFILE = $TestHome
$env:HOME = $TestHome
$env:NO_PROXY = '127.0.0.1,localhost'

$BinDir = [IO.Path]::Combine($TestHome, '.local', 'bin')
$FuseCommand = [IO.Path]::Combine($BinDir, 'fuse.cmd')
$EnvFile = [IO.Path]::Combine($TestHome, '.config', 'fuse', 'env')
$FuseSettings = [IO.Path]::Combine($TestHome, '.claude', 'fuse', 'settings.json')
$UserSettings = [IO.Path]::Combine($TestHome, '.claude', 'settings.json')
$ArchivePath = [IO.Path]::Combine($WorkDir, 'fuse-code.zip')
$MockPort = Get-FreePort
$MockUrl = "http://127.0.0.1:$MockPort"
$SavedUserPath = Save-UserPath
$Mock = $null

try {
    New-PayloadArchive -Destination $ArchivePath
    $Mock = Start-MockFuse
    Write-Host "e2e: mock FUSE at $MockUrl, home at $TestHome, $(& claude --version)"

    Test-Case "install.cmd succeeds and skips $RejectedModel" {
        $install = Invoke-Installer -Environment @{ FUSE_API_KEY = $MockKey; FUSE_BASE_URL = $MockUrl }
        Assert-Succeeded $install 'install.cmd'
        Assert-Contains $install "Skipping $RejectedModel"
    }

    Test-Case 'env file holds the key and only the current user can read it' {
        Assert-True (Test-Path -LiteralPath $EnvFile) "$EnvFile does not exist"
        Assert-EnvValue -Name 'FUSE_API_KEY' -Expected $MockKey
        $acl = Get-Acl -LiteralPath $EnvFile
        $rules = @($acl.Access)
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
        Assert-True $acl.AreAccessRulesProtected 'the env file still inherits permissions'
        Assert-True ($rules.Count -eq 1) "the env file has $($rules.Count) access rules"
        Assert-True ($rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $currentUser) "the env file rule belongs to $($rules[0].IdentityReference)"
    }

    Test-Case 'fuse settings and env file hold the verified models' {
        $settings = Read-FuseSettings
        Assert-True ($settings.theme -ceq 'custom:fuse') "theme is $($settings.theme)"
        Assert-True ($settings.disableClaudeAiConnectors -eq $true) 'disableClaudeAiConnectors is not true'
        $models = @($settings.modelPicker.options | ForEach-Object { $_.model }) -join ','
        Assert-True ($models -ceq $ExpectedOptionModels) "option models are $models"
        Assert-True (-not (Test-StartsWithBom $FuseSettings)) 'fuse settings start with a byte order mark'
        Assert-True (-not (Test-StartsWithBom $EnvFile)) 'the env file starts with a byte order mark'
        Assert-EnvValue -Name 'FUSE_DEFAULT_MODEL' -Expected $DefaultMain
        Assert-EnvValue -Name 'FUSE_SONNET_MODEL' -Expected $DefaultSonnet
        Assert-EnvValue -Name 'FUSE_SMALL_MODEL' -Expected $DefaultSmall
    }

    Test-Case 'dark and light themes are installed' {
        foreach ($theme in 'fuse.json', 'fuse-light.json') {
            $path = [IO.Path]::Combine($TestHome, '.claude', 'themes', $theme)
            Assert-True (Test-Path -LiteralPath $path) "$path does not exist"
        }
    }

    Test-Case 'fuse.cmd is installed and the bin folder is on the user PATH' {
        Assert-True (Test-Path -LiteralPath $FuseCommand) "$FuseCommand does not exist"
        Assert-True ([IO.File]::ReadAllText($FuseCommand).Contains('fuse-code')) 'fuse.cmd is not the fuse-code launcher'
        $userPath = Read-UserPathValue
        Assert-True (@($userPath.Split(';') | Where-Object { $_.TrimEnd('\') -ieq $BinDir }).Count -eq 1) "user PATH is $userPath"
    }

    Test-Case 'fuse -p answers ok through the mock' {
        $session = Invoke-Fuse -Arguments @('-p', 'Reply with the single word ok') -TimeoutSeconds $SessionTimeoutSeconds
        Assert-Succeeded $session 'fuse -p'
        Assert-True (@($session.Output -split "`r?`n") -ccontains 'ok') "fuse -p did not print ok, $(Format-Transcript $session)"
    }

    Test-Case 'guard removes fuse model and theme left in user settings' {
        Write-UserSettings "{`"model`":`"$DefaultMain`",`"theme`":`"custom:fuse`",`"permissions`":{`"allow`":[`"Bash(ls)`"]}}"
        Assert-Succeeded (Invoke-Fuse -Arguments @('--version')) 'fuse --version'
        $settings = Read-UserSettingsText | ConvertFrom-Json
        Assert-True ($null -eq $settings.PSObject.Properties['model'] -and $null -eq $settings.PSObject.Properties['theme']) "user settings are $(Read-UserSettingsText)"
        Assert-True (@($settings.permissions.allow) -join ',' -ceq 'Bash(ls)') "permissions changed: $(Read-UserSettingsText)"
        Assert-True (-not (Test-StartsWithBom $UserSettings)) 'user settings were written with a byte order mark'
    }

    Test-Case "guard keeps the user's own model and theme" {
        $original = '{"model":"opus","theme":"dark"}'
        Write-UserSettings $original
        Assert-Succeeded (Invoke-Fuse -Arguments @('--version')) 'fuse --version'
        Assert-True ((Read-UserSettingsText) -ceq $original) "user settings changed to $(Read-UserSettingsText)"
    }

    Test-Case 'settings watcher restores user settings after the launcher is killed' {
        Write-UserSettings '{"theme":"dark"}'
        $fakeBin = New-FakeClaude
        $isolatedPath = @($fakeBin, [IO.Path]::Combine($env:SystemRoot, 'System32'), $env:SystemRoot, [IO.Path]::Combine($env:SystemRoot, 'System32', 'Wbem'), [IO.Path]::GetDirectoryName($WindowsPowerShell)) -join ';'
        $session = Start-Captured -FilePath $FuseCommand -Environment @{ PATH = $isolatedPath } -WorkingDirectory $ProjectDir
        try {
            Wait-Until -TimeoutSeconds 90 -Message "the fake claude never picked a fuse model, user settings are $(Read-UserSettingsText)" -Condition { (Read-UserSettingsText).Contains('Kimi') }
            $tree = @(Get-ProcessTree -RootId $session.Process.Id)
            $watcher = Find-ProcessByCommandLine -Processes $tree -Pattern 'fuse-guard\.ps1'
            $launcher = Find-ProcessByCommandLine -Processes $tree -Pattern '\\bin\\fuse\.ps1'
            Assert-True ($null -ne $watcher) 'no settings watcher was running during the session'
            Assert-True ($null -ne $launcher) 'the launcher process was not found'
            Stop-Process -Id $launcher.ProcessId -Force
            foreach ($process in $tree) {
                if ($process.ProcessId -ne $watcher.ProcessId) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
            }
            Wait-Until -TimeoutSeconds 30 -Message "the watcher did not restore user settings: $(Read-UserSettingsText)" -Condition { -not (Read-UserSettingsText).Contains('Kimi') }
            $settings = Read-UserSettingsText | ConvertFrom-Json
            Assert-True ($settings.theme -ceq 'dark' -and $null -eq $settings.PSObject.Properties['model']) "user settings are $(Read-UserSettingsText)"
            Wait-Until -TimeoutSeconds 30 -Message 'the watcher did not exit after restoring' -Condition { -not (Get-Process -Id $watcher.ProcessId -ErrorAction SilentlyContinue) }
        }
        finally {
            if (-not $session.Process.HasExited) { Stop-Tree -ProcessId $session.Process.Id }
        }
    }

    Test-Case 'FUSE_THEME=light refresh switches to the light theme' {
        Assert-Succeeded (Invoke-Fuse -Arguments @('--refresh-models') -Environment @{ FUSE_THEME = 'light' }) 'fuse --refresh-models'
        Assert-True ((Read-FuseSettings).theme -ceq 'custom:fuse-light') "theme is $((Read-FuseSettings).theme)"
        Assert-EnvValue -Name 'FUSE_THEME' -Expected 'light'
    }

    Test-Case 'refresh with a wrong key is rejected through fuse.cmd and keeps the saved key' {
        $refresh = Invoke-Fuse -Arguments @('--refresh-models') -Environment @{ FUSE_API_KEY = $WrongKey }
        Assert-True ($refresh.ExitCode -ne 0) "fuse --refresh-models succeeded with a wrong key, $(Format-Transcript $refresh)"
        Assert-Contains $refresh 'rejected'
        Assert-EnvValue -Name 'FUSE_API_KEY' -Expected $MockKey
    }

    Test-Case 'FUSE_DEFAULT_MODEL pins the main model on refresh' {
        Assert-Succeeded (Invoke-Fuse -Arguments @('--refresh-models') -Environment @{ FUSE_DEFAULT_MODEL = $PinnedMain }) 'fuse --refresh-models'
        Assert-EnvValue -Name 'FUSE_DEFAULT_MODEL' -Expected $PinnedMain
    }

    Test-Case 'fuse --reset-models restores the default main model' {
        Assert-Succeeded (Invoke-Fuse -Arguments @('--reset-models')) 'fuse --reset-models'
        Assert-EnvValue -Name 'FUSE_DEFAULT_MODEL' -Expected $DefaultMain
    }

    Test-Case 'install.cmd again without FUSE_API_KEY reuses the saved key' {
        Assert-Succeeded (Invoke-Installer) 'install.cmd'
        Assert-EnvValue -Name 'FUSE_API_KEY' -Expected $MockKey
    }

    Test-Case 'the irm | iex one-liner installs from the archive under a Restricted policy' {
        $command = "iex ([IO.File]::ReadAllText('$([IO.Path]::Combine($RepoDir, 'install.ps1'))')); exit `$LASTEXITCODE"
        $oneLiner = Invoke-Captured -FilePath $WindowsPowerShell -Arguments @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Restricted', '-Command', $command) -Environment @{ FUSE_CODE_ARCHIVE_URL = "$MockUrl/fuse-code.zip" } -WorkingDirectory $ProjectDir
        Assert-Succeeded $oneLiner 'the one-liner'
        Assert-Contains $oneLiner 'Downloading the latest fuse-code'
        Assert-Contains $oneLiner 'Done.'
    }

    Test-Case 'uninstall without a terminal is cancelled and keeps the install' {
        $uninstall = Invoke-Fuse -Arguments @('--uninstall')
        Assert-True ($uninstall.ExitCode -ne 0) "uninstall did not refuse, $(Format-Transcript $uninstall)"
        Assert-Contains $uninstall 'Cancelled.'
        Assert-True (Test-Path -LiteralPath $EnvFile) 'the env file was removed'
    }
}
finally {
    if ($Mock -and -not $Mock.HasExited) { Stop-Tree -ProcessId $Mock.Id }
    Restore-UserPath -Saved $SavedUserPath
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "e2e: $script:Passes passed, $script:Failures failed"
if ($script:Failures -gt 0) { exit 1 }
