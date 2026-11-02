Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:FuseThemes = [string[]]@('custom:fuse', 'custom:fuse-light')
$script:OneMillionTokens = 1000000
$script:TokensPerThousand = 1000
$script:ChatContextFloor = 200000
$script:NonChatModelPattern = 'embed|rerank|vision|translat|transcri|stt|tts|image|i2v|t2v'
$script:JsonEscapePattern = New-Object System.Text.RegularExpressions.Regex('[\\"\u0000-\u001f]')
$script:JsonNumberTypes = [type[]]@([byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64], [decimal])
$script:JsonFloatTypes = [type[]]@([single], [double])
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:JsonParseOptions = @{}
$script:ConvertFromJsonParameters = (Get-Command -Name ConvertFrom-Json).Parameters
if ($script:ConvertFromJsonParameters.ContainsKey('DateKind')) { $script:JsonParseOptions['DateKind'] = 'String' }
if ($script:ConvertFromJsonParameters.ContainsKey('NoEnumerate')) { $script:JsonParseOptions['NoEnumerate'] = $true }
$script:BroadcastWindow = [IntPtr]0xffff
$script:SettingChangeMessage = [uint32]0x1A
$script:AbortIfHungFlag = [uint32]2
$script:BroadcastTimeoutMilliseconds = [uint32]1000
$script:CapturedTextTimeoutMilliseconds = 10000
$script:LauncherProduct = 'fuse-code'
$script:BatchExtensions = [string[]]@('.cmd', '.bat')
$script:BatchPercentEscape = '%%cd:~,%'

function Test-WindowsHost {
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-FusePaths {
    $userHome = $env:USERPROFILE
    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { [IO.Path]::Combine($userHome, '.claude') }
    [pscustomobject]@{
        Home          = $userHome
        ShareDir      = [IO.Path]::Combine($userHome, '.local', 'share', 'fuse-code')
        DefaultBinDir = [IO.Path]::Combine($userHome, '.local', 'bin')
        EnvFile       = [IO.Path]::Combine($userHome, '.config', 'fuse', 'env')
        ClaudeDir     = $claudeDir
        FuseSettings  = [IO.Path]::Combine($claudeDir, 'fuse', 'settings.json')
        UserSettings  = [IO.Path]::Combine($claudeDir, 'settings.json')
        ThemesDir     = [IO.Path]::Combine($claudeDir, 'themes')
        ProjectsDir   = [IO.Path]::Combine($claudeDir, 'projects')
    }
}

function Get-WindowsPowerShellPath {
    [IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
}

function Get-PowerShellHostArguments {
    param([switch]$NonInteractive)
    $hostArguments = @('-NoLogo', '-NoProfile')
    if ($NonInteractive) { $hostArguments += '-NonInteractive' }
    $hostArguments + @('-ExecutionPolicy', 'Bypass')
}

function New-ShortToken {
    [Guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Select-FirstValue {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Candidates)
    foreach ($candidate in $Candidates) {
        if ($candidate) { return [string]$candidate }
    }
    ''
}

function Get-ModelBase {
    param([AllowNull()][AllowEmptyString()][string]$Reference)
    $Reference -creplace '\[1m\]$', ''
}

function Get-JsonProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return , $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Name -cne $Name) { return $null }
    , $property.Value
}

function ConvertTo-OrderedDictionary {
    param([AllowNull()][object]$Object)
    $dictionary = [ordered]@{}
    if ($null -eq $Object) { return $dictionary }
    foreach ($property in $Object.PSObject.Properties) { $dictionary[$property.Name] = $property.Value }
    $dictionary
}

function ConvertTo-JsonString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $escaped = $script:JsonEscapePattern.Replace($Text, [System.Text.RegularExpressions.MatchEvaluator] {
            param($match)
            switch -CaseSensitive ($match.Value) {
                '"' { '\"' }
                '\' { '\\' }
                "`n" { '\n' }
                "`r" { '\r' }
                "`t" { '\t' }
                "`b" { '\b' }
                "`f" { '\f' }
                default { '\u{0:x4}' -f [int][char]$match.Value }
            }
        })
    '"' + $escaped + '"'
}

