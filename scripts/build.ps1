# scripts/build.ps1
# ClipOCR-Pro automated build, copy, and GitHub release upload script

$ErrorActionPreference = "Stop"

# 1. Verify paths
$ahkPath = "src/ClipOCR-Pro.ahk"
if (-not (Test-Path $ahkPath)) {
    Write-Error "Could not find src/ClipOCR-Pro.ahk"
}

# 2. Extract version from script
$ahkContent = Get-Content -Path $ahkPath -Raw
if ($ahkContent -match 'global APP_VERSION\s*:=\s*"([^"]+)"') {
    $version = $Matches[1]
} else {
    Write-Error "Could not find APP_VERSION in script."
}

$expectedFileVersion = "$version.0"
if ($ahkContent -notmatch ";@Ahk2Exe-SetVersion\s+$([regex]::Escape($expectedFileVersion))(?:\s|$)") {
    Write-Error "APP_VERSION ($version) and Ahk2Exe file version ($expectedFileVersion) are not synchronized."
}

Write-Host "=========================================="
Write-Host " ClipOCR-Pro Auto Build and Release Pipeline"
Write-Host " Target Version: v$version"
Write-Host "=========================================="

# 3. Check GitHub CLI Auth
Write-Host "[1/6] Checking GitHub CLI auth status..."
$ghAuth = gh auth status 2>&1
if ($LastExitCode -ne 0) {
    Write-Error "GitHub CLI is not authenticated. Please run 'gh auth login' first."
}
Write-Host "GitHub CLI auth check succeeded."

$tag = "v$version"
$existingReleaseTags = gh release list --limit 1000 --json tagName | ConvertFrom-Json
if ($LastExitCode -ne 0) {
    Write-Error "Could not query existing GitHub releases."
}
if ($existingReleaseTags.tagName -contains $tag) {
    Write-Error "Release $tag already exists. Bump APP_VERSION instead of replacing a published release."
}

# 4. Prepare release folder and clean old files
$releaseDir = "release"
if (-not (Test-Path $releaseDir)) {
    New-Item -Path $releaseDir -ItemType Directory | Out-Null
} else {
    # Replace only artifacts for the target version; older builds may still be running.
    $targetArtifacts = @(
        "ClipOCR-Pro.v$version.exe",
        "ClipOCR-Pro.v$version.zip",
        "App03_ClipOCR-Pro_v$version.exe",
        "App03_ClipOCR-Pro_v$version.zip"
    )
    foreach ($artifactName in $targetArtifacts) {
        $artifactPath = Join-Path $releaseDir $artifactName
        if (Test-Path -LiteralPath $artifactPath) {
            Remove-Item -LiteralPath $artifactPath -Force
        }
    }
}

# 5. Compile AHK script
$compilerPath = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
$baseAhk = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
$iconPath = "assets\ClipOCR-Pro.ico"
$outputExeName = "ClipOCR-Pro.v$version.exe"
$outputExePath = Join-Path $releaseDir $outputExeName

if (-not (Test-Path $compilerPath)) {
    Write-Error "AutoHotkey compiler not found at $compilerPath"
}

# Resolve absolute paths to prevent any relative path resolution issues
$absAhkPath = [System.IO.Path]::GetFullPath($ahkPath)
$absOutPath = [System.IO.Path]::GetFullPath($outputExePath)
$absIconPath = [System.IO.Path]::GetFullPath($iconPath)
$absBaseAhk = [System.IO.Path]::GetFullPath($baseAhk)

Write-Host "[2/6] Compiling AHK script..."
$compileArguments = "/in `"$absAhkPath`" /out `"$absOutPath`" /icon `"$absIconPath`" /base `"$absBaseAhk`""
$compileProcess = Start-Process -FilePath $compilerPath -ArgumentList $compileArguments -Wait -PassThru
if ($compileProcess.ExitCode -ne 0) {
    Write-Error "Ahk2Exe failed with exit code $($compileProcess.ExitCode)."
}

if (-not (Test-Path $outputExePath)) {
    Write-Error "Failed to generate compiled exe: $outputExePath"
}
$compiledFileVersion = (Get-Item -LiteralPath $outputExePath).VersionInfo.FileVersion
if ($compiledFileVersion -ne $expectedFileVersion) {
    Write-Error "Compiled EXE version ($compiledFileVersion) does not match expected version ($expectedFileVersion)."
}

$healthProcess = Start-Process -FilePath $outputExePath -ArgumentList "--health-check" -Wait -PassThru
if ($healthProcess.ExitCode -ne 0) {
    $healthLog = Join-Path $env:TEMP "ClipOCR-Pro\health-check.log"
    Write-Error "Compiled EXE health check failed. See $healthLog"
}
Write-Host "Compilation and health check finished: $outputExeName"

# 6. Compress to ZIP
$outputZipName = "ClipOCR-Pro.v$version.zip"
$outputZipPath = Join-Path $releaseDir $outputZipName

if (Test-Path $outputZipPath) {
    Remove-Item $outputZipPath -Force
}

Write-Host "[3/6] Compiling ZIP archive..."
Compress-Archive -Path $outputExePath -DestinationPath $outputZipPath
Write-Host "ZIP archive created: $outputZipName"

# 7. Create corporate copy (App03_ClipOCR-Pro_v[Version])
Write-Host "[4/6] Creating App03_ClipOCR-Pro_v$version copies..."
$app03ExePath = Join-Path $releaseDir "App03_ClipOCR-Pro_v$version.exe"
$app03ZipPath = Join-Path $releaseDir "App03_ClipOCR-Pro_v$version.zip"

Copy-Item -Path $outputExePath -Destination $app03ExePath -Force
Copy-Item -Path $outputZipPath -Destination $app03ZipPath -Force
Write-Host "Corporate copy files created (App03_ClipOCR-Pro_v$version.exe and App03_ClipOCR-Pro_v$version.zip)"

# 8. Git commit and push only project release inputs (never stage unrelated workspace files)
Write-Host "[5/6] Committing and pushing release inputs..."
$releaseInputs = @("src/ClipOCR-Pro.ahk", "src/Gdip_All.ahk", "scripts/build.ps1", "README.md", "README.ko.md", "assets")
git add -- $releaseInputs
$gitStatus = git status --porcelain -- $releaseInputs
if ($gitStatus) {
    git commit -m "Release v$version"
    git push origin main
    Write-Host "Git changes successfully pushed to origin."
} else {
    Write-Host "No changes to commit."
}

# 9. Create an immutable GitHub release at the exact pushed commit
Write-Host "[6/6] Creating GitHub Release and uploading assets..."
$releaseTarget = (git rev-parse HEAD).Trim()
Write-Host "Creating release $tag at commit $releaseTarget..."
gh release create $tag $outputExePath $outputZipPath $app03ExePath $app03ZipPath --target $releaseTarget --title $tag --notes "Release $tag"

Write-Host "=========================================="
Write-Host " Build and Release Pipeline completed successfully!"
Write-Host "=========================================="
Write-Host "Deployed files:"
Get-ChildItem $releaseDir | Where-Object { $_.Name -match "v$version|App03" } | Select-Object Name, Length
