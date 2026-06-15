# Sync Remoter-Win to GitHub Repository
# Repository: https://github.com/ricklxf/Remoter
# Target Folder: Remoter-Win

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Sync Remoter-Win to GitHub" -ForegroundColor Cyan
Write-Host "Repository: https://github.com/ricklxf/Remoter" -ForegroundColor Cyan
Write-Host "Target Folder: Remoter-Win" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Configuration
$repoUrl = "https://github.com/ricklxf/Remoter.git"
$targetFolder = "Remoter-Win"
$tempDir = Join-Path $env:TEMP "remoter_github_sync"
$currentDir = Get-Location

Write-Host "Step 1: Clone the remote repository" -ForegroundColor Yellow
Write-Host "Temp directory: $tempDir" -ForegroundColor Gray
Write-Host ""

# Clean up temp directory if exists
if (Test-Path $tempDir) {
    Write-Host "Cleaning up temp directory..." -ForegroundColor Gray
    Remove-Item -Path $tempDir -Recurse -Force
}

# Clone repository
try {
    Write-Host "Cloning repository..." -ForegroundColor Gray
    git clone $repoUrl $tempDir 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone repository"
    }
    
    Write-Host "✓ Repository cloned successfully" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to clone repository!" -ForegroundColor Red
    Write-Host "Please check:" -ForegroundColor Yellow
    Write-Host "  1. Repository exists: https://github.com/ricklxf/Remoter" -ForegroundColor Yellow
    Write-Host "  2. You have proper access rights" -ForegroundColor Yellow
    Write-Host "  3. Git credentials are configured" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "Step 2: Copy Remoter-Win files" -ForegroundColor Yellow
Write-Host ""

# Create target folder if not exists
$targetPath = Join-Path $tempDir $targetFolder
if (-not (Test-Path $targetPath)) {
    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
}

# Copy files (excluding .git, bin, obj, etc.)
Write-Host "Copying files..." -ForegroundColor Gray

$excludeDirs = @('.git', 'bin', 'obj', 'publish', '.vs', '.vscode')
$excludeFiles = @('.gitignore')

Get-ChildItem -Path $currentDir -File | Where-Object {
    $_.Name -notin $excludeFiles
} | Copy-Item -Destination $targetPath -Force

Get-ChildItem -Path $currentDir -Directory | Where-Object {
    $_.Name -notin $excludeDirs
} | ForEach-Object {
    $destDir = Join-Path $targetPath $_.Name
    Copy-Item -Path $_.FullName -Destination $destDir -Recurse -Force
}

# Copy .gitignore
Copy-Item -Path (Join-Path $currentDir ".gitignore") -Destination $targetPath -Force

Write-Host "✓ Files copied successfully" -ForegroundColor Green
Write-Host ""

Write-Host "Step 3: Commit and push changes" -ForegroundColor Yellow
Write-Host ""

# Change to temp directory
Set-Location $tempDir

# Check if there are changes
$status = git status --porcelain

if ([string]::IsNullOrEmpty($status)) {
    Write-Host "No changes to commit." -ForegroundColor Yellow
}
else {
    # Add files
    Write-Host "Adding files to git..." -ForegroundColor Gray
    git add $targetFolder/
    
    # Commit
    Write-Host "Committing changes..." -ForegroundColor Gray
    $commitMsg = "Add/Update Remoter-Win: Windows remote desktop service"
    git commit -m $commitMsg
    
    Write-Host "✓ Changes committed" -ForegroundColor Green
    Write-Host ""
    
    # Push
    Write-Host "Step 4: Push to GitHub" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Pushing to origin main..." -ForegroundColor Gray
    git push origin main 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Push to main failed, trying master..." -ForegroundColor Yellow
        git push origin master 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Push failed!" -ForegroundColor Red
            Write-Host "You may need to:" -ForegroundColor Yellow
            Write-Host "  1. Pull first: git pull origin main --rebase" -ForegroundColor Yellow
            Write-Host "  2. Resolve conflicts" -ForegroundColor Yellow
            Write-Host "  3. Push again" -ForegroundColor Yellow
            Set-Location $currentDir
            Read-Host "Press Enter to exit"
            exit 1
        }
    }
    
    Write-Host "✓ Changes pushed to GitHub successfully" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Sync completed!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Check the repository on GitHub" -ForegroundColor Yellow
Write-Host "  2. Verify Remoter-Win folder is created" -ForegroundColor Yellow
Write-Host "  3. Other folders should NOT be affected" -ForegroundColor Yellow
Write-Host ""

# Restore original directory
Set-Location $currentDir

Read-Host "Press Enter to exit"