function ConvertTo-FuseJson {
    param([AllowNull()][object]$InputObject)
    $builder = New-Object System.Text.StringBuilder
    Add-JsonValue -Builder $builder -Value $InputObject -Indent ''
    $builder.ToString()
}

function Add-JsonValue {
    param([System.Text.StringBuilder]$Builder, [AllowNull()][object]$Value, [string]$Indent)
    if ($null -eq $Value) { [void]$Builder.Append('null'); return }
    if ($Value -is [string] -or $Value -is [char]) { [void]$Builder.Append((ConvertTo-JsonString -Text ([string]$Value))); return }
    if ($Value -is [bool]) { [void]$Builder.Append($(if ($Value) { 'true' } else { 'false' })); return }
    $type = $Value.GetType()
    if ($script:JsonNumberTypes -contains $type) { [void]$Builder.Append($Value.ToString($script:Invariant)); return }
    if ($script:JsonFloatTypes -contains $type) { [void]$Builder.Append($Value.ToString('R', $script:Invariant)); return }
    if ($Value -is [System.Collections.IDictionary]) {
        $entries = @(foreach ($key in $Value.Keys) { [pscustomobject]@{ Name = [string]$key; Value = $Value[$key] } })
        Add-JsonObject -Builder $Builder -Entries $entries -Indent $Indent
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $entries = @(foreach ($property in $Value.PSObject.Properties) { [pscustomobject]@{ Name = $property.Name; Value = $property.Value } })
        Add-JsonObject -Builder $Builder -Entries $entries -Indent $Indent
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        Add-JsonArray -Builder $Builder -Items @($Value) -Indent $Indent
        return
    }
    [void]$Builder.Append((ConvertTo-JsonString -Text ([string]$Value)))
}

function Add-JsonObject {
    param([System.Text.StringBuilder]$Builder, [AllowEmptyCollection()][object[]]$Entries, [string]$Indent)
    if ($Entries.Count -eq 0) { [void]$Builder.Append('{}'); return }
    $inner = $Indent + '  '
    [void]$Builder.Append("{`n")
    for ($index = 0; $index -lt $Entries.Count; $index++) {
        [void]$Builder.Append($inner).Append((ConvertTo-JsonString -Text $Entries[$index].Name)).Append(': ')
        Add-JsonValue -Builder $Builder -Value $Entries[$index].Value -Indent $inner
        if ($index -lt $Entries.Count - 1) { [void]$Builder.Append(',') }
        [void]$Builder.Append("`n")
    }
    [void]$Builder.Append($Indent).Append('}')
}

function Add-JsonArray {
    param([System.Text.StringBuilder]$Builder, [AllowEmptyCollection()][object[]]$Items, [string]$Indent)
    if ($Items.Count -eq 0) { [void]$Builder.Append('[]'); return }
    $inner = $Indent + '  '
    [void]$Builder.Append("[`n")
    for ($index = 0; $index -lt $Items.Count; $index++) {
        [void]$Builder.Append($inner)
        Add-JsonValue -Builder $Builder -Value $Items[$index] -Indent $inner
        if ($index -lt $Items.Count - 1) { [void]$Builder.Append(',') }
        [void]$Builder.Append("`n")
    }
    [void]$Builder.Append($Indent).Append(']')
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $options = $script:JsonParseOptions
    try {
        $parsed = ConvertFrom-Json -InputObject $text @options
    }
    catch [System.ArgumentException] {
        return $null
    }
    , $parsed
}

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Protect-CurrentUserFile {
    param([Parameter(Mandatory)][string]$Path)
    $security = New-Object System.Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, 'FullControl', 'Allow')
    $security.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Write-PrivateFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $staging = "$Path.$(New-ShortToken)"
    try {
        Write-TextFile -Path $staging -Content $Content
        if (Test-WindowsHost) { Protect-CurrentUserFile -Path $staging }
        Move-Item -LiteralPath $staging -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
    }
}

