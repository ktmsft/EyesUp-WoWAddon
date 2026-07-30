<#
    build.ps1 — package Eyes Up into a distributable zip for CurseForge.

    Produces dist/EyesUp-<version>.zip with a single top-level "EyesUp" folder (the folder
    name MUST match EyesUp.toc), even though this dev checkout lives in the codename folder
    "EyesUpDev". Ships only what the game loads plus LICENSE/README, and leaves out dev-only
    material (.git, tools/, the gitignored EyesUpDev.toc dev loader) and source art (.png,
    which WoW can't load — it reads only .tga/.blp).

    Usage:  powershell -File tools/build.ps1     (Windows PowerShell 5.1 or pwsh 7, either)
#>
# NOT Compress-Archive. Windows PowerShell 5.1's version writes entry names with
# BACKSLASH separators -- "EyesUp\Core.lua" -- which the zip spec doesn't allow
# (APPNOTE 4.4.17.1 says forward slash). Explorer forgives it, so the zip looks fine
# when you double-click it; unzippers that follow the spec don't, and read the whole
# archive as a pile of oddly-named files in the root with no EyesUp/ folder at all.
# That's a broken upload that looks correct locally. pwsh 7 fixed it, which is why
# this used to say pwsh -- but a build that silently produces a bad zip when run the
# obvious way is a trap. ZipFile does it right on both.

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
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $zip) { Remove-Item $zip -Force }

# Entry names written by hand, because BOTH of the obvious helpers get this wrong on
# Windows PowerShell 5.1: Compress-Archive and ZipFile::CreateFromDirectory each use
# the platform separator, so both produce "EyesUp\Core.lua". .NET Core fixed it and
# .NET Framework never did. Naming the entries ourselves is the only version-proof
# answer -- and it's three lines.
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    Get-ChildItem -LiteralPath $staging -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel  = $_.FullName.Substring($staging.Length).TrimStart('\', '/')
        $name = "$folder/" + ($rel -replace '\\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $_.FullName, $name, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $archive.Dispose() }

# Say it out loud rather than trusting the line above. A zip with backslash entries
# is the failure this build has already had once, and it is invisible until CurseForge
# rejects it.
$check = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $bad = @($check.Entries | Where-Object { $_.FullName -match '\\' })
    $root = @($check.Entries | ForEach-Object { $_.FullName.Split('/')[0] } | Sort-Object -Unique)
} finally { $check.Dispose() }
if ($bad.Count)   { throw "Zip has $($bad.Count) backslash entry name(s), e.g. $($bad[0].FullName)" }
if ($root -ne $folder) { throw "Zip root should be exactly '$folder/', got: $($root -join ', ')" }
$count = (Get-ChildItem $staging -Recurse -File).Count
$size  = '{0:N0} KB' -f ((Get-Item $zip).Length / 1KB)
Write-Host "Wrote $zip  ($count files, $size)"
Write-Host "Top-level entry in the zip: $folder/  (drop into Interface/AddOns)"
