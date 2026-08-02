<#
.SYNOPSIS
    Package a World of Warcraft addon in the current folder into a clean,
    CurseForge-ready .zip -- without .git or other dev clutter.

.DESCRIPTION
    * Reads files from the current directory (or -SourceDir).
    * Detects the addon name from the .toc file (used for the output
      filename only -- the zip has no wrapper folder, files sit at its root).
    * Skips .git, .github, build output, editor folders, and other junk.
    * Writes  build\AddonName.zip
    * Re-opens the finished zip and confirms no .git slipped in.

.EXAMPLE
    .\Build-Addon.ps1
.EXAMPLE
    .\Build-Addon.ps1 -AddonName ColdCaller
#>

[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$AddonName
)

$ErrorActionPreference = 'Stop'

# Where's the addon? By default, the folder ONE LEVEL UP from this script,
# i.e. the repo root when this script lives in <repo>\utils\.
# Pass -SourceDir to override, or set it to $PSScriptRoot if you ever move the
# script back into the addon's own root folder.
if (-not $SourceDir) {
    if ($PSScriptRoot) {
        $SourceDir = Split-Path -Parent $PSScriptRoot
    } else {
        $SourceDir = (Get-Location).Path
    }
}

# ---- edit these to taste --------------------------------------------------
# Folder names skipped anywhere in the tree:
$ExcludeDirs = @('.git', '.github', '.vs', '.vscode', '.idea',
                 'build', '.release', 'node_modules', 'utils')

# File name patterns skipped anywhere in the tree (wildcards allowed):
$ExcludeFilePatterns = @(
    '.gitignore', '.gitattributes', '.gitmodules', '.pkgmeta', '.editorconfig',
    '*.zip', '*.7z', '*.rar',
    '*.ps1', '*.bat', '*.cmd', '*.sh',
    '*.md',
    '.DS_Store', 'Thumbs.db', 'desktop.ini'
)
# ---------------------------------------------------------------------------

$SourceDir = (Resolve-Path -LiteralPath $SourceDir).Path
Write-Host "Source folder : $SourceDir" -ForegroundColor Cyan

# --- work out the addon (= zip top-level folder) name from the .toc ---------
if (-not $AddonName) {
    $tocFiles = Get-ChildItem -LiteralPath $SourceDir -Filter '*.toc' -File
    if (-not $tocFiles) {
        Write-Host "ERROR: no .toc file found here." -ForegroundColor Red
        Write-Host "Run this from your addon's root folder (the one holding the .toc)." -ForegroundColor Red
        exit 1
    }
    # strip flavor suffixes (ColdCaller_Vanilla.toc -> ColdCaller) for multi-TOC
    $AddonName = $tocFiles |
        ForEach-Object {
            $_.BaseName -replace '[-_](Mainline|Standard|Vanilla|Classic|Cata|Wrath|WOTLKC|TBC|BCC)$',''
        } |
        Sort-Object -Unique |
        Select-Object -First 1
}
Write-Host "Addon name    : $AddonName" -ForegroundColor Cyan

# --- decide which files to include -----------------------------------------
function Test-Excluded {
    param([string]$FullPath, [string]$Name)

    $rel = $FullPath.Substring($SourceDir.Length).TrimStart('\', '/')
    $segments = $rel -split '[\\/]'

    # any parent folder in the exclude list? (check all but the file itself)
    if ($segments.Length -gt 1) {
        foreach ($seg in $segments[0..($segments.Length - 2)]) {
            if ($ExcludeDirs -contains $seg) { return $true }
        }
    }
    # file name matches an excluded pattern?
    foreach ($pat in $ExcludeFilePatterns) {
        if ($Name -like $pat) { return $true }
    }
    return $false
}

$included = Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force |
    Where-Object { -not (Test-Excluded -FullPath $_.FullName -Name $_.Name) }

if (-not $included) {
    Write-Host "ERROR: nothing left to package after exclusions." -ForegroundColor Red
    exit 1
}

# --- stage into a temp folder named exactly like the addon ------------------
$stageRoot  = Join-Path ([System.IO.Path]::GetTempPath()) ("addonbuild_" + [guid]::NewGuid().ToString('N'))
$stageAddon = Join-Path $stageRoot $AddonName
New-Item -ItemType Directory -Force -Path $stageAddon | Out-Null

foreach ($f in $included) {
    $rel     = $f.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
    $dest    = Join-Path $stageAddon $rel
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
}

# --- zip it (includeBaseDirectory = false -> files sit at the zip root, no
#     wrapper "AddonName/" folder inside) -------------------------------------
$buildDir = Join-Path $SourceDir 'build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$zipPath = Join-Path $buildDir ("{0}.zip" -f $AddonName)
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

if (-not ([System.Management.Automation.PSTypeName]'System.IO.Compression.ZipFile').Type) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stageAddon,
    $zipPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

Remove-Item -LiteralPath $stageRoot -Recurse -Force

# --- verify the result ------------------------------------------------------
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names   = $zip.Entries | ForEach-Object { $_.FullName }
    $gitHits = $names | Where-Object { $_ -match '(^|/)\.git(/|$)' }
    $tocHits = $names | Where-Object { $_ -match '\.toc$' }
}
finally {
    $zip.Dispose()
}

Write-Host ""
Write-Host ("Packaged {0} file(s)" -f $included.Count) -ForegroundColor Green
Write-Host ("Output        : {0}" -f $zipPath)          -ForegroundColor Green
Write-Host "Layout        : files at zip root (no wrapper folder)" -ForegroundColor Green

if ($gitHits) {
    Write-Host "WARNING: .git entries are STILL in the zip:" -ForegroundColor Red
    $gitHits | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}
else {
    Write-Host "Clean         : no .git entries." -ForegroundColor Green
}

if (-not $tocHits) {
    Write-Host "WARNING: no .toc inside the zip -- double-check the folder." -ForegroundColor Yellow
}