# ==============================================================================
# Tytul:        sampler.ps1
# Opis:         Jeden probkownik testu awarii: dlugie polaczenie SSH z guest/shared/probe.sh <tryb>,
#               kazdy wiersz dostaje czas hosta w chwili odbioru (UTC, ms) i trafia do pliku surowego.
#               Gdy wezel milknie (wylaczony, odciety), probkownik przechodzi na kolejny wezel z listy.
#               Konczy sie, gdy pojawi sie plik stopu.
# Description [EN]: One failure-test sampler: a long SSH connection to guest/shared/probe.sh <mode>;
#               every line gets the host time on receipt (UTC, ms) and goes to the raw file. When a
#               node goes silent (powered off, cut off) the sampler moves to the next node in the list.
#               Ends when the stop file appears.
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, OpenSSH z kluczem; uruchamia go tests/run_test.ps1
# Requirements [EN]: - PowerShell 7, OpenSSH with a key; started by tests/run_test.ps1
#
# Uzycie [PL]:       pwsh tests/sampler.ps1 -Mode crs -Nodes ggrac1=192.168.58.11,ggrac2=192.168.58.12 -OutFile x -StopFile y
# Usage [EN]:        pwsh tests/sampler.ps1 -Mode crs -Nodes name=ip,... -OutFile x -StopFile y [-IntervalSec 1]
# ==============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('crs', 'gg', 'lag')][string]$Mode,
    [Parameter(Mandatory)][string[]]$Nodes,
    [Parameter(Mandatory)][string]$OutFile,
    [Parameter(Mandatory)][string]$StopFile,
    [int]$IntervalSec = 1,
    [int]$SilenceSec = 6,
    [string]$KeyPath = (Join-Path $HOME '.ssh\id_ed25519')
)
Set-StrictMode -Version Latest
$inv = [Globalization.CultureInfo]::InvariantCulture
$enc = [Text.UTF8Encoding]::new($false)
$w = [IO.StreamWriter]::new($OutFile, $true, $enc)
$w.NewLine = "`n"; $w.AutoFlush = $true
function Out-Line([string]$Node, [string]$Line) {
    $w.WriteLine(('{0}{1}{2}{1}{3}' -f [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $inv), "`t", $Node, $Line))
}
# -File passes 'a=ip,b=ip' as one string: split it here
$targets = @(($Nodes -join ',') -split ',' | Where-Object { $_ } | ForEach-Object { $n, $ip = $_ -split '=', 2; [pscustomobject]@{ Name = $n; Ip = $ip } })
$i = 0
try {
    while (-not (Test-Path $StopFile)) {
        $t = $targets[$i % $targets.Count]
        $psi = [Diagnostics.ProcessStartInfo]::new('ssh')
        foreach ($a in '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                       '-o', 'ServerAliveInterval=2', '-o', 'ServerAliveCountMax=2', '-o', 'LogLevel=ERROR', '-i', $KeyPath,
                       "root@$($t.Ip)", "bash /root/lab/shared/probe.sh $Mode $IntervalSec") { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        Out-Line $t.Name "CONNECT $($t.Name)"
        $p = [Diagnostics.Process]::Start($psi)
        $read = $p.StandardOutput.ReadLineAsync()
        while (-not (Test-Path $StopFile)) {
            if ($read.Wait([TimeSpan]::FromSeconds($SilenceSec))) {
                if ($null -eq $read.Result) { break }          # connection closed
                Out-Line $t.Name $read.Result
                $read = $p.StandardOutput.ReadLineAsync()
            } else { Out-Line $t.Name "SILENT ${SilenceSec}s"; break }
        }
        if (-not $p.HasExited) { $p.Kill() }
        if (-not (Test-Path $StopFile)) { Out-Line $t.Name "DISCONNECT $($t.Name)"; $i++; Start-Sleep -Milliseconds 300 }
    }
} finally { $w.Dispose() }
