[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $repoRoot "src\ClipOCR-Pro.ahk"
$main = Get-Content -Raw -LiteralPath $mainPath
$failures = [Collections.Generic.List[string]]::new()

function Assert-Project {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

foreach ($scriptPath in @(
    (Join-Path $PSScriptRoot "build.ps1"),
    (Join-Path $PSScriptRoot "publish.ps1"),
    (Join-Path $PSScriptRoot "Invoke-WindowsOcr.ps1"),
    $PSCommandPath
)) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    Assert-Project ($parseErrors.Count -eq 0) "PowerShell syntax errors in $scriptPath"
}

$appVersion = [regex]::Match($main, 'global APP_VERSION\s*:=\s*"([^"]+)"')
$fileVersion = [regex]::Match($main, ';@Ahk2Exe-SetVersion\s+([^\s]+)')
Assert-Project $appVersion.Success "APP_VERSION is missing."
Assert-Project $fileVersion.Success "Ahk2Exe file version is missing."
if ($appVersion.Success -and $fileVersion.Success) {
    Assert-Project ($fileVersion.Groups[1].Value -eq "$($appVersion.Groups[1].Value).0") "App and file versions differ."
}

foreach ($include in @("SuiteRegistry.ahk", "OcrService.ahk", "HealthCheck.ahk")) {
    Assert-Project ($main -match "(?m)^#Include $([regex]::Escape($include))$") "Missing module include: $include"
}

$menuNumbers = @([regex]::Matches($main, '(?m)^ClipMenu\.Add\("[^"]*? (\d+)\.') |
    ForEach-Object { [int]$_.Groups[1].Value })
Assert-Project ($menuNumbers.Count -eq 20) "Expected 20 numbered capture-menu commands."
for ($index = 0; $index -lt $menuNumbers.Count; $index++) {
    Assert-Project ($menuNumbers[$index] -eq ($index + 1)) "Capture-menu numbering is out of sequence."
}

foreach ($readOnlyModule in @("SuiteRegistry.ahk", "OcrService.ahk", "HealthCheck.ahk")) {
    $moduleText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "src\$readOnlyModule")
    Assert-Project ($moduleText -notmatch '\bRegWrite\b') "$readOnlyModule must not write Registry values."
}

$ocrText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "src\OcrService.ahk")
$ocrHelperText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "Invoke-WindowsOcr.ps1")
Assert-Project ($ocrText -notmatch 'https?://|GoogleTranslate|EnsureTranslationConsent') "Local OCR service crosses the external-service boundary."
Assert-Project ($ocrHelperText -notmatch 'Invoke-WebRequest|HttpClient|WebClient|https?://') "Windows OCR helper contains network access."
Assert-Project ($main -match 'FileInstall\("\.\.\\scripts\\Invoke-WindowsOcr\.ps1"') "Compiled OCR helper embedding is missing."

$buildText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "build.ps1")
$publishText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "publish.ps1")
Assert-Project ($buildText -notmatch '(?im)^\s*(git\s+push|gh\s+release)') "Build script must not publish."
Assert-Project ($publishText -notmatch '(?im)^\s*git\s+(commit|add)') "Publish script must not create commits."
Assert-Project (Test-Path -LiteralPath (Join-Path $repoRoot "docs\OCR_PACKAGING.md") -PathType Leaf) "OCR deployment guide is missing."

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error "FAIL: $_" }
    exit 1
}

Write-Host "ClipOCR-Pro static checks: PASS"
