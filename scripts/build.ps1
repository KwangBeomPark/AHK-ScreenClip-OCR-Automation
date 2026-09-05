[CmdletBinding()]
param(
    [string]$OutputDirectory = "dist",
    [string]$AutoHotkeyPath = $env:AUTOHOTKEY_EXE_PATH,
    [string]$CompilerPath = $env:AHK2EXE_PATH,
    [string]$CertificatePath = $env:CLIPOCR_SIGN_CERT_PATH,
    [string]$TimestampServer = $env:CLIPOCR_TIMESTAMP_SERVER,
    [string]$TesseractDirectory = $env:CLIPOCR_TESSERACT_DIR,
    [switch]$IncludeEnterpriseAliases
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repoRoot "src\ClipOCR-Pro.ahk"
$iconPath = Join-Path $repoRoot "assets\ClipOCR-Pro.ico"

function Resolve-ExistingFile {
    param([string]$ConfiguredPath, [string]$DefaultPath, [string]$Description)

    $candidate = if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) { $DefaultPath } else { $ConfiguredPath }
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $repoRoot $candidate
    }
    $candidate = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "$Description was not found: $candidate"
    }
    return $candidate
}

function Invoke-CheckedProcess {
    param([string]$FilePath, [string]$Arguments, [string]$Description)

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "$Description failed with exit code $($process.ExitCode)."
    }
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Could not find the application source: $sourcePath"
}

$ahkExe = Resolve-ExistingFile $AutoHotkeyPath "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "AutoHotkey v2 runtime"
$ahk2Exe = Resolve-ExistingFile $CompilerPath "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" "Ahk2Exe compiler"
$source = Get-Content -Raw -LiteralPath $sourcePath
if ($source -notmatch 'global APP_VERSION\s*:=\s*"([^\"]+)"') {
    throw "Could not find APP_VERSION in $sourcePath"
}
$version = $Matches[1]
$expectedFileVersion = "$version.0"
if ($source -notmatch ";@Ahk2Exe-SetVersion\s+$([regex]::Escape($expectedFileVersion))(?:\s|$)") {
    throw "APP_VERSION ($version) and Ahk2Exe file version ($expectedFileVersion) are not synchronized."
}

$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$baseName = "ClipOCR-Pro.v$version"
$exePath = Join-Path $outputRoot "$baseName.exe"
$zipPath = Join-Path $outputRoot "$baseName.zip"
$manifestPath = Join-Path $outputRoot "build-manifest.json"
$checksumsPath = Join-Path $outputRoot "SHA256SUMS.txt"
$fullZipPath = Join-Path $outputRoot "App03_ClipOCR-Pro_v$version-Full.zip"
$portableOcrRoot = $null
if (-not [string]::IsNullOrWhiteSpace($TesseractDirectory)) {
    $portableOcrRoot = if ([IO.Path]::IsPathRooted($TesseractDirectory)) {
        [IO.Path]::GetFullPath($TesseractDirectory)
    } else {
        [IO.Path]::GetFullPath((Join-Path $repoRoot $TesseractDirectory))
    }
    foreach ($requiredPath in @(
        (Join-Path $portableOcrRoot "tesseract.exe"),
        (Join-Path $portableOcrRoot "tessdata\kor.traineddata"),
        (Join-Path $portableOcrRoot "tessdata\eng.traineddata")
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Full OCR package requires an approved portable Tesseract runtime with kor and eng data: $requiredPath"
        }
    }
}
$targetArtifacts = @($exePath, $zipPath, $manifestPath, $checksumsPath)
if ($null -ne $portableOcrRoot) {
    $targetArtifacts += $fullZipPath
}
if ($IncludeEnterpriseAliases) {
    $targetArtifacts += Join-Path $outputRoot "App03_ClipOCR-Pro_v$version.exe"
    $targetArtifacts += Join-Path $outputRoot "App03_ClipOCR-Pro_v$version.zip"
}
foreach ($target in $targetArtifacts) {
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Remove-Item -LiteralPath $target -Force
    }
}

Write-Host "[1/5] Running source health check..."
Invoke-CheckedProcess $ahkExe "/ErrorStdOut `"$sourcePath`" --health-check" "Source health check"

Write-Host "[2/5] Compiling $baseName.exe..."
$compileArgs = "/in `"$sourcePath`" /out `"$exePath`" /icon `"$iconPath`" /base `"$ahkExe`" /silent verbose"
Invoke-CheckedProcess $ahk2Exe $compileArgs "Ahk2Exe compilation"
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Compiler did not create $exePath"
}

