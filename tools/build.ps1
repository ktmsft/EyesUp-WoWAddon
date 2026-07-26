<#
    build.ps1 — package Eyes Up into a distributable zip for CurseForge.

    Produces dist/EyesUp-<version>.zip with a single top-level "EyesUp" folder (the folder
    name MUST match EyesUp.toc), even though this dev checkout lives in the codename folder
    "EyesUpDev". Ships only what the game loads plus LICENSE/README, and leaves out dev-only
    material (.git, tools/, the gitignored EyesUpDev.toc dev loader) and source art (.png,
    which WoW can't load — it reads only .tga/.blp).

    Usage:  pwsh tools/build.ps1
#>

$ErrorActionPreference = 'Stop'
$repo    = Split-Path -Parent $PSScriptRoot          # tools/ -> repo root (EyesUpDev)
$folder  = 'EyesUp'                                  # shipped addon folder name (matches the .toc)
$dist    = Join-Path $repo 'dist'
$staging = Join-Path $dist $folder

$toc     = Get-Content (Join-Path $repo 'EyesUp.toc')
$version = ($toc | Select-String -Pattern '^##\s*Version:\s*(.+?)\s*$').Matches[0].Groups[1].Value
if (-not $version) { throw 'Could not read ## Version from EyesUp.toc' }

# Never shipped to players.
$exclude = @('.git', '.gitignore', 'dist', 'tools', 'tests', 'EyesUpDev.toc')

Write-Host "Building Eyes Up $version ..."
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null

Get-ChildItem -LiteralPath $repo -Force |
    Where-Object { $exclude -notcontains $_.Name } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $staging -Recurse -Force }

# Strip source art the game can't load.
Get-ChildItem -LiteralPath $staging -Filter *.png -File -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

$zip = Join-Path $dist ("EyesUp-$version.zip")
Compress-Archive -Path $staging -DestinationPath $zip -Force
$count = (Get-ChildItem $staging -Recurse -File).Count
$size  = '{0:N0} KB' -f ((Get-Item $zip).Length / 1KB)
Write-Host "Wrote $zip  ($count files, $size)"
Write-Host "Top-level entry in the zip: $folder/  (drop into Interface/AddOns)"