function Read-FuseEnv {
    param([Parameter(Mandatory)][string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $values }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) { $values[$line.Substring(0, $separator)] = $line.Substring($separator + 1) }
    }
    $values
}

function ConvertTo-FuseEnvText {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $lines = foreach ($entry in $Values.GetEnumerator()) {
        $value = [string]$entry.Value
        if ($value -match '[\r\n]') { throw [System.ArgumentException]::new("$($entry.Key) cannot contain a line break.") }
        "$($entry.Key)=$value"
    }
    ($lines -join "`n") + "`n"
}

function Read-TsvRows {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.Length -gt 0) { [pscustomobject]@{ Columns = $line.Split("`t") } }
    }
}

function Get-TsvColumn {
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][int]$Index)
    if ($Index -lt $Row.Columns.Count) { return $Row.Columns[$Index] }
    ''
}

function Read-ModelCatalog {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($row in Read-TsvRows -Path $Path) {
        [pscustomobject]@{ id = Get-TsvColumn $row 0; label = Get-TsvColumn $row 1; summary = Get-TsvColumn $row 2 }
    }
}

function Read-SlotPreferences {
    param([Parameter(Mandatory)][string]$Path)
    $preferences = @{}
    foreach ($row in Read-TsvRows -Path $Path) {
        $preferences[(Get-TsvColumn $row 0)] = [string[]]@((Get-TsvColumn $row 1).Split(' ') | Where-Object { $_ })
    }
    $preferences
}

function New-OrdinalSet {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Items)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($item in $Items) { [void]$set.Add($item) }
    , $set
}

function Get-ModelEntry {
    param($Context, [AllowNull()][AllowEmptyString()][string]$Id)
    if ($Id -and $Context.ById.ContainsKey($Id)) { return $Context.ById[$Id] }
    $null
}

function Get-ContextLength {
    param($Context, [AllowNull()][AllowEmptyString()][string]$Id)
    $model = Get-ModelEntry -Context $Context -Id $Id
    $length = Get-JsonProperty -Object $model -Name 'max_model_len'
    if ($null -eq $length) {
        $target = [string](Get-JsonProperty -Object (Get-JsonProperty -Object $model -Name 'preset') -Name 'model')
        $length = Get-JsonProperty -Object (Get-ModelEntry -Context $Context -Id $target) -Name 'max_model_len'
    }
    if ($null -eq $length) { return [long]0 }
    [long]$length
}

function Format-ContextLabel {
    param([long]$Length)
    if ($Length -ge $script:OneMillionTokens) { return '1M' }
    if ($Length -gt 0) { return "$([long][Math]::Floor($Length / $script:TokensPerThousand))k" }
    'unknown'
}

function Get-ContextDescription {
    param($Context, [string]$Id, [string]$Detail)
    "Fuse, $(Format-ContextLabel -Length (Get-ContextLength -Context $Context -Id $Id)) context, $Detail"
}

function Test-ModelUsable {
    param($Context, [AllowNull()][AllowEmptyString()][string]$Id)
    if ($null -eq (Get-ModelEntry -Context $Context -Id $Id)) { return $false }
    $null -eq $Context.Verified -or $Context.Verified.Contains($Id)
}

function Get-ModelReference {
    param($Context, [string]$Id)
    if ((Get-ContextLength -Context $Context -Id $Id) -ge $script:OneMillionTokens) { return "$Id[1m]" }
    $Id
}

function Test-ChatModel {
    param($Context, [string]$Id)
    $owner = [string](Get-JsonProperty -Object (Get-ModelEntry -Context $Context -Id $Id) -Name 'owned_by')
    ($owner -ceq 'vllm') -and ((Get-ContextLength -Context $Context -Id $Id) -ge $script:ChatContextFloor) -and ($Id -notmatch $script:NonChatModelPattern)
}

