<#
  make-dev-toc.ps1 - regenerate the gitignored dev loader from the shipped .toc.

  This dev checkout lives in a codename folder "<Name>Dev" so a live "<Name>" install can sit
  beside it. WoW needs the .toc name to match the folder, so the folder needs <Name>Dev.toc:
  the shipped <Name>.toc with a "[DEV]" Title and Dev-named SavedVariables (Core switches to
  them when the Title has "[DEV]"). Only ONE copy enabled at a time.
  Run after editing the shipped .toc:  pwsh tools/make-dev-toc.ps1

  ENCODING, which gets this wrong quietly. Windows PowerShell's Get-Content defaults to the
  system ANSI codepage, so a UTF-8 em dash comes back as three Latin-1 characters and is
  written out re-encoded -- the Notes line then reads "a€"" in the AddOns list. And
  Set-Content -Encoding utf8 adds a BOM, which is the worse half: a BOM sits BEFORE line 1,
  so "## Interface:" stops parsing as a directive and the dev entry declares no interface
  version at all. The file still reads fine to a human, which is why it hid for a release
  elsewhere. So: read as UTF-8 explicitly, write with no BOM. Check with
      head -c 3 <Codename>.toc | xxd     ->  efbbbf means this went wrong.

  THE SAVED-VARIABLE NAMES ARE THE PART TO GET RIGHT, and the shared version of this script
  gets them wrong here. CueTip's copy suffixes 'DB$' -> 'DevDB', which turns EyesUpAccountDB
  into EyesUpAccountDevDB. Core.lua looks for EyesUpDevAccountDB, so the two never meet: the
  toc declares a global nothing reads, Core's global is never saved, and the dev profile
  quietly stops persisting. Nothing errors.

  So the rule here is "swap the leading ship name for the codename", which gives
  EyesUpAccountDB -> EyesUpDevAccountDB and EyesUpDB -> EyesUpDevDB. A name that does NOT
  start with the ship name -- a legacy table kept declared through a rename -- falls back to
  the suffix rule, because there's no prefix to swap. Both are handled; neither is guessed.

  And EVERY name on the line, not just a lone one: a migration keeps the previous name
  declared alongside the current one, and a loader that suffixed only the first would leave
  the DEV build reading and writing a LIVE table.
#>

$repo      = Split-Path -Parent $PSScriptRoot
$codename  = Split-Path -Leaf $repo
$shipName  = $codename -replace 'Dev$',''
$shipToc   = $shipName + '.toc'
$ourFolder = 'Interface\AddOns\'

function Convert-DevName([string]$name) {
    if ($name.StartsWith($shipName)) { return $codename + $name.Substring($shipName.Length) }
    return ($name -replace 'DB$','DevDB')
}

$out = Get-Content (Join-Path $repo $shipToc) -Encoding UTF8 | ForEach-Object {
    $line = $_ -replace '^(## Title: .+?)\s*$', '${1} [DEV]'

    # Any path into our own folder has to point at THIS folder. A line still reading
    # Interface\AddOns\<Name>\... resolves against the LIVE install whenever one is
    # present -- so the dev build would quietly wear the live build's art and look
    # perfectly correct while testing nothing. A .toc header is read before any of our
    # Lua runs, so unlike our texture paths this one cannot be computed at load.
    $line = $line.Replace($ourFolder + $shipName + '\', $ourFolder + $codename + '\')

    if ($line -match '^(## SavedVariables(?:PerCharacter)?: )(.+?)\s*$') {
        $prefix = $Matches[1]
        $names  = @($Matches[2] -split ',' | ForEach-Object { Convert-DevName $_.Trim() })
        $line   = $prefix + ($names -join ', ')
    }
    $line
}

# Absolute path, always. Set-Location does not move .NET's working directory, so a bare
# relative name here resolves against wherever the shell started -- which has silently
# rewritten the wrong project's .toc before.
$noBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines((Join-Path $repo ($codename + '.toc')), $out, $noBom)
Write-Host ("Wrote " + $codename + ".toc  (dev loader: [DEV] title + Dev saved variables)")
