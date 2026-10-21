[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ReleaseDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = 'luizram17/soul-table-updates'
if ($env:GITHUB_REPOSITORY -ne $repository) {
    throw 'Release publishing is restricted to luizram17/soul-table-updates.'
}
if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw 'Version must be strict semantic version major.minor.patch.'
}
if ($TargetCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'TargetCommit must be a 40-character lowercase Git SHA.'
}
if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw 'GH_TOKEN is required for publishing with this workflow run token.'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required on the Windows runner.'
}

$releaseRoot = [System.IO.Path]::GetFullPath($ReleaseDirectory)
if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
    throw 'The signed release output directory does not exist.'
}
$tag = "v$Version"
$assetNames = @(
    "Soul.Table-Windows-GM-$Version.zip",
    "Soul.Table-Windows-Player-$Version.zip",
    'windows-gm-stable.json',
    'windows-player-stable.json',
    'SHA256SUMS.txt',
    'release-summary.json'
)
$actualEntries = @(Get-ChildItem -LiteralPath $releaseRoot -Force | ForEach-Object { $_.Name })
if ($actualEntries.Count -ne $assetNames.Count -or @($actualEntries | Where-Object { $_ -notin $assetNames }).Count -gt 0) {
    throw 'Release output must contain only the two ZIPs, two manifests, SHA256SUMS.txt, and release-summary.json.'
}
foreach ($assetName in $assetNames) {
    $assetPath = Join-Path $releaseRoot $assetName
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Required release asset is missing: $assetName"
    }
}

$packageNames = @(
    "Soul.Table-Windows-GM-$Version.zip",
    "Soul.Table-Windows-Player-$Version.zip"
)
$manifestNames = @('windows-gm-stable.json', 'windows-player-stable.json')
$sumPath = Join-Path $releaseRoot 'SHA256SUMS.txt'
$sumLines = @(Get-Content -LiteralPath $sumPath)
if ($sumLines.Count -ne 4) {
    throw 'SHA256SUMS.txt must contain one record for each ZIP and manifest.'
}
$sumRecords = @{}
foreach ($line in $sumLines) {
    if ($line -notmatch '^(?<sha256>[0-9a-f]{64})  (?<path>[A-Za-z0-9._-]+)$') {
        throw 'SHA256SUMS.txt has an invalid record.'
    }
    $sumRecords[$Matches.path] = $Matches.sha256
}
$expectedHashedNames = @($packageNames + $manifestNames | Sort-Object)
if ((@($sumRecords.Keys | Sort-Object) -join "`n") -ne ($expectedHashedNames -join "`n")) {
    throw 'SHA256SUMS.txt lists unexpected or duplicate release assets.'
}
foreach ($assetName in $expectedHashedNames) {
    $actualHash = (Get-FileHash -LiteralPath (Join-Path $releaseRoot $assetName) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sumRecords[$assetName] -ne $actualHash) {
        throw "SHA256SUMS.txt does not match $assetName."
    }
}

$nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$expectedManifestFields = @(
    'schema_version', 'version', 'minimum_supported', 'channel', 'platform',
    'url', 'size', 'sha256', 'expires_at', 'package_signature', 'signature'
)
foreach ($edition in @('gm', 'player')) {
    $manifestName = "windows-$edition-stable.json"
    $manifestPath = Join-Path $releaseRoot $manifestName
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifestFields = @($manifest.PSObject.Properties.Name | Sort-Object)
    if (($manifestFields -join "`n") -ne (@($expectedManifestFields | Sort-Object) -join "`n")) {
        throw "$manifestName does not use the closed UpdateService v1 schema."
    }
    $zipName = if ($edition -eq 'gm') { $packageNames[0] } else { $packageNames[1] }
    $zipPath = Join-Path $releaseRoot $zipName
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (
        $manifest.schema_version -ne 1 -or
        $manifest.version -ne $Version -or
        $manifest.channel -ne 'stable' -or
        $manifest.platform -ne 'windows' -or
        $manifest.url -ne "https://github.com/$repository/releases/download/$tag/$zipName" -or
        $manifest.size -ne (Get-Item -LiteralPath $zipPath).Length -or
        $manifest.sha256 -ne $zipHash -or
        [int64]$manifest.expires_at -le $nowUnix -or
        $manifest.minimum_supported -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
    ) {
        throw "$manifestName does not describe the expected unexpired ZIP."
    }
    foreach ($field in @('package_signature', 'signature')) {
        try {
            $signature = [Convert]::FromBase64String([string]$manifest.$field)
        }
        catch {
            throw "$manifestName has an invalid $field encoding."
        }
        if ($signature.Length -lt 1 -or $signature.Length -gt 1024) {
            throw "$manifestName has an invalid $field length."
        }
    }
}

$summary = Get-Content -LiteralPath (Join-Path $releaseRoot 'release-summary.json') -Raw | ConvertFrom-Json
if (
    $summary.schema_version -ne 1 -or
    $summary.version -ne $Version -or
    $summary.channel -ne 'stable' -or
    $summary.platform -ne 'windows' -or
    $summary.repository -ne $repository -or
    @($summary.packages).Count -ne 2 -or
    ((@($summary.packages.edition | Sort-Object) -join ',') -ne 'gm,player')
) {
    throw 'release-summary.json does not match the stable Windows release.'
}

function Assert-GitHubResourceNotFound {
    param([Parameter(Mandatory = $true)][string]$ApiPath)

    $response = @(& gh api $ApiPath 2>&1)
    $status = $LASTEXITCODE
    if ($status -eq 0) {
        throw "Refusing to overwrite an existing GitHub resource: $ApiPath"
    }
    $message = $response -join "`n"
    if ($message -notmatch '(?i)(HTTP 404|Not Found)') {
        throw "Could not verify that the GitHub resource is absent: $ApiPath"
    }
}

Assert-GitHubResourceNotFound "repos/$repository/releases/tags/$tag"
Assert-GitHubResourceNotFound "repos/$repository/git/ref/tags/$tag"

$assetPaths = @($assetNames | ForEach-Object { Join-Path $releaseRoot $_ })
& gh release create $tag @assetPaths `
    --repo $repository `
    --target $TargetCommit `
    --title "Soul.Table $Version — Stable Windows" `
    --notes "Soul.Table $Version stable Windows update packages for GM and Player."
if ($LASTEXITCODE -ne 0) {
    throw "GitHub release creation failed (exit $LASTEXITCODE)."
}

Write-Output "Published $tag with two signed Windows packages, two manifests, checksums, and summary."