function Get-LastSegment {
    param([string]$Id)
    $Id.Split('/')[-1]
}

function Select-SlotModel {
    param($Context, [AllowEmptyString()][string]$Current, [AllowNull()][AllowEmptyCollection()][string[]]$Ranked, [AllowEmptyCollection()][string[]]$KnownIds)
    $wanted = Get-ModelBase -Reference $Current
    if ($wanted -and (Test-ModelUsable -Context $Context -Id $wanted)) { return $wanted }
    foreach ($candidate in @($Ranked) + @($KnownIds)) {
        if ($candidate -and (Test-ModelUsable -Context $Context -Id $candidate)) { return $candidate }
    }
    $null
}

function New-PickerOption {
    param([string]$Model, [string]$Label, [string]$Description)
    [ordered]@{ model = $Model; label = $Label; description = $Description }
}

function New-ExtraPickerOption {
    param($Context, [string]$Id)
    $reference = Get-ModelReference -Context $Context -Id $Id
    if (-not $Id.StartsWith('@preset/', [StringComparison]::Ordinal)) {
        return New-PickerOption -Model $reference -Label (Get-LastSegment -Id $Id) -Description (Get-ContextDescription -Context $Context -Id $Id -Detail 'your pick')
    }
    $preset = Get-JsonProperty -Object (Get-ModelEntry -Context $Context -Id $Id) -Name 'preset'
    $label = Select-FirstValue @((Get-JsonProperty -Object $preset -Name 'name'), $Id)
    $target = Select-FirstValue @((Get-JsonProperty -Object $preset -Name 'model'), 'a custom model')
    New-PickerOption -Model $reference -Label $label -Description "Fuse preset for $target"
}

function New-ModelPlan {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Models,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog,
        [Parameter(Mandatory)][hashtable]$Preferences,
        [AllowEmptyString()][string]$Main = '',
        [AllowEmptyString()][string]$Sonnet = '',
        [AllowEmptyString()][string]$Small = '',
        [string]$Theme = 'dark',
        [AllowNull()][AllowEmptyCollection()][string[]]$Verified = $null
    )
    $byId = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($model in $Models) { $byId[[string](Get-JsonProperty -Object $model -Name 'id')] = $model }
    $verifiedSet = if ($null -eq $Verified) { $null } else { New-OrdinalSet -Items $Verified }
    $context = [pscustomobject]@{ ById = $byId; Verified = $verifiedSet }
    $knownIds = [string[]]@($Catalog | ForEach-Object { $_.id })

    $mainId = Select-SlotModel -Context $context -Current $Main -Ranked $Preferences['main'] -KnownIds $knownIds
    if ($null -eq $mainId) {
        $reason = if ($null -eq $Verified) { 'none of the supported chat models are enabled for this key' } else { 'no model passed the Claude Code check' }
        throw [System.InvalidOperationException]::new($reason)
    }
    $sonnetId = Select-FirstValue @((Select-SlotModel -Context $context -Current $Sonnet -Ranked $Preferences['sonnet'] -KnownIds $knownIds), $mainId)
    $smallId = Select-FirstValue @((Select-SlotModel -Context $context -Current $Small -Ranked $Preferences['small'] -KnownIds $knownIds), $mainId)

    $options = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Catalog) {
        if (Test-ModelUsable -Context $context -Id $entry.id) {
            $options.Add((New-PickerOption -Model (Get-ModelReference -Context $context -Id $entry.id) -Label $entry.label -Description (Get-ContextDescription -Context $context -Id $entry.id -Detail $entry.summary)))
        }
    }
    $knownSet = New-OrdinalSet -Items $knownIds
    foreach ($model in $Models) {
        $id = [string](Get-JsonProperty -Object $model -Name 'id')
        if (-not $knownSet.Contains($id) -and (Test-ChatModel -Context $context -Id $id) -and (Test-ModelUsable -Context $context -Id $id)) {
            $options.Add((New-PickerOption -Model (Get-ModelReference -Context $context -Id $id) -Label (Get-LastSegment -Id $id) -Description (Get-ContextDescription -Context $context -Id $id -Detail 'new on Fuse')))
        }
    }
    $listedIds = New-OrdinalSet -Items @($options | ForEach-Object { Get-ModelBase -Reference $_.model })
    $picks = [string[]]@($mainId, $sonnetId, $smallId)
    [Array]::Sort($picks, [StringComparer]::Ordinal)
    $seen = New-OrdinalSet -Items @()
    foreach ($id in $picks) {
        if ($seen.Add($id) -and -not $listedIds.Contains($id)) { $options.Add((New-ExtraPickerOption -Context $context -Id $id)) }
    }

    $themeName = if ($Theme -ceq 'light') { 'custom:fuse-light' } else { 'custom:fuse' }
    [pscustomobject]@{
        main     = Get-ModelReference -Context $context -Id $mainId
        sonnet   = Get-ModelReference -Context $context -Id $sonnetId
        small    = Get-ModelReference -Context $context -Id $smallId
        settings = [ordered]@{
            modelPicker               = [ordered]@{ replaceBuiltInOptions = $true; options = $options.ToArray() }
            theme                     = $themeName
            disableClaudeAiConnectors = $true
        }
    }
}

