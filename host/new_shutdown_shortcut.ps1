# ==============================================================================
# Tytul:        new_shutdown_shortcut.ps1
# Opis:         Tworzy na pulpicie skrot "LAB GG RAC - wylacz": okno pwsh 7 pokazuje podglad
#               (lab.cmd shutdown -DryRun), pyta o potwierdzenie i dopiero po "tak" wylacza lab
#               (lab.cmd shutdown). Okno zostaje otwarte po zakonczeniu (raport krokow).
# Description [EN]: Creates the desktop shortcut "LAB GG RAC - wylacz": a pwsh 7 window shows the
#               preview (lab.cmd shutdown -DryRun), asks for confirmation and only after "tak"
#               shuts the lab down (lab.cmd shutdown). The window stays open afterwards (step report).
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - Windows, PowerShell 7 (pwsh w PATH), lab.cmd w katalogu repo
# Requirements [EN]: - Windows, PowerShell 7 (pwsh on PATH), lab.cmd in the repo directory
#
# Uzycie [PL]:       pwsh -File host\new_shutdown_shortcut.ps1 [-RepoRoot <katalog repo>] [-DryRun]
# Usage [EN]:        pwsh -File host\new_shutdown_shortcut.ps1 [-RepoRoot <repo dir>] [-DryRun]
# ==============================================================================
[CmdletBinding()]
param(
    # Katalog repo, na ktory wskazuje skrot (domyslnie rodzic host\) / repo directory the shortcut points to
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Name = 'LAB GG RAC - wyłącz',
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path $RepoRoot).Path
$labCmd = Join-Path $RepoRoot 'lab.cmd'
if (-not (Test-Path $labCmd)) { throw "lab.cmd not found in $RepoRoot" }
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$Name.lnk"

# Podglad, potwierdzenie, wylaczenie; -NoExit zostawia okno z raportem / preview, confirm, shut down; -NoExit keeps the report
$cmd = "& '$labCmd' shutdown -DryRun; " +
       "if ((Read-Host 'Wylaczyc lab w tej kolejnosci? Wpisz tak') -eq 'tak') { & '$labCmd' shutdown } else { 'Anulowane / cancelled' }"
$argLine = "-NoProfile -NoExit -ExecutionPolicy Bypass -Command `"$cmd`""

if ($DryRun) { "DRYRUN shortcut $lnk -> $pwsh $argLine (cwd $RepoRoot)"; return }
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = $pwsh
$s.Arguments = $argLine
$s.WorkingDirectory = $RepoRoot
$s.IconLocation = "$env:SystemRoot\System32\shell32.dll,27"
$s.Description = 'lab gg-rac26ai: uporzadkowane wylaczenie (lab.cmd shutdown)'
$s.Save()
"OK shortcut: $lnk"
