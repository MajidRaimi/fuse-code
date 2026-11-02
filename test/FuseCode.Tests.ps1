Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent $PSScriptRoot
Import-Module ([IO.Path]::Combine($RepoDir, 'lib', 'FuseCode.psm1'))

$WorkDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "fuse-unit-$([Guid]::NewGuid().ToString('N').Substring(0, 8))")
[void][IO.Directory]::CreateDirectory($WorkDir)
$SettingsPath = [IO.Path]::Combine($WorkDir, 'settings.json')
$Arabic = [string]::new([char[]]@(0x645, 0x631, 0x62D, 0x628, 0x627))
$Guard = [pscustomobject]@{
    Path   = $SettingsPath
    Models = [string[]]@('moonshotai/Kimi-K3', 'zai-org/GLM-5.3-Flash')
    Themes = [string[]]@('custom:fuse', 'custom:fuse-light')
}
$Fixture = [IO.File]::ReadAllText([IO.Path]::Combine($PSScriptRoot, 'fixtures', 'models.json')) | ConvertFrom-Json
$Catalog = @(Read-ModelCatalog -Path ([IO.Path]::Combine($RepoDir, 'models.tsv')))
$Preferences = Read-SlotPreferences -Path ([IO.Path]::Combine($RepoDir, 'slots.tsv'))

$script:Passes = 0
$script:Failures = 0

function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Check)
    try {
        $outcome = & $Check
        if ($outcome -is [bool] -and $outcome) {
            $script:Passes++
            Write-Host "ok - $Name"
            return
        }
        $script:Failures++
        Write-Host "not ok - $Name"
        Write-Host "    | check returned $outcome"
    }
    catch {
        $script:Failures++
        Write-Host "not ok - $Name"
        Write-Host "    | $($_.Exception.Message)"
    }
}

function Set-Settings {
    param([Parameter(Mandatory)][string]$Json)
    [IO.File]::WriteAllText($SettingsPath, $Json)
}

function Get-SettingsText {
    [IO.File]::ReadAllText($SettingsPath)
}

function New-FixturePlan {
    param([string]$Main = '', [string]$Theme = 'dark', [AllowNull()][AllowEmptyCollection()][string[]]$Verified = $null)
    New-ModelPlan -Models @($Fixture.data) -Catalog $Catalog -Preferences $Preferences -Main $Main -Theme $Theme -Verified $Verified
}

function Get-OptionModels {
    param([Parameter(Mandatory)]$Plan)
    @($Plan.settings.modelPicker.options | ForEach-Object { $_.model }) -join ','
}