function New-SettingsGuard {
    param([Parameter(Mandatory)][string]$UserSettingsPath, [Parameter(Mandatory)][string]$FuseSettingsPath, [AllowEmptyCollection()][string[]]$SlotModels)
    $fuseSettings = if (Test-Path -LiteralPath $FuseSettingsPath -PathType Leaf) { Read-JsonFile -Path $FuseSettingsPath } else { $null }
    $options = Get-JsonProperty -Object (Get-JsonProperty -Object $fuseSettings -Name 'modelPicker') -Name 'options'
    $references = @(foreach ($option in @($options)) { Get-JsonProperty -Object $option -Name 'model' }) + @($SlotModels)
    [pscustomobject]@{
        Path   = $UserSettingsPath
        Models = [string[]]@($references | Where-Object { $_ } | ForEach-Object { Get-ModelBase -Reference $_ } | Sort-Object -Unique -CaseSensitive)
        Themes = $script:FuseThemes
    }
}

function Read-UserSettings {
    param([Parameter(Mandatory)]$Guard)
    if (-not (Test-Path -LiteralPath $Guard.Path -PathType Leaf)) { return $null }
    $settings = Read-JsonFile -Path $Guard.Path
    if ($settings -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $settings
}

function Get-UserChoices {
    param([Parameter(Mandatory)]$Guard)
    $choices = [ordered]@{}
    $settings = Read-UserSettings -Guard $Guard
    foreach ($key in 'model', 'theme') {
        $value = Get-JsonProperty -Object $settings -Name $key
        if ($null -ne $value) { $choices[$key] = $value }
    }
    $choices
}

function Reset-FuseChoices {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Guard, [AllowEmptyCollection()][System.Collections.IDictionary]$Previous)
    $owned = @{ model = @($Guard.Models); theme = @($Guard.Themes) }
    $changed = $false
    foreach ($key in 'model', 'theme') {
        $property = $Settings.PSObject.Properties[$key]
        if ($null -eq $property -or $property.Name -cne $key -or $property.Value -isnot [string]) { continue }
        if ($owned[$key] -cnotcontains (Get-ModelBase -Reference $property.Value)) { continue }
        if ($Previous.Contains($key)) { $property.Value = $Previous[$key] } else { $Settings.PSObject.Properties.Remove($key) }
        $changed = $true
    }
    $changed
}

