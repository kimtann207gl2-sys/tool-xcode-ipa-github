# One-click: Xcode zip in Xcode-Input -> GitHub Release + Actions -> IPA in Xcode-Output
# Zip is uploaded via Release (avoids Git LFS quota). CI downloads it with gh + GITHUB_TOKEN.
param(
    [switch]$UploadAppStore,
    [switch]$SkipPush,
    [switch]$Setup
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
Set-Location $Root
$env:GIT_LFS_SKIP_PUSH = "1"

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing '$Name'. Install it and ensure it is on PATH."
    }
}

function Write-Step($Msg) {
    Write-Host ""
    Write-Host "==> $Msg" -ForegroundColor Cyan
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string[]]$ArgList,
        [string]$FailMessage = $null
    )
    # Avoid PowerShell treating native stderr as terminating errors.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $File @ArgList
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        if (-not $FailMessage) { $FailMessage = "$File failed with exit code $code" }
        throw $FailMessage
    }
}

function Get-SafeReleaseTag([string]$ZipName) {
    $base = [IO.Path]::GetFileNameWithoutExtension($ZipName).ToLowerInvariant()
    $base = $base -replace '[^a-z0-9\-]+', '-'
    $base = $base.Trim('-')
    if (-not $base) { $base = "xcode" }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return "build-$base-$stamp"
}

if ($Setup) {
    Write-Step "Initial setup"
    Require-Command git
    Require-Command gh
    git init 2>$null
    Write-Host "Done. Next:"
    Write-Host "  1. gh auth login"
    Write-Host "  2. gh repo create tool-xcode-ipa-github --public --source . --remote origin --push"
    Write-Host "  3. Put Xcode zip into Xcode-Input\"
    Write-Host "  4. Double-click run.bat"
    exit 0
}

$cfgPath = Join-Path $Root "tool/config.json"
if (-not (Test-Path $cfgPath)) { throw "Missing tool/config.json" }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
if ($UploadAppStore) { $cfg.uploadAppStore = $true }

Write-Step "Detect Xcode project from zip"
& (Join-Path $Root "tool/detect-project.ps1")
$buildCfg = Get-Content "tool/build-config.json" -Raw | ConvertFrom-Json
$zipRel = $buildCfg.xcodeZip.Replace("/", [IO.Path]::DirectorySeparatorChar)
$zipPath = Join-Path $Root $zipRel
if (-not (Test-Path $zipPath)) { throw "Zip not found: $zipPath" }

Write-Step "Preflight checks"
Require-Command git
Require-Command gh

gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI not authenticated. Run: gh auth login" }

$remote = git remote get-url origin 2>$null
if (-not $remote) { throw "No git remote origin. Run: .\run.bat -Setup  then create/push repo." }

$who = gh api user --jq ".login" 2>$null
Write-Host "GitHub account : $who"
Write-Host "Remote         : $remote"
Write-Host "Zip            : $($buildCfg.xcodeZip)"
Write-Host "App            : $($buildCfg.appName) / $($buildCfg.bundleId)"

New-Item -ItemType Directory -Path "Xcode-Output" -Force | Out-Null

$runId = $null

