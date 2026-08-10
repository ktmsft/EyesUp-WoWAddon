<#
    make-dev-toc.ps1 — regenerate the gitignored dev loader (EyesUpDev.toc) from EyesUp.toc.

    This dev checkout lives in a codename folder "EyesUpDev" so a live CurseForge "EyesUp"
    install can sit beside it without clobbering it. WoW requires the .toc filename to match
    the folder, so the folder needs EyesUpDev.toc. It is the shipped EyesUp.toc with four
    changes, so the dev copy is unmistakable and its saved data never touches a live profile:
      * Title                       -> "Eyes Up [DEV]"
      * SavedVariables              -> EyesUpDevAccountDB
      * SavedVariablesPerCharacter  -> EyesUpDevDB
      * IconTexture                 -> ...\AddOns\EyesUpDev\...
    Core.lua switches to the EyesUpDev* files when it sees "[DEV]" in the Title.

    The icon path is the one thing here that can't be computed at load the way our Lua
    texture paths are — a .toc header is read before any of our code runs. Left pointing at
    "AddOns\EyesUp\" it resolves to the LIVE install's folder: the wrong art if one is
    installed, and a blank tile if one isn't.

    Only ONE of the two copies should be enabled at a time. Run after editing EyesUp.toc:
      pwsh tools/make-dev-toc.ps1
#>

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$out  = Get-Content (Join-Path $repo 'EyesUp.toc') | ForEach-Object {
    $_ -replace '^## Title: Eyes Up\s*$', '## Title: Eyes Up [DEV]' `
       -replace '^## SavedVariables: EyesUpAccountDB\s*$', '## SavedVariables: EyesUpDevAccountDB' `
       -replace '^## SavedVariablesPerCharacter: EyesUpDB\s*$', '## SavedVariablesPerCharacter: EyesUpDevDB' `
       -replace '^(## IconTexture: Interface\\AddOns\\)EyesUp(\\.*)$', '${1}EyesUpDev${2}'
}
Set-Content -Path (Join-Path $repo 'EyesUpDev.toc') -Value $out -Encoding utf8
Write-Host 'Wrote EyesUpDev.toc  (dev loader: "Eyes Up [DEV]", EyesUpDev* saved variables)'