function Restore-UserSettings {
    param([Parameter(Mandatory)]$Guard, [AllowEmptyCollection()][System.Collections.IDictionary]$Previous = @{})
    $settings = Read-UserSettings -Guard $Guard
    if ($null -eq $settings) { return }
    if (-not (Reset-FuseChoices -Settings $settings -Guard $Guard -Previous $Previous)) { return }
    Write-TextFile -Path $Guard.Path -Content ((ConvertTo-FuseJson -InputObject $settings) + "`n")
}

function ConvertTo-GuardHandoff {
    param([Parameter(Mandatory)]$Guard, [AllowEmptyCollection()][System.Collections.IDictionary]$Previous, [Parameter(Mandatory)][int]$LauncherId)
    ConvertTo-FuseJson -InputObject ([ordered]@{
            launcherId = $LauncherId
            path       = $Guard.Path
            models     = $Guard.Models
            themes     = $Guard.Themes
            previous   = $Previous
        })
}

function ConvertFrom-GuardHandoff {
    param([Parameter(Mandatory)][string]$Json)
    $handoff = ConvertFrom-Json -InputObject $Json
    [pscustomobject]@{
        LauncherId = [int]$handoff.launcherId
        Guard      = [pscustomobject]@{ Path = [string]$handoff.path; Models = [string[]]@($handoff.models); Themes = [string[]]@($handoff.themes) }
        Previous   = ConvertTo-OrderedDictionary -Object $handoff.previous
    }
}