if (-not $SkipPush) {
    Write-Step "Upload zip to GitHub Release"
    $repo = gh repo view --json nameWithOwner --jq ".nameWithOwner"
    $releaseTag = Get-SafeReleaseTag (Split-Path $zipPath -Leaf)
    $releaseTitle = "Build $($buildCfg.appName) $releaseTag"
    Write-Host "Creating release $releaseTag ..."
    Invoke-Native -File "gh" -ArgList @(
        "release", "create", $releaseTag,
        "--target", $cfg.branch,
        "--title", $releaseTitle,
        "--notes", "Xcode zip for CI IPA build",
        $zipPath
    ) -FailMessage "gh release create failed"

    $zipLeaf = Split-Path $zipPath -Leaf
    $zipUrl = "https://github.com/$repo/releases/download/$releaseTag/$zipLeaf"
    $buildCfg | Add-Member -NotePropertyName xcodeZipUrl -NotePropertyValue $zipUrl -Force
    $buildCfg | Add-Member -NotePropertyName xcodeZipRelease -NotePropertyValue $releaseTag -Force
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText(
        (Join-Path $Root "tool/build-config.json"),
        ($buildCfg | ConvertTo-Json -Depth 5),
        $utf8NoBom
    )
    Write-Host "Release URL: $zipUrl"

    Write-Step "Commit and push to GitHub ($($cfg.branch))"
    git add .gitattributes .gitignore .github scripts ci tool/build-config.json tool/config.json run.ps1 run.bat setup.bat 2>$null
    git add -u

    $zipName = Split-Path $buildCfg.xcodeZip -Leaf
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    $commitMsg = "build: $zipName $timestamp"
    $status = git status --porcelain
    if ($status) {
        Invoke-Native -File "git" -ArgList @("commit", "-m", $commitMsg) -FailMessage "git commit failed"
    } else {
        Write-Host "No file changes. Triggering workflow manually."
    }

    if ($cfg.uploadAppStore) {
        Invoke-Native -File "gh" -ArgList @("workflow", "run", $cfg.workflowFile, "--ref", $cfg.branch, "-f", "upload_appstore=true")
        Start-Sleep -Seconds 8
        $runId = gh run list --workflow $cfg.workflowFile --branch $cfg.branch --limit 1 --json databaseId --jq ".[0].databaseId"
    } else {
        Invoke-Native -File "git" -ArgList @("push", "origin", "HEAD:$($cfg.branch)") -FailMessage "git push failed"
        $commit = git rev-parse HEAD
        $short = $commit.Substring(0, 7)
        Write-Host "Waiting for workflow to start (commit $short)..."
        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds $cfg.pollIntervalSeconds
            $runId = gh run list --commit $commit --workflow $cfg.workflowFile --json databaseId --jq ".[0].databaseId" 2>$null
        } while (-not $runId -and (Get-Date) -lt $deadline)
        if (-not $runId) {
            $runId = gh run list --workflow $cfg.workflowFile --branch $cfg.branch --limit 1 --json databaseId --jq ".[0].databaseId"
        }
    }
} else {
    Write-Step "SkipPush - using latest workflow run"
    $runId = gh run list --workflow $cfg.workflowFile --branch $cfg.branch --limit 1 --json databaseId --jq ".[0].databaseId"
    $buildCfg = Get-Content "tool/build-config.json" -Raw | ConvertFrom-Json
}

if (-not $runId) { throw "Could not find a GitHub Actions run." }
Write-Host "Run ID: $runId"
Write-Host "Logs: $(gh run view $runId --json url --jq ".url")"

Write-Step "Waiting for build (max $($cfg.maxWaitMinutes) min)"
gh run watch $runId --exit-status --interval $cfg.pollIntervalSeconds
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Build FAILED. Fetching log tail:" -ForegroundColor Red
    gh run view $runId --log-failed 2>$null
    throw "GitHub Actions build failed."
}

Write-Step "Download IPA to Xcode-Output"
$dlDir = Join-Path $Root "Xcode-Output\_download"
if (Test-Path $dlDir) { Remove-Item $dlDir -Recurse -Force }
New-Item -ItemType Directory -Path $dlDir -Force | Out-Null

# Reload config in case it was updated
$buildCfg = Get-Content "tool/build-config.json" -Raw | ConvertFrom-Json
gh run download $runId --name $buildCfg.artifactName --dir $dlDir
if ($LASTEXITCODE -ne 0) {
    gh run download $runId --dir $dlDir
}

$ipaFiles = @(Get-ChildItem -Path $dlDir -Filter "*.ipa" -Recurse -File)
if ($ipaFiles.Count -eq 0) { throw "No .ipa found in downloaded artifacts." }

$dest = Join-Path $Root "Xcode-Output\$($buildCfg.outputIpa)"
Copy-Item $ipaFiles[0].FullName -Destination $dest -Force
Remove-Item $dlDir -Recurse -Force

Write-Host ""
Write-Host "SUCCESS" -ForegroundColor Green
Write-Host "  IPA : $dest"
Write-Host "  Size: $([math]::Round((Get-Item $dest).Length / 1MB, 2)) MB"
if ($cfg.unsignedBuild) {
    Write-Host ""
    Write-Host "IPA is UNSIGNED — user must re-sign before install:" -ForegroundColor Yellow
    Write-Host "  Sideloadly, AltStore, 3uTools, ESign (personal Apple ID / dev cert)"
}
