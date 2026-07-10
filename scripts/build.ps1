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

# 4. Prepare release folder and clean old App03 files
$releaseDir = "release"
if (-not (Test-Path $releaseDir)) {
    New-Item -Path $releaseDir -ItemType Directory | Out-Null
} else {
    # Clean up legacy App03 files to prevent clutter
    Get-ChildItem $releaseDir -Filter "App03_*" | Remove-Item -Force
}

# 5. Compile AHK Script using CMD to guarantee synchronous execution and correct path parsing
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
$compileCmd = "`"$compilerPath`" /in `"$absAhkPath`" /out `"$absOutPath`" /icon `"$absIconPath`" /base `"$absBaseAhk`""
cmd.exe /c $compileCmd

if (-not (Test-Path $outputExePath)) {
    Write-Error "Failed to generate compiled exe: $outputExePath"
}
Write-Host "Compilation finished: $outputExeName"

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

# 8. Git Commit and Push
Write-Host "[5/6] Committing and pushing git changes..."
git add .
$gitStatus = git status --porcelain
if ($gitStatus) {
    git commit -m "Release v$version"
    git push origin main
    Write-Host "Git changes successfully pushed to origin."
} else {
    Write-Host "No changes to commit."
}

# 9. GitHub Release creation and asset upload
Write-Host "[6/6] Creating/Updating GitHub Release and uploading assets..."
$tag = "v$version"

$releaseExists = $true
try {
    gh release view $tag >$null 2>&1
} catch {
    $releaseExists = $false
}

if ($LastExitCode -ne 0) {
    $releaseExists = $false
}

if ($releaseExists) {
    Write-Host "Release $tag already exists. Deleting it to refresh all assets..."
    gh release delete $tag -y >$null 2>&1
    # Give GitHub API a moment to process deletion
    Start-Sleep -Seconds 2
}

Write-Host "Creating new release $tag and uploading assets..."
gh release create $tag $outputExePath $outputZipPath $app03ExePath $app03ZipPath --title $tag --notes "Release $tag"

Write-Host "=========================================="
Write-Host " Build and Release Pipeline completed successfully!"
Write-Host "=========================================="
Write-Host "Deployed files:"
Get-ChildItem $releaseDir | Where-Object { $_.Name -match "v$version|App03" } | Select-Object Name, Length