function ConvertTo-CommandLine {
    param([AllowNull()][AllowEmptyCollection()][string[]]$ArgumentList)
    if ($null -eq $ArgumentList) { return '' }
    $quoted = foreach ($argument in $ArgumentList) {
        if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') { $argument; continue }
        '"' + (($argument -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }
    @($quoted) -join ' '
}

function ConvertFrom-CommandLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CommandLine)
    $arguments = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuotes = $false
    $hasArgument = $false
    $index = 0
    while ($index -lt $CommandLine.Length) {
        $character = $CommandLine[$index]
        if ($character -eq [char]'\') {
            $start = $index
            while ($index -lt $CommandLine.Length -and $CommandLine[$index] -eq [char]'\') { $index++ }
            $count = $index - $start
            $quoteFollows = $index -lt $CommandLine.Length -and $CommandLine[$index] -eq [char]'"'
            $literalCount = if ($quoteFollows) { [int](($count - ($count % 2)) / 2) } else { $count }
            [void]$current.Append([char]'\', $literalCount)
            if ($quoteFollows -and ($count % 2) -eq 1) {
                [void]$current.Append([char]'"')
                $index++
            }
            $hasArgument = $true
        }
        elseif ($character -eq [char]'"') {
            if ($inQuotes -and ($index + 1) -lt $CommandLine.Length -and $CommandLine[$index + 1] -eq [char]'"') {
                [void]$current.Append([char]'"')
                $index += 2
            }
            else {
                $inQuotes = -not $inQuotes
                $index++
            }
            $hasArgument = $true
        }
        elseif (-not $inQuotes -and ($character -eq [char]' ' -or $character -eq [char]"`t")) {
            if ($hasArgument) {
                $arguments.Add($current.ToString())
                [void]$current.Clear()
                $hasArgument = $false
            }
            $index++
        }
        else {
            [void]$current.Append($character)
            $hasArgument = $true
            $index++
        }
    }
    if ($hasArgument) { $arguments.Add($current.ToString()) }
    , [string[]]$arguments.ToArray()
}

function ConvertTo-BatchCommandLine {
    param([AllowNull()][AllowEmptyCollection()][string[]]$ArgumentList)
    if ($null -eq $ArgumentList) { return '' }
    $quoted = foreach ($argument in $ArgumentList) {
        if ($argument -match '[\r\n]') { throw [System.ArgumentException]::new('Claude Code is installed as a .cmd file, which cannot receive line breaks. Install the native Claude Code to pass multi-line prompts.') }
        $escaped = (($argument -replace '(\\*)"', '$1$1""') -replace '(\\+)$', '$1$1').Replace('%', $script:BatchPercentEscape)
        '"' + $escaped + '"'
    }
    @($quoted) -join ' '
}

function Test-BatchFile {
    param([Parameter(Mandatory)][string]$FilePath)
    $script:BatchExtensions -icontains [IO.Path]::GetExtension($FilePath)
}

function New-NativeStartInfo {
    param([Parameter(Mandatory)][string]$FilePath, [AllowNull()][AllowEmptyCollection()][string[]]$ArgumentList)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    if (Test-BatchFile -FilePath $FilePath) {
        $startInfo.FileName = [IO.Path]::Combine($env:SystemRoot, 'System32', 'cmd.exe')
        $startInfo.Arguments = '/d /e:ON /v:OFF /c ""' + $FilePath + '" ' + (ConvertTo-BatchCommandLine -ArgumentList $ArgumentList) + '"'
    }
    else {
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = ConvertTo-CommandLine -ArgumentList $ArgumentList
    }
    $startInfo.UseShellExecute = $false
    $startInfo
}

function Invoke-NativeCommand {
    param([Parameter(Mandatory)][string]$FilePath, [AllowNull()][AllowEmptyCollection()][string[]]$ArgumentList, [switch]$Quiet)
    if ($Quiet) {
        $captured = Start-CapturedProcess -FilePath $FilePath -ArgumentList $ArgumentList
        return Wait-CapturedProcess -Captured $captured
    }
    $process = [System.Diagnostics.Process]::Start((New-NativeStartInfo -FilePath $FilePath -ArgumentList $ArgumentList))
    try {
        $process.WaitForExit()
        $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Start-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowNull()][AllowEmptyCollection()][string[]]$ArgumentList,
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{}
    )
    $startInfo = New-NativeStartInfo -FilePath $FilePath -ArgumentList $ArgumentList
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    foreach ($entry in $Environment.GetEnumerator()) { $startInfo.EnvironmentVariables[$entry.Key] = [string]$entry.Value }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Close()
    [pscustomobject]@{
        Process = $process
        Output  = $process.StandardOutput.ReadToEndAsync()
        Errors  = $process.StandardError.ReadToEndAsync()
    }
}

function Wait-CapturedProcess {
    param([Parameter(Mandatory)]$Captured, [int]$TimeoutMilliseconds = -1)
    if (-not $Captured.Process.WaitForExit($TimeoutMilliseconds)) {
        Stop-ProcessTree -ProcessId $Captured.Process.Id
        $Captured.Process.WaitForExit()
        return $null
    }
    $Captured.Process.WaitForExit()
    $Captured.Process.ExitCode
}

function Get-CompletedText {
    param([Parameter(Mandatory)][System.Threading.Tasks.Task[string]]$Reader)
    if ($Reader.IsCompleted) { return $Reader.Result }
    ''
}

function Get-CapturedText {
    param([Parameter(Mandatory)]$Captured)
    [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($Captured.Output, $Captured.Errors), $script:CapturedTextTimeoutMilliseconds)
    (Get-CompletedText -Reader $Captured.Output) + "`n" + (Get-CompletedText -Reader $Captured.Errors)
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    $taskkill = [IO.Path]::Combine($env:SystemRoot, 'System32', 'taskkill.exe')
    [void](Wait-CapturedProcess -Captured (Start-CapturedProcess -FilePath $taskkill -ArgumentList @('/PID', [string]$ProcessId, '/T', '/F')))
}

function Test-FuseExecutable {
    param([Parameter(Mandatory)][string]$Path)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and ((Get-Item -LiteralPath $Path).VersionInfo.ProductName -ceq $script:LauncherProduct)
}

function Remove-RetiredExecutables {
    param([Parameter(Mandatory)][string]$Destination)
    $directory = [IO.Path]::GetDirectoryName($Destination)
    foreach ($retired in @(Get-ChildItem -LiteralPath $directory -Filter "$([IO.Path]::GetFileName($Destination)).old-*" -File)) {
        try { Remove-Item -LiteralPath $retired.FullName -Force -ErrorAction Stop }
        catch [System.UnauthorizedAccessException] { continue }
        catch [System.IO.IOException] { continue }
    }
}

function Install-FuseExecutable {
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$Destination)
    $token = New-ShortToken
    $staging = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Destination), "fuse-build-$token.exe")
    try {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText($SourcePath)) -Language CSharp -OutputAssembly $staging -OutputType ConsoleApplication
        if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination "$Destination.old-$token" }
        Move-Item -LiteralPath $staging -Destination $Destination
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
    }
    Remove-RetiredExecutables -Destination $Destination
}