try {
    Test-Case 'json writer reproduces 2-space formatted settings byte for byte' {
        $original = (@(
                '{'
                '  "model": "moonshotai/Kimi-K3[1m]",'
                '  "permissions": {'
                '    "allow": ['
                '      "Bash(ls)"'
                '    ],'
                '    "deny": []'
                '  },'
                '  "env": {'
                "    `"GREETING`": `"$Arabic \`"quoted\`" back\\slash\ttab`","
                '    "EMPTY": {}'
                '  },'
                '  "cleanupPeriodDays": 30,'
                '  "ratio": 0.25,'
                '  "flag": false,'
                '  "nothing": null,'
                '  "createdAt": "2026-11-02T10:00:00Z"'
                '}'
            ) -join "`n") + "`n"
        Set-Settings $original
        ((ConvertTo-FuseJson -InputObject (Read-JsonFile -Path $SettingsPath)) + "`n") -ceq $original
    }

    Test-Case 'guard removes a leftover fuse model and theme and keeps everything else' {
        Set-Settings "{`"model`":`"moonshotai/Kimi-K3[1m]`",`"theme`":`"custom:fuse`",`"permissions`":{`"allow`":[`"Bash(ls)`"]},`"note`":`"$Arabic`"}"
        Restore-UserSettings -Guard $Guard -Previous @{}
        $after = Get-SettingsText | ConvertFrom-Json
        ($null -eq $after.PSObject.Properties['model']) -and ($null -eq $after.PSObject.Properties['theme']) -and (@($after.permissions.allow) -join ',' -ceq 'Bash(ls)') -and ($after.note -ceq $Arabic)
    }

    Test-Case 'guard puts back the previous model and theme' {
        Set-Settings '{"model":"zai-org/GLM-5.3-Flash[1m]","theme":"custom:fuse-light"}'
        Restore-UserSettings -Guard $Guard -Previous ([ordered]@{ model = 'opus'; theme = 'dark' })
        $after = Get-SettingsText | ConvertFrom-Json
        ($after.model -ceq 'opus') -and ($after.theme -ceq 'dark')
    }

    Test-Case 'guard leaves the user''s own values and does not rewrite the file' {
        $original = '{"model":"opus","theme":"dark"}'
        Set-Settings $original
        Restore-UserSettings -Guard $Guard -Previous @{}
        (Get-SettingsText) -ceq $original
    }

    Test-Case 'guard leaves invalid json and non-object json alone' {
        Set-Settings '{not json'
        Restore-UserSettings -Guard $Guard -Previous @{}
        $invalidKept = (Get-SettingsText) -ceq '{not json'
        Set-Settings '[{"model":"moonshotai/Kimi-K3"}]'
        Restore-UserSettings -Guard $Guard -Previous @{}
        $invalidKept -and ((Get-SettingsText) -ceq '[{"model":"moonshotai/Kimi-K3"}]')
    }

    Test-Case 'user choices only read exact lowercase keys' {
        Set-Settings '{"model":"Opus","Theme":"custom:fuse"}'
        $choices = Get-UserChoices -Guard $Guard
        ($choices.Count -eq 1) -and ($choices['model'] -ceq 'Opus')
    }

    Test-Case 'guard handoff survives a json round trip' {
        $handoff = ConvertFrom-GuardHandoff -Json (ConvertTo-GuardHandoff -Guard $Guard -Previous ([ordered]@{ model = 'opus' }) -LauncherId 4242)
        ($handoff.LauncherId -eq 4242) -and ($handoff.Guard.Models.Count -eq 2) -and ($handoff.Previous['model'] -ceq 'opus') -and ($handoff.Guard.Path -ceq $SettingsPath)
    }

    Test-Case 'guard handoff keeps empty lists empty' {
        $emptyGuard = [pscustomobject]@{ Path = 'x'; Models = [string[]]@(); Themes = [string[]]@('custom:fuse') }
        $handoff = ConvertFrom-GuardHandoff -Json (ConvertTo-GuardHandoff -Guard $emptyGuard -Previous @{} -LauncherId 1)
        ($handoff.Guard.Models.Count -eq 0) -and ($handoff.Previous.Count -eq 0) -and ($handoff.Guard.Themes.Count -eq 1)
    }

    Test-Case 'command lines quote spaces, quotes, empty values and trailing backslashes' {
        $line = ConvertTo-CommandLine -ArgumentList @('-p', 'fix the failing test', '', 'say "hi"', 'C:\path with space\', 'a\\"b', '--model', 'zai-org/GLM-5.3-Flash[1m]')
        $line -ceq '-p "fix the failing test" "" "say \"hi\"" "C:\path with space\\" "a\\\\\"b" --model zai-org/GLM-5.3-Flash[1m]'
    }

    Test-Case 'empty argument lists become an empty command line' {
        ((ConvertTo-CommandLine -ArgumentList @()) -ceq '') -and ((ConvertTo-CommandLine -ArgumentList $null) -ceq '')
    }

    Test-Case 'env files round trip without leaving staging files' {
        $envPath = [IO.Path]::Combine($WorkDir, 'config', 'env')
        Write-PrivateFile -Path $envPath -Content (ConvertTo-FuseEnvText -Values ([ordered]@{ FUSE_API_KEY = 'k=1'; FUSE_DEFAULT_MODEL = 'moonshotai/Kimi-K3[1m]'; FUSE_SONNET_MODEL = '' }))
        $values = Read-FuseEnv -Path $envPath
        ($values['FUSE_API_KEY'] -ceq 'k=1') -and ($values['FUSE_DEFAULT_MODEL'] -ceq 'moonshotai/Kimi-K3[1m]') -and ($values['FUSE_SONNET_MODEL'] -ceq '') -and (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($envPath))).Count -eq 1)
    }

    Test-Case 'env values with line breaks are rejected' {
        try {
            [void](ConvertTo-FuseEnvText -Values @{ X = "a`nb" })
            $false
        }
        catch [System.ArgumentException] {
            $true
        }
    }

    Test-Case 'a single-row tsv stays one row and missing columns read as empty' {
        $tsv = [IO.Path]::Combine($WorkDir, 'one.tsv')
        [IO.File]::WriteAllText($tsv, "only`trow`n")
        $rows = @(Read-ModelCatalog -Path $tsv)
        ($rows.Count -eq 1) -and ($rows[0].id -ceq 'only') -and ($rows[0].label -ceq 'row') -and ($rows[0].summary -ceq '')
    }

    Test-Case 'path lists match entries with trailing slashes and ignore case' {
        (Test-PathListContains -PathList 'C:\a;C:\Users\x\.LOCAL\bin\;D:\b' -Directory 'C:\Users\x\.local\bin') -and -not (Test-PathListContains -PathList '' -Directory 'C:\x')
    }

    Test-Case 'model base strips only a trailing lowercase [1m]' {
        ((Get-ModelBase -Reference 'a/b[1m]') -ceq 'a/b') -and ((Get-ModelBase -Reference 'a/b[1M]') -ceq 'a/b[1M]') -and ((Get-ModelBase -Reference $null) -ceq '')
    }

    Test-Case 'plan before probing lists every chat model with 1M suffixes' {
        $plan = New-FixturePlan
        ((Get-OptionModels $plan) -ceq 'moonshotai/Kimi-K3[1m],zai-org/GLM-5.3-Flash[1m],deepseek-ai/DeepSeek-V4.1-Flash,Qwen/Qwen3.8-Flash-Next,tarjama/llmx-1.0,acme/new-chat-9') -and ($plan.main -ceq 'moonshotai/Kimi-K3[1m]') -and ($plan.sonnet -ceq 'zai-org/GLM-5.3-Flash[1m]') -and ($plan.small -ceq 'Qwen/Qwen3.8-Flash-Next') -and ($plan.settings.theme -ceq 'custom:fuse')
    }

    Test-Case 'plan after probing keeps only verified models' {
        $plan = New-FixturePlan -Verified @('zai-org/GLM-5.3-Flash', 'Qwen/Qwen3.8-Flash-Next')
        ((Get-OptionModels $plan) -ceq 'zai-org/GLM-5.3-Flash[1m],Qwen/Qwen3.8-Flash-Next') -and ($plan.main -ceq 'zai-org/GLM-5.3-Flash[1m]') -and ($plan.small -ceq 'Qwen/Qwen3.8-Flash-Next')
    }

    Test-Case 'a picked preset is appended with its preset label' {
        $plan = New-FixturePlan -Main '@preset/team-coder' -Theme 'light'
        $last = @($plan.settings.modelPicker.options)[-1]
        ($plan.main -ceq '@preset/team-coder[1m]') -and ($last.label -ceq 'Team Coder') -and ($last.description -ceq 'Fuse preset for moonshotai/Kimi-K3') -and ($plan.settings.theme -ceq 'custom:fuse-light')
    }

    Test-Case 'no verified model is an InvalidOperationException' {
        try {
            [void](New-FixturePlan -Verified @())
            $false
        }
        catch [System.InvalidOperationException] {
            $_.Exception.Message -ceq 'no model passed the Claude Code check'
        }
    }
}
finally {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "unit: $script:Passes passed, $script:Failures failed"
if ($script:Failures -gt 0) { exit 1 }
