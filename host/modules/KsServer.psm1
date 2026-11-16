# ==============================================================================
# Tytul:        KsServer.psm1
# Opis:         Uruchamia i zatrzymuje maly serwer HTTP (host/ks_server.py), z ktorego
#               instalator Linuksa pobiera kickstart. Serwer dziala tylko w czasie
#               'build'. Sprzatanie osieroconych serwerow wylacznie tego labu (po pelnej
#               sciezce), zeby nie zabic serwera innego, rownolegle budowanego labu.
# Description [EN]: Starts and stops the small HTTP server (host/ks_server.py) the Linux
#               installer downloads its kickstart from. Runs only during 'build'. Reaps
#               orphans of THIS lab only (by full path), never another lab's server.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       3.1 (log na ekranie: sama nazwa pliku / log on screen: file name only)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, Python 3.8+ na hoscie, regula zapory TCP (lab.cmd firewall)
# Requirements [EN]: - PowerShell 7, Python 3.8+ on the host, firewall rule (lab.cmd firewall)
#
# Uzycie [PL]:       Start-KsServer -RepoRoot <repo> -LabName gitlab-lab -BindIp 192.168.56.1 -Port 8000
#                    Stop-KsServer -LabName gitlab-lab
# Usage [EN]:        same as above
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

function Get-KsFile([string]$LabName, [string]$Suffix) { Join-Path $env:TEMP "vbox-lab-$LabName-ks.$Suffix" }

function Find-PythonExe {
    # Pomija atrape python.exe ze Sklepu Windows (WindowsApps): istnieje, ale nie uruchamia Pythona.
    # Skips the Microsoft Store python.exe stub (WindowsApps): it exists but does not run Python.
    [CmdletBinding()]
    param()
    foreach ($name in @('python.exe', 'python3.exe', 'py.exe')) {
        foreach ($c in @(Get-Command $name -All -ErrorAction SilentlyContinue)) {
            if ($c.Source -match 'WindowsApps') { continue }
            $prefix = if ($name -eq 'py.exe') { @('-3') } else { @() }
            return @{ Exe = $c.Source; Prefix = $prefix }
        }
    }
    throw 'Brak Pythona 3. Zainstaluj: winget install --id Python.Python.3.12 -e  (potem NOWE okno)'
}

function Test-KsServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BindIp, [Parameter(Mandatory)][int]$Port)
    try {
        $r = Invoke-WebRequest -Uri "http://${BindIp}:${Port}/kickstart/health.txt" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Stop-KsServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LabName)
    $pidFile = Get-KsFile $LabName 'pid'
    if (-not (Test-Path $pidFile)) { return }
    $id = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($id) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        # Sprawdzamy polecenie, bo numer PID mogl juz dostac inny proces.
        # Check the command line: the PID may have been reused by another process.
        if ($p -and $p.CommandLine -match 'ks_server\.py') {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            Write-Ok "Serwer kickstart zatrzymany / stopped (PID $id)"
        }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

function Start-KsServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$LabName,
        [Parameter(Mandatory)][string]$BindIp,
        [Parameter(Mandatory)][int]$Port
    )
    $serverScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\ks_server.py'))

    # Sieroty TEGO labu z przerwanego builda: rozpoznanie po pelnej sciezce serwera.
    # Orphans of THIS lab from an aborted build: matched by the server's full path.
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='python3.exe' OR Name='py.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($serverScript) } |
        ForEach-Object {
            Write-Log -Level Warn -Message "Zamykam stary serwer tego labu (PID $($_.ProcessId))"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

    $py = Find-PythonExe
    $logOut = Get-KsFile $LabName 'out.log'
    $logErr = Get-KsFile $LabName 'err.log'
    # Na ekran sama nazwa (film: bez sciezki z katalogu uzytkownika); plik lezy w %TEMP%
    # Screen shows the name only (film: no user profile path); the file is in %TEMP%
    $logName = Split-Path -Leaf $logErr
    $argLine = (@($py.Prefix) + @(('"{0}"' -f $serverScript), ('"{0}"' -f $RepoRoot), $BindIp, "$Port")) -join ' '
    Write-Step "Serwer kickstart / KS server: http://${BindIp}:${Port}/"
    $proc = Start-Process -FilePath $py.Exe -ArgumentList $argLine -WorkingDirectory $RepoRoot `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $logOut -RedirectStandardError $logErr
    $proc.Id | Out-File -FilePath (Get-KsFile $LabName 'pid') -Encoding ascii -Force

    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            throw "Serwer KS zakonczyl sie od razu (kod $($proc.ExitCode)): $(Get-Content $logErr -Raw -ErrorAction SilentlyContinue)"
        }
        if (Test-KsServer -BindIp $BindIp -Port $Port) {
            Write-Ok "Serwer dziala / running, PID $($proc.Id) (log: $logName)"
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Serwer KS nie odpowiada na http://${BindIp}:${Port}/ w 12 s. Log: $logName (TEMP)"
}

Export-ModuleMember -Function 'Find-PythonExe', 'Start-KsServer', 'Stop-KsServer', 'Test-KsServer'