function Resolve-ClaudePath {
    $commands = @(Get-Command -Name claude -CommandType Application -All -ErrorAction SilentlyContinue)
    $preferred = @($commands | Where-Object { $_.Extension -ieq '.exe' }) + $commands | Select-Object -First 1
    if ($preferred) { return $preferred.Path }
    $fallback = [IO.Path]::Combine($env:USERPROFILE, '.local', 'bin', 'claude.exe')
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    $null
}

function Test-PathListContains {
    param([AllowNull()][AllowEmptyString()][string]$PathList, [Parameter(Mandatory)][string]$Directory)
    $wanted = $Directory.TrimEnd('\', '/')
    foreach ($entry in ([string]$PathList).Split(';')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim()).TrimEnd('\', '/')
        if ($expanded -and $expanded -ieq $wanted) { return $true }
    }
    $false
}

function Add-UserPathEntry {
    param([Parameter(Mandatory)][string]$Directory)
    $environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $current = [string]$environmentKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (Test-PathListContains -PathList $current -Directory $Directory) { return $false }
        $entries = @($current.Split(';') | Where-Object { $_ }) + $Directory
        $environmentKey.SetValue('Path', ($entries -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    }
    finally {
        $environmentKey.Close()
    }
    Send-EnvironmentChange
    $true
}

function Send-EnvironmentChange {
    if (-not ('FuseCode.EnvironmentBroadcast' -as [type])) {
        Add-Type -Namespace FuseCode -Name EnvironmentBroadcast -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr window, uint message, System.UIntPtr wParam, string lParam, uint flags, uint timeout, out System.UIntPtr result);
'@
    }
    $broadcastResult = [UIntPtr]::Zero
    [void][FuseCode.EnvironmentBroadcast]::SendMessageTimeout($script:BroadcastWindow, $script:SettingChangeMessage, [UIntPtr]::Zero, 'Environment', $script:AbortIfHungFlag, $script:BroadcastTimeoutMilliseconds, [ref]$broadcastResult)
}

Export-ModuleMember -Function @(
    'Test-WindowsHost', 'Get-FusePaths', 'Get-WindowsPowerShellPath', 'Get-PowerShellHostArguments', 'New-ShortToken', 'Select-FirstValue',
    'Get-ModelBase', 'Get-JsonProperty', 'ConvertTo-FuseJson', 'Read-JsonFile', 'Write-TextFile', 'Write-PrivateFile',
    'Read-FuseEnv', 'ConvertTo-FuseEnvText', 'Read-ModelCatalog', 'Read-SlotPreferences', 'New-ModelPlan',
    'New-SettingsGuard', 'Get-UserChoices', 'Restore-UserSettings', 'ConvertTo-GuardHandoff', 'ConvertFrom-GuardHandoff',
    'ConvertTo-CommandLine', 'ConvertFrom-CommandLine', 'ConvertTo-BatchCommandLine', 'Test-FuseExecutable', 'Install-FuseExecutable', 'Remove-RetiredExecutables', 'Send-EnvironmentChange', 'Invoke-NativeCommand', 'Start-CapturedProcess', 'Wait-CapturedProcess', 'Get-CapturedText',
    'Stop-ProcessTree', 'Resolve-ClaudePath', 'Test-PathListContains', 'Add-UserPathEntry'
)