$compiledVersion = (Get-Item -LiteralPath $exePath).VersionInfo.FileVersion
if ($compiledVersion -ne $expectedFileVersion) {
    throw "Compiled EXE version ($compiledVersion) does not match $expectedFileVersion."
}

$signatureStatus = "NotSigned"
$signed = $false
if (-not [string]::IsNullOrWhiteSpace($CertificatePath)) {
    Write-Host "[3/5] Signing executable..."
    $certificateFile = Resolve-ExistingFile $CertificatePath $CertificatePath "Signing certificate"
    $passwordText = $env:CLIPOCR_SIGN_CERT_PASSWORD
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certificateFile,
        $(if ($null -eq $passwordText) { "" } else { $passwordText }),
        $flags
    )
    if (-not $certificate.HasPrivateKey) {
        throw "The configured certificate does not contain a private key. A .cer file cannot sign releases."
    }
    $signParams = @{
        FilePath      = $exePath
        Certificate   = $certificate
        HashAlgorithm = "SHA256"
    }
    if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
        $signParams.TimestampServer = $TimestampServer
    }
    $signature = Set-AuthenticodeSignature @signParams
    if ($null -eq $signature.SignerCertificate -or $signature.SignatureType -eq "None") {
        throw "Authenticode signing did not produce a signature. Status: $($signature.Status)"
    }
    $signatureStatus = [string]$signature.Status
    $signed = $true
} else {
    Write-Host "[3/5] Signing skipped (CLIPOCR_SIGN_CERT_PATH is not configured)."
}

Write-Host "[4/5] Running compiled health check and creating archives..."
Invoke-CheckedProcess $exePath "--health-check" "Compiled health check"
Compress-Archive -LiteralPath $exePath -DestinationPath $zipPath -CompressionLevel Optimal

$artifactPaths = [System.Collections.Generic.List[string]]::new()
$artifactPaths.Add($exePath)
$artifactPaths.Add($zipPath)
if ($IncludeEnterpriseAliases) {
    $enterpriseExe = Join-Path $outputRoot "App03_ClipOCR-Pro_v$version.exe"
    $enterpriseZip = Join-Path $outputRoot "App03_ClipOCR-Pro_v$version.zip"
    Copy-Item -LiteralPath $exePath -Destination $enterpriseExe
    Copy-Item -LiteralPath $zipPath -Destination $enterpriseZip
    $artifactPaths.Add($enterpriseExe)
    $artifactPaths.Add($enterpriseZip)
}
if ($null -ne $portableOcrRoot) {
    $fullStage = Join-Path $outputRoot ".full-stage-$([Diagnostics.Process]::GetCurrentProcess().Id)"
    if (Test-Path -LiteralPath $fullStage) {
        Remove-Item -LiteralPath $fullStage -Recurse -Force
    }
    try {
        New-Item -ItemType Directory -Path $fullStage | Out-Null
        Copy-Item -LiteralPath $exePath -Destination (Join-Path $fullStage "ClipOCR-Pro.exe")
        Copy-Item -LiteralPath $portableOcrRoot -Destination (Join-Path $fullStage "ocr") -Recurse
        Compress-Archive -Path (Join-Path $fullStage "*") -DestinationPath $fullZipPath -CompressionLevel Optimal
        $artifactPaths.Add($fullZipPath)
    } finally {
        if (Test-Path -LiteralPath $fullStage) {
            Remove-Item -LiteralPath $fullStage -Recurse -Force
        }
    }
}

Write-Host "[5/5] Writing checksums and build manifest..."
$artifactInfo = foreach ($path in $artifactPaths) {
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject]@{
        name   = $item.Name
        bytes  = $item.Length
        sha256 = $hash
    }
}
$checksumLines = $artifactInfo | ForEach-Object { "$($_.sha256)  $($_.name)" }
Set-Content -LiteralPath $checksumsPath -Value $checksumLines -Encoding utf8NoBOM

$commit = ""
$workingTreeDirty = $false
try {
    $commit = (& git -C $repoRoot rev-parse HEAD 2>$null).Trim()
    $workingTreeDirty = [bool](& git -C $repoRoot status --porcelain 2>$null)
} catch {
    $commit = ""
}
$manifest = [ordered]@{
    application     = "ClipOCR-Pro"
    version         = $version
    fileVersion     = $expectedFileVersion
    commit          = $commit
    workingTreeDirty = $workingTreeDirty
    builtAtUtc      = [DateTime]::UtcNow.ToString("o")
    signed          = $signed
    signatureStatus = $signatureStatus
    fullOcrPackage  = ($null -ne $portableOcrRoot)
    artifacts       = @($artifactInfo)
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

Write-Host "Build complete: $outputRoot"
Write-Output $manifest
