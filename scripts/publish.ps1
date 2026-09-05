[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$OutputDirectory = "release",
    [switch]$AllowUnsigned,
    [switch]$NoPush,
    [switch]$Draft
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repoRoot "src\ClipOCR-Pro.ahk"
$source = Get-Content -Raw -LiteralPath $sourcePath
if ($source -notmatch 'global APP_VERSION\s*:=\s*"([^\"]+)"') {
    throw "Could not find APP_VERSION."
}
$version = $Matches[1]
$tag = "v$version"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required to publish."
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI is required to publish."
}

$branch = (& git -C $repoRoot branch --show-current).Trim()
if ($branch -ne "main") {
    throw "Publishing is allowed only from main; current branch is '$branch'."
}
$workingChanges = & git -C $repoRoot status --porcelain
if ($workingChanges) {
    throw "Commit or remove working-tree changes before publishing. publish.ps1 never commits automatically."
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated."
}
& gh release view $tag *> $null
if ($LASTEXITCODE -eq 0) {
    throw "GitHub release $tag already exists. Bump APP_VERSION instead of replacing it."
}

& (Join-Path $PSScriptRoot "build.ps1") -OutputDirectory $OutputDirectory -IncludeEnterpriseAliases

$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
}
$manifestPath = Join-Path $outputRoot "build-manifest.json"
$checksumsPath = Join-Path $outputRoot "SHA256SUMS.txt"
$manifestData = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if (-not $manifestData.signed -and -not $AllowUnsigned) {
    throw "Release is unsigned. Configure CLIPOCR_SIGN_CERT_PATH and CLIPOCR_SIGN_CERT_PASSWORD, or explicitly pass -AllowUnsigned."
}

$assets = @($manifestData.artifacts | ForEach-Object { Join-Path $outputRoot $_.name })
$assets += $manifestPath
$assets += $checksumsPath
foreach ($asset in $assets) {
    if (-not (Test-Path -LiteralPath $asset -PathType Leaf)) {
        throw "Missing release asset: $asset"
    }
}

$targetCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
$action = "push main and create immutable GitHub release $tag at $targetCommit"
if (-not $PSCmdlet.ShouldProcess("origin/main", $action)) {
    return
}

if (-not $NoPush) {
    & git -C $repoRoot push origin main
    if ($LASTEXITCODE -ne 0) {
        throw "git push origin main failed."
    }
}

$releaseArgs = @("release", "create", $tag) + $assets + @(
    "--target", $targetCommit,
    "--title", $tag,
    "--notes", "Release $tag"
)
if ($Draft) {
    $releaseArgs += "--draft"
}
& gh @releaseArgs
if ($LASTEXITCODE -ne 0) {
    throw "GitHub release creation failed."
}

Write-Host "Published $tag at $targetCommit"
