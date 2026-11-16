@echo off
rem ==============================================================================
rem Tytul:        lab.cmd
rem Opis:         Starter lab.ps1: sprawdza PowerShell 7 (pwsh) i uruchamia lab.ps1 z
rem               -ExecutionPolicy Bypass tylko dla tego procesu (bez zmian w systemie).
rem Description [EN]: lab.ps1 launcher: checks for PowerShell 7 (pwsh) and runs lab.ps1
rem               with -ExecutionPolicy Bypass for this process only (no system change).
rem
rem Autor:        KCB Kris
rem Data:         2026-10-27
rem Wersja:       1.0
rem Konwencje:    <repo>/SETTINGS.md
rem
rem Uzycie [PL]:       lab.cmd plan  |  lab.cmd all  (te same argumenty co lab.ps1)
rem Usage [EN]:        lab.cmd plan  |  lab.cmd all  (same arguments as lab.ps1)
rem ==============================================================================
where pwsh >nul 2>nul
if errorlevel 1 (
    echo [PL] Brak PowerShell 7 ^(pwsh^). Windows PowerShell 5.1 nie uruchomi lab.ps1.
    echo      Zainstaluj:  winget install --id Microsoft.PowerShell -e
    echo      potem otworz NOWE okno i uruchom ponownie lab.cmd.
    echo [EN] PowerShell 7 ^(pwsh^) not found. Install it with the winget command above.
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0lab.ps1" %*
exit /b %errorlevel%
