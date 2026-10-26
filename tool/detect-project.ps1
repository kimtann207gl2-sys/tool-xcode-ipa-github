# Scan Xcode-Input/*.zip and write tool/build-config.json for CI.
param(
    [string]$InputDir = "Xcode-Input",
    [string]$OutputConfig = "tool/build-config.json",
    [string]$XcodeZipPath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ZipTextEntry {
    param([System.IO.Compression.ZipArchive]$Zip, [string]$Pattern)
    foreach ($entry in $Zip.Entries) {
        if ($entry.FullName -match $Pattern) {
            $stream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($stream)
                return @{ Path = $entry.FullName; Text = $reader.ReadToEnd() }
            } finally {
                $reader.Dispose()
                $stream.Dispose()
            }
        }
    }
    return $null
}

if ($XcodeZipPath) {
    if (Test-Path -LiteralPath $XcodeZipPath) {
        $zipItem = Get-Item -LiteralPath $XcodeZipPath
    } else {
        $candidate = Join-Path $InputDir $XcodeZipPath
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Zip not found: $XcodeZipPath"
        }
        $zipItem = Get-Item -LiteralPath $candidate
    }
} else {
    $zipFiles = @(Get-ChildItem -Path $InputDir -Filter "*.zip" -File | Sort-Object LastWriteTime -Descending)
    if ($zipFiles.Count -eq 0) {
        throw "No .zip found in $InputDir. Place your Xcode export zip there first."
    }
    $zipItem = $zipFiles[0]
}
if (-not $zipItem -or -not $zipItem.FullName) {
    throw "Invalid zip file reference."
}
Write-Host "[detect] Using zip: $($zipItem.Name)"

$zip = [System.IO.Compression.ZipFile]::OpenRead($zipItem.FullName)
try {
    $pbxEntry = Get-ZipTextEntry -Zip $zip -Pattern "\.xcodeproj/project\.pbxproj$"
    if (-not $pbxEntry) { throw "No .xcodeproj/project.pbxproj found inside zip." }

    $pbxRel = $pbxEntry.Path -replace "/", [IO.Path]::DirectorySeparatorChar
    $xcodeProject = Split-Path (Split-Path $pbxRel -Parent) -Leaf
    $innerRoot = ($pbxEntry.Path -split "/")[0]

    $pbxText = $pbxEntry.Text
    $appName = "App.app"
    if ($pbxText -match 'PRODUCT_NAME_APP\s*=\s*([^;]+);') {
        $appName = ($Matches[1].Trim().Trim('"') -replace '\s', '') + ".app"
    } elseif ($pbxText -match 'PRODUCT_NAME\s*=\s*"?([^";\s]+)"?;') {
        $appName = ($Matches[1].Trim().Trim('"') -replace '\$\([^)]+\)', 'App') + ".app"
    }

    $bundleId = "com.example.app"
    if ($pbxText -match 'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);') {
        $bundleId = $Matches[1].Trim().Trim('"')
    }

    $scheme = "Unity-iPhone"
    $schemeEntry = Get-ZipTextEntry -Zip $zip -Pattern "xcshareddata/xcschemes/[^/]+\.xcscheme$"
    if ($schemeEntry) {
        $schemeFile = [IO.Path]::GetFileNameWithoutExtension((Split-Path $schemeEntry.Path -Leaf))
        if ($schemeFile) { $scheme = $schemeFile }
    }

    $baseName = [IO.Path]::GetFileNameWithoutExtension($appName)
    $artifactName = "$baseName-ipa"

    $rootPath = (Get-Location).Path.TrimEnd('\')
    $fullZip = $zipItem.FullName
    if ($fullZip.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        $zipRel = $fullZip.Substring($rootPath.Length).TrimStart('\', '/')
    } else {
        $zipRel = "$InputDir/$($zipItem.Name)"
    }
    $zipRel = ($zipRel -replace "\\", "/")

    $config = [ordered]@{
        xcodeZip      = $zipRel
        xcodeSrc      = "$InputDir/extracted/$innerRoot" -replace "\\", "/"
        xcodeProject  = $xcodeProject
        scheme        = $scheme
        appName       = $appName
        outputIpa     = "$baseName.ipa"
        artifactName  = $artifactName
        bundleId      = $bundleId
        detectedAt    = (Get-Date).ToString("o")
    }
} finally {
    $zip.Dispose()
}

$outDir = Split-Path $OutputConfig -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$json = $config | ConvertTo-Json -Depth 3
$outPath = Join-Path (Get-Location) $OutputConfig
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)

Write-Host "[detect] xcodeProject : $($config.xcodeProject)"
Write-Host "[detect] scheme       : $($config.scheme)"
Write-Host "[detect] appName        : $($config.appName)"
Write-Host "[detect] bundleId       : $($config.bundleId)"
Write-Host "[detect] config saved   : $OutputConfig"
