& {
    param([string[]]$Arguments)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $ArchiveUrl = if ($env:FUSE_CODE_ARCHIVE_URL) { $env:FUSE_CODE_ARCHIVE_URL } else { 'https://github.com/MajidRaimi/fuse-code/archive/refs/heads/main.zip' }
    $SourceDir = $PSScriptRoot
    $ModulePath = if ($SourceDir) { [IO.Path]::Combine($SourceDir, 'lib', 'FuseCode.psm1') } else { '' }

    function Write-Step {
        param([Parameter(Mandatory)][string]$Message)
        Write-Host '==> ' -ForegroundColor Green -NoNewline
        Write-Host $Message
    }

    function Write-Note {
        param([Parameter(Mandatory)][string]$Message)
        Write-Host "    $Message" -ForegroundColor DarkGray
    }

    function Install-FromArchive {
        param([AllowEmptyCollection()][string[]]$Forwarded)
        $workDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "fuse-code-$([Guid]::NewGuid().ToString('N').Substring(0, 8))")
        [void][IO.Directory]::CreateDirectory($workDir)
        try {
            $archive = [IO.Path]::Combine($workDir, 'fuse-code.zip')
            Write-Step 'Downloading the latest fuse-code'
            Invoke-WebRequest -Uri $ArchiveUrl -OutFile $archive -UseBasicParsing
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($archive, $workDir)
            $payload = Get-ChildItem -LiteralPath $workDir -Directory | Select-Object -First 1
            $installer = [IO.Path]::Combine($payload.FullName, 'install.ps1')
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = [IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
            $startInfo.Arguments = (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$installer`"") + @($Forwarded | ForEach-Object { "`"$_`"" })) -join ' '
            $startInfo.UseShellExecute = $false
            $process = [System.Diagnostics.Process]::Start($startInfo)
            $process.WaitForExit()
            $process.ExitCode
        }
        finally {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $ModulePath -or -not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
        $exitCode = Install-FromArchive -Forwarded $Arguments
        if ($SourceDir) { exit $exitCode }
        $global:LASTEXITCODE = $exitCode
        return
    }

    Import-Module $ModulePath

    $Paths = Get-FusePaths
    $DefaultBaseUrl = 'https://api.fuse.humainaic.com'
    $ModelListTimeoutSeconds = 30
    $ProbeSeconds = 150
    $ProbeParallel = 3
    $ProbePrompt = 'Reply with the single word ok'
    $PayloadFiles = [string[]]@(
        'install.ps1', 'install.cmd', 'models.tsv', 'slots.tsv',
        'bin\fuse.ps1', 'bin\fuse-guard.ps1', 'bin\fuse.cmd', 'lib\FuseCode.psm1', 'lib\FuseLauncher.cs',
        'themes\fuse.json', 'themes\fuse-light.json'
    )
    $Requested = @{
        Key     = $env:FUSE_API_KEY
        BaseUrl = $env:FUSE_BASE_URL
        Theme   = $env:FUSE_THEME
        Main    = $env:FUSE_DEFAULT_MODEL
        Sonnet  = $env:FUSE_SONNET_MODEL
        Small   = $env:FUSE_SMALL_MODEL
        BinDir  = $env:FUSE_BIN_DIR
    }
    $Saved = Read-FuseEnv -Path $Paths.EnvFile
    $BinDir = Select-FirstValue @($Requested.BinDir, $Saved['FUSE_BIN_DIR'], $Paths.DefaultBinDir)
    $Launcher = [IO.Path]::Combine($BinDir, 'fuse.cmd')
    $LauncherExecutable = [IO.Path]::Combine($BinDir, 'fuse.exe')
    $ProbeLauncher = [IO.Path]::Combine($Paths.ShareDir, 'bin', 'fuse.ps1')

    function Stop-Installer {
        param([Parameter(Mandatory)][string]$Message)
        $Host.UI.WriteErrorLine("error: $Message")
        exit 1
    }

    function Get-UsageText {
        @'
Usage: .\install.cmd [option]

  (no option)          Install or repair fuse, reusing a saved key if there is one
  --refresh-models     Re-read the models your key can use and rebuild the /model list
  --reset-models       Same as --refresh-models, but pick the default models again
  --self-update        Download the latest fuse-code and reinstall
  --uninstall          Remove fuse, its settings, themes and saved key

Environment overrides: FUSE_API_KEY, FUSE_BASE_URL, FUSE_THEME (dark or light),
FUSE_DEFAULT_MODEL, FUSE_SONNET_MODEL, FUSE_SMALL_MODEL.
'@
    }

    function Test-Interactive {
        [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    }

    function Confirm-Action {
        param([Parameter(Mandatory)][string]$Question)
        if (-not (Test-Interactive)) { return $false }
        $answer = Read-Host "$Question [Y/n]"
        -not $answer -or $answer -match '^[Yy]'
    }

    function ConvertFrom-SecureText {
        param([Parameter(Mandatory)][Security.SecureString]$Secure)
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }

    function Resolve-ApiKey {
        $key = Select-FirstValue @($Requested.Key, $Saved['FUSE_API_KEY'])
        if (-not $key) {
            if (-not (Test-Interactive)) { Stop-Installer 'No FUSE API key. Run it as: $env:FUSE_API_KEY = "your-key"; .\install.cmd' }
            $key = ConvertFrom-SecureText -Secure (Read-Host -Prompt 'Paste your FUSE API key (input is hidden)' -AsSecureString)
        }
        $key = $key -replace '\s', ''
        if (-not $key) { Stop-Installer 'The FUSE API key is empty.' }
        $key
    }

    function Invoke-WindowsPowerShell {
        param([Parameter(Mandatory)][string[]]$ArgumentList, [switch]$Quiet)
        Invoke-NativeCommand -FilePath (Get-WindowsPowerShellPath) -ArgumentList ((Get-PowerShellHostArguments) + $ArgumentList) -Quiet:$Quiet
    }

    function Initialize-ClaudeCode {
        if (Resolve-ClaudePath) { return }
        if (-not (Confirm-Action 'Claude Code is not installed. Install it now with the official installer?')) {
            Stop-Installer 'Install Claude Code first (irm https://claude.ai/install.ps1 | iex) and run this again.'
        }
        $exitCode = Invoke-WindowsPowerShell -ArgumentList @('-Command', '[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; irm https://claude.ai/install.ps1 | iex')
        if ($exitCode -ne 0 -or -not (Resolve-ClaudePath)) { Stop-Installer 'Claude Code still was not found after installing it.' }
    }

    function Get-HttpStatus {
        param([Parameter(Mandatory)][Exception]$Exception)
        $response = $Exception.PSObject.Properties['Response']
        if ($null -eq $response -or $null -eq $response.Value) { return $null }
        [int]$response.Value.StatusCode
    }

    function Get-FuseModels {
        param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$Key)
        try {
            $response = Invoke-RestMethod -Uri "$BaseUrl/v1/models" -Headers @{ Authorization = "Bearer $Key" } -TimeoutSec $ModelListTimeoutSeconds -UseBasicParsing
        }
        catch {
            $status = Get-HttpStatus -Exception $_.Exception
            if ($null -eq $status) { Stop-Installer "Could not reach $BaseUrl" }
            if ($status -eq 401 -or $status -eq 403) { Stop-Installer "FUSE rejected that API key (HTTP $status)." }
            Stop-Installer "FUSE answered HTTP $status when listing models."
        }
        if ($response -is [string]) { $response = ConvertFrom-Json -InputObject $response }
        $models = Get-JsonProperty -Object $response -Name 'data'
        if ($null -eq $models) { $models = @() }
        , @($models)
    }

    function New-InstallPlan {
        param($Models, $Catalog, $Preferences, $Slots, [string]$Theme, [AllowNull()][AllowEmptyCollection()][string[]]$Verified)
        try {
            New-ModelPlan -Models $Models -Catalog $Catalog -Preferences $Preferences -Main $Slots.Main -Sonnet $Slots.Sonnet -Small $Slots.Small -Theme $Theme -Verified $Verified
        }
        catch [System.InvalidOperationException] {
            Stop-Installer $_.Exception.Message
        }
    }

    function Save-Plan {
        param($Plan, [string]$Key, [string]$BaseUrl, [string]$Theme, [string]$EnvFile, [string]$SettingsFile)
        $values = [ordered]@{
            FUSE_API_KEY       = $Key
            FUSE_BASE_URL      = $BaseUrl
            FUSE_THEME         = $Theme
            FUSE_DEFAULT_MODEL = $Plan.main
            FUSE_SONNET_MODEL  = $Plan.sonnet
            FUSE_SMALL_MODEL   = $Plan.small
            FUSE_BIN_DIR       = $BinDir
        }
        Write-PrivateFile -Path $EnvFile -Content (ConvertTo-FuseEnvText -Values $values)
        Write-PrivateFile -Path $SettingsFile -Content ((ConvertTo-FuseJson -InputObject $Plan.settings) + "`n")
    }

    function Start-ModelProbe {
        param([Parameter(Mandatory)][string]$Reference, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][hashtable]$Environment)
        $arguments = (Get-PowerShellHostArguments -NonInteractive) + @(
            '-File', $ProbeLauncher,
            '--model', $Reference, '--no-session-persistence', '--strict-mcp-config', '--setting-sources', 'project', '-p', $ProbePrompt
        )
        [pscustomobject]@{
            Reference = $Reference
            Captured  = Start-CapturedProcess -FilePath (Get-WindowsPowerShellPath) -ArgumentList $arguments -WorkingDirectory $WorkDir -Environment $Environment
            Deadline  = [DateTime]::UtcNow.AddSeconds($ProbeSeconds)
            ExitCode  = $null
        }
    }

    function Wait-ModelProbe {
        param([Parameter(Mandatory)]$Probe)
        $remaining = [int][Math]::Max(0, ($Probe.Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $Probe.ExitCode = Wait-CapturedProcess -Captured $Probe.Captured -TimeoutMilliseconds $remaining
    }

    function Get-ProbeFailure {
        param([Parameter(Mandatory)]$Probe)
        $text = Get-CapturedText -Captured $Probe.Captured
        if ($Probe.ExitCode -eq 0 -and $text -cnotmatch 'API Error') { return $null }
        $reason = @($text -split "`r?`n" | Where-Object { $_ -cmatch 'API Error|rror' }) | Select-Object -First 1
        Select-FirstValue @($reason, 'no answer')
    }

    function Remove-ProbeLeftovers {
        param([Parameter(Mandatory)][string]$ProbeDir, [Parameter(Mandatory)][string]$Token)
        Remove-Item -LiteralPath $ProbeDir -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Paths.ProjectsDir)) { return }
        Get-ChildItem -LiteralPath $Paths.ProjectsDir -Directory -Filter "*fuse-code-probe-$Token*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    function Test-Models {
        param($Plan, [string]$Key, [string]$BaseUrl, [string]$Theme)
        $token = New-ShortToken
        $probeDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "fuse-code-probe-$token")
        $workDir = [IO.Path]::Combine($probeDir, 'work')
        [void][IO.Directory]::CreateDirectory($workDir)
        $environment = @{
            FUSE_ENV_FILE      = [IO.Path]::Combine($probeDir, 'env')
            FUSE_SETTINGS_FILE = [IO.Path]::Combine($probeDir, 'settings.json')
            FUSE_SKIP_SETTINGS_GUARD = '1'
        }
        $probes = New-Object System.Collections.Generic.List[object]
        try {
            Save-Plan -Plan $Plan -Key $Key -BaseUrl $BaseUrl -Theme $Theme -EnvFile $environment.FUSE_ENV_FILE -SettingsFile $environment.FUSE_SETTINGS_FILE
            $references = [string[]]@($Plan.settings.modelPicker.options | ForEach-Object { $_.model })
            for ($start = 0; $start -lt $references.Count; $start += $ProbeParallel) {
                $end = [Math]::Min($start + $ProbeParallel, $references.Count) - 1
                $batch = @($references[$start..$end] | ForEach-Object { Start-ModelProbe -Reference $_ -WorkDir $workDir -Environment $environment })
                foreach ($probe in $batch) {
                    Wait-ModelProbe -Probe $probe
                    $probes.Add($probe)
                }
            }
        }
        finally {
            Remove-ProbeLeftovers -ProbeDir $probeDir -Token $token
        }
        $passed = New-Object System.Collections.Generic.List[string]
        foreach ($probe in $probes) {
            $failure = Get-ProbeFailure -Probe $probe
            if ($null -eq $failure) { $passed.Add((Get-ModelBase -Reference $probe.Reference)) }
            else { Write-Note "Skipping $($probe.Reference): $failure" }
        }
        , [string[]]$passed.ToArray()
    }

    function Resolve-Slots {
        param([Parameter(Mandatory)][ValidateSet('keep', 'reset')][string]$Mode)
        if ($Mode -ceq 'reset') {
            return @{ Main = [string]$Requested.Main; Sonnet = [string]$Requested.Sonnet; Small = [string]$Requested.Small }
        }
        @{
            Main   = Select-FirstValue @($Requested.Main, $Saved['FUSE_DEFAULT_MODEL'])
            Sonnet = Select-FirstValue @($Requested.Sonnet, $Saved['FUSE_SONNET_MODEL'])
            Small  = Select-FirstValue @($Requested.Small, $Saved['FUSE_SMALL_MODEL'])
        }
    }

    function Show-PlanSummary {
        param([Parameter(Mandatory)]$Plan)
        Write-Step 'Models'
        Write-Note "main   $($Plan.main)"
        Write-Note "sonnet $($Plan.sonnet)"
        Write-Note "small  $($Plan.small)"
        Write-Note "/model $(@($Plan.settings.modelPicker.options | ForEach-Object { $_.label }) -join ', ')"
    }

    function Update-Configuration {
        param([Parameter(Mandatory)][ValidateSet('keep', 'reset')][string]$Mode)
        $key = Resolve-ApiKey
        $baseUrl = (Select-FirstValue @($Requested.BaseUrl, $Saved['FUSE_BASE_URL'], $DefaultBaseUrl)).TrimEnd('/')
        $theme = if ((Select-FirstValue @($Requested.Theme, $Saved['FUSE_THEME'])) -ceq 'light') { 'light' } else { 'dark' }
        $slots = Resolve-Slots -Mode $Mode
        $catalog = @(Read-ModelCatalog -Path ([IO.Path]::Combine($Paths.ShareDir, 'models.tsv')))
        $preferences = Read-SlotPreferences -Path ([IO.Path]::Combine($Paths.ShareDir, 'slots.tsv'))

        Write-Step "Checking your key against $baseUrl"
        $models = Get-FuseModels -BaseUrl $baseUrl -Key $key
        $plan = New-InstallPlan -Models $models -Catalog $catalog -Preferences $preferences -Slots $slots -Theme $theme -Verified $null

        Write-Step 'Testing each model inside Claude Code'
        $verified = Test-Models -Plan $plan -Key $key -BaseUrl $baseUrl -Theme $theme
        $plan = New-InstallPlan -Models $models -Catalog $catalog -Preferences $preferences -Slots $slots -Theme $theme -Verified $verified
        Save-Plan -Plan $plan -Key $key -BaseUrl $baseUrl -Theme $theme -EnvFile $Paths.EnvFile -SettingsFile $Paths.FuseSettings
        Show-PlanSummary -Plan $plan
    }

    function Copy-Payload {
        $source = [IO.Path]::GetFullPath($SourceDir).TrimEnd('\')
        $target = [IO.Path]::GetFullPath($Paths.ShareDir).TrimEnd('\')
        if ($source -ieq $target) { return }
        foreach ($relative in $PayloadFiles) {
            $destination = [IO.Path]::Combine($Paths.ShareDir, $relative)
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            Copy-Item -LiteralPath ([IO.Path]::Combine($SourceDir, $relative)) -Destination $destination -Force
        }
        if (Test-Path -LiteralPath ([IO.Path]::Combine($SourceDir, '.git'))) {
            Write-TextFile -Path ([IO.Path]::Combine($Paths.ShareDir, 'source-dir')) -Content "$SourceDir`n"
        }
    }

    function Test-OwnLauncher {
        (Test-Path -LiteralPath $Launcher -PathType Leaf) -and (Select-String -LiteralPath $Launcher -Pattern 'fuse-code' -SimpleMatch -Quiet)
    }

    function Backup-ForeignLauncher {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$IsOwn)
        if (-not (Test-Path -LiteralPath $Path) -or $IsOwn) { return }
        $backup = "$Path.bak-$(Get-Date -Format yyyyMMddHHmmss)"
        Move-Item -LiteralPath $Path -Destination $backup
        Write-Note "Your previous fuse command was saved as $backup"
    }

    function Install-LauncherExecutable {
        Backup-ForeignLauncher -Path $LauncherExecutable -IsOwn (Test-FuseExecutable -Path $LauncherExecutable)
        try {
            Install-FuseExecutable -SourcePath ([IO.Path]::Combine($Paths.ShareDir, 'lib', 'FuseLauncher.cs')) -Destination $LauncherExecutable
        }
        catch {
            Write-Note "Could not build fuse.exe ($($_.Exception.Message)). Using fuse.cmd, which cannot pass & or line breaks in prompts."
        }
    }

    function Install-Launcher {
        [void][IO.Directory]::CreateDirectory($BinDir)
        Backup-ForeignLauncher -Path $Launcher -IsOwn (Test-OwnLauncher)
        Copy-Item -LiteralPath ([IO.Path]::Combine($Paths.ShareDir, 'bin', 'fuse.cmd')) -Destination $Launcher -Force
        Install-LauncherExecutable
    }

    function Install-Themes {
        [void][IO.Directory]::CreateDirectory($Paths.ThemesDir)
        foreach ($theme in 'fuse.json', 'fuse-light.json') {
            Copy-Item -LiteralPath ([IO.Path]::Combine($Paths.ShareDir, 'themes', $theme)) -Destination ([IO.Path]::Combine($Paths.ThemesDir, $theme)) -Force
        }
    }

    function Register-BinDirOnPath {
        if (Test-PathListContains -PathList $env:Path -Directory $BinDir) { return }
        if (Add-UserPathEntry -Directory $BinDir) {
            Write-Note "Added $BinDir to your PATH. Open a new terminal before running fuse."
            return
        }
        Write-Note 'Open a new terminal before running fuse.'
    }

    function Remove-PathIfPresent {
        param([Parameter(Mandatory)][string]$Path)
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    }

    function Install-Fuse {
        Initialize-ClaudeCode
        Copy-Payload
        Install-Launcher
        Install-Themes
        Update-Configuration -Mode keep
        if ((Invoke-NativeCommand -FilePath $Launcher -ArgumentList @('--version') -Quiet) -ne 0) { Write-Note 'Warning: fuse --version failed. Run it to see why.' }
        Register-BinDirOnPath
        Write-Host ''
        Write-Host 'Done.' -ForegroundColor Green -NoNewline
        Write-Host ' Run fuse to start Claude Code on FUSE.'
        Write-Note 'Refresh the model list any time with: fuse --refresh-models'
    }

    function Update-ModelList {
        param([Parameter(Mandatory)][ValidateSet('keep', 'reset')][string]$Mode)
        if (-not (Test-Path -LiteralPath $Paths.EnvFile -PathType Leaf)) { Stop-Installer 'fuse is not installed yet. Run the installer first.' }
        Update-Configuration -Mode $Mode
        Write-Step 'Model list updated. Restart any open fuse sessions to see it.'
    }

    function Update-Fuse {
        $marker = [IO.Path]::Combine($Paths.ShareDir, 'source-dir')
        $source = if (Test-Path -LiteralPath $marker) { [IO.File]::ReadAllText($marker).Trim() } else { '' }
        $git = @(Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($source -and $git -and (Test-Path -LiteralPath ([IO.Path]::Combine($source, '.git')))) {
            Write-Step "Pulling the latest fuse-code into $source"
            if ((Invoke-NativeCommand -FilePath $git.Path -ArgumentList @('-C', $source, 'pull', '--ff-only')) -ne 0) { Stop-Installer "git pull failed in $source." }
            exit (Invoke-WindowsPowerShell -ArgumentList @('-File', [IO.Path]::Combine($source, 'install.ps1')))
        }
        exit (Install-FromArchive -Forwarded @())
    }

    function Uninstall-Fuse {
        if (-not (Confirm-Action 'Remove fuse, its settings, themes and saved FUSE key?')) { Stop-Installer 'Cancelled.' }
        if (Test-Path -LiteralPath $ProbeLauncher) { [void](Invoke-WindowsPowerShell -ArgumentList @('-File', $ProbeLauncher, '--version') -Quiet) }
        if (Test-OwnLauncher) { Remove-Item -LiteralPath $Launcher -Force }
        if (Test-FuseExecutable -Path $LauncherExecutable) { Move-Item -LiteralPath $LauncherExecutable -Destination "$LauncherExecutable.old-$(New-ShortToken)" }
        if (Test-Path -LiteralPath $BinDir) { Remove-RetiredExecutables -Destination $LauncherExecutable }
        $leftovers = @(
            [IO.Path]::Combine($Paths.ClaudeDir, 'fuse'),
            $Paths.ShareDir,
            [IO.Path]::Combine($Paths.ThemesDir, 'fuse.json'),
            [IO.Path]::Combine($Paths.ThemesDir, 'fuse-light.json'),
            $Paths.EnvFile
        )
        foreach ($path in $leftovers) { Remove-PathIfPresent -Path $path }
        $envDir = [IO.Path]::GetDirectoryName($Paths.EnvFile)
        if ((Test-Path -LiteralPath $envDir) -and -not (Get-ChildItem -LiteralPath $envDir -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $envDir -Force }
        Write-Step 'fuse is uninstalled. Your regular Claude Code setup was not touched.'
    }

    $mode = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    switch -CaseSensitive ($mode) {
        '' { Install-Fuse }
        '--refresh-models' { Update-ModelList -Mode keep }
        '--reset-models' { Update-ModelList -Mode reset }
        '--self-update' { Update-Fuse }
        '--uninstall' { Uninstall-Fuse }
        '-h' { Get-UsageText }
        '--help' { Get-UsageText }
        default {
            [Console]::Error.WriteLine((Get-UsageText))
            exit 2
        }
    }
} $args
