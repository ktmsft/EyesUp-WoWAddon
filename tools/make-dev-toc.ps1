<#
    make-dev-toc.ps1 — regenerate the gitignored dev loader (EyesUpDev.toc) from EyesUp.toc.

    This dev checkout lives in a codename folder "EyesUpDev" so a live CurseForge "EyesUp"
    install can sit beside it without clobbering it. WoW requires the .toc filename to match
    the folder, so the folder needs EyesUpDev.toc. It is the shipped EyesUp.toc with three
    changes, so the dev copy is unmistakable and its saved data never touches a live profile:
      * Title                       -> "Eyes Up [DEV]"
      * SavedVariables              -> EyesUpDevAccountDB
      * SavedVariablesPerCharacter  -> EyesUpDevDB
    Core.lua switches to the EyesUpDev* files when it sees "[DEV]" in the Title.

    Only ONE of the two copies should be enabled at a time. Run after editing EyesUp.toc:
      pwsh tools/make-dev-toc.ps1
#>

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$out  = Get-Content (Join-Path $repo 'EyesUp.toc') | ForEach-Object {
    $_ -replace '^## Title: Eyes Up\s*$', '## Title: Eyes Up [DEV]' `
       -replace '^## SavedVariables: EyesUpAccountDB\s*$', '## SavedVariables: EyesUpDevAccountDB' `
       -replace '^## SavedVariablesPerCharacter: EyesUpDB\s*$', '## SavedVariablesPerCharacter: EyesUpDevDB'
}
Set-Content -Path (Join-Path $repo 'EyesUpDev.toc') -Value $out -Encoding utf8
Write-Host 'Wrote EyesUpDev.toc  (dev loader: "Eyes Up [DEV]", EyesUpDev* saved variables)'
