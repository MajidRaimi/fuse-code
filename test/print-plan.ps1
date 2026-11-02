param(
    [Parameter(Mandatory)][string]$ModelsPath,
    [AllowEmptyString()][string]$Main = '',
    [AllowEmptyString()][string]$Sonnet = '',
    [AllowEmptyString()][string]$Small = '',
    [string]$Theme = 'dark',
    [string]$VerifiedJson = 'null'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent $PSScriptRoot
Import-Module ([IO.Path]::Combine($RepoDir, 'lib', 'FuseCode.psm1'))

$verified = $null
if ($VerifiedJson -cne 'null') { $verified = [string[]]@(ConvertFrom-Json -InputObject $VerifiedJson) }
$models = @(([IO.File]::ReadAllText($ModelsPath) | ConvertFrom-Json).data)
try {
    $plan = New-ModelPlan -Models $models -Catalog @(Read-ModelCatalog -Path ([IO.Path]::Combine($RepoDir, 'models.tsv'))) -Preferences (Read-SlotPreferences -Path ([IO.Path]::Combine($RepoDir, 'slots.tsv'))) -Main $Main -Sonnet $Sonnet -Small $Small -Theme $Theme -Verified $verified
    ConvertTo-FuseJson -InputObject $plan
}
catch [System.InvalidOperationException] {
    "error: $($_.Exception.Message)"
}
