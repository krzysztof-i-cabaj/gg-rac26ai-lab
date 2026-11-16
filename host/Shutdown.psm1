# ==============================================================================
# Tytul:        Shutdown.psm1
# Opis:         Uporzadkowane wylaczenie labu (lab.cmd shutdown): lista krokow w kolejnosci
#               GoldenGate zrodla -> cel (GG, baza) -> baza RAC -> CRS po kolei na wezlach ->
#               maszyny. Kazdy krok to polecenie bash, ktore samo czeka na potwierdzenie stanu
#               (limit czasu) i konczy sie linia "RESULT ok|skip|timeout|error <opis>".
# Description [EN]: Orderly lab shutdown (lab.cmd shutdown): the step list in order source
#               GoldenGate -> target (GG, database) -> RAC database -> CRS node by node -> VMs.
#               Each step is a bash command that waits for the state itself (time limit) and
#               ends with a "RESULT ok|skip|timeout|error <detail>" line.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, konfiguracja z Get-GgConfig; polecenia uruchamia lab.ps1 przez ssh jako root
# Requirements [EN]: - PowerShell 7, config from Get-GgConfig; lab.ps1 runs the commands over ssh as root
#
# Uzycie [PL]:       Get-ShutdownSteps -Config $cfg   # lista krokow (Id, Scope, Node, TimeoutSec, Command)
# Usage [EN]:        Get-ShutdownSteps -Config $cfg   # the step list (Id, Scope, Node, TimeoutSec, Command)
# ==============================================================================
Set-StrictMode -Version Latest

# Wspolny poczatek kazdego polecenia: W <s> czeka do <s> sekund, az ok() zwroci 0 / common prelude:
# W <s> waits up to <s> seconds for ok() to return 0; R prints the result line the host reads
$script:Prelude = 'W(){ local t=$1 s=$SECONDS; until ok; do (( SECONDS - s >= t )) && return 1; sleep 5; done; }; R(){ echo "RESULT $*"; }; '

# Procesy GoldenGate (Service Manager i deployment); [x] w nawiasach: pgrep nie lapie wlasnego bash -c
# GoldenGate processes (Service Manager and deployment); [x]: pgrep does not match its own bash -c
$script:GgProcRegex = '(^|/)([S]erviceManager|[a]dminsrvr|[d]istsrvr|[r]ecvsrvr|[p]msrvr|[e]xtract|[r]eplicat)( |$)'

function Get-GgProcsCommand([int]$TimeoutSec) {
    "P='$script:GgProcRegex'; ok(){ ! pgrep -f `"`$P`" >/dev/null; }; " +
    "W $TimeoutSec && R ok 'no GoldenGate processes' || " +
    "{ R timeout `"GoldenGate processes still running: `$(pgrep -fa `"`$P`" | awk '{print `$2}' | xargs -rn1 basename | sort -u | xargs)`"; exit 1; }"
}

# Kroki w kolejnosci wykonania. Scope: rac-first = pierwszy osiagalny wezel RAC, node = ten wezel, vms = host.
# Steps in execution order. Scope: rac-first = first reachable RAC node, node = that node, vms = the host.
function Get-ShutdownSteps {
    param([Parameter(Mandatory)][hashtable]$Config)
    $o = $Config.Oracle; $g = $Config.Ogg
    $rac = @($Config.Nodes | Where-Object Role -eq 'rac')
    $tgt = @($Config.Nodes | Where-Object Role -eq 'tgt')
    $crsctl = "$($o.GridHome)/bin/crsctl"
    $res = "xag.$($g.SourceDeployment).goldengate"
    $steps = [System.Collections.Generic.List[object]]::new()
    function Add([string]$Id, [string]$Scope, [string]$Node, [int]$Timeout, [string]$Title, [string]$Body) {
        $steps.Add([pscustomobject]@{ Id = $Id; Scope = $Scope; Node = $Node; TimeoutSec = $Timeout; Title = $Title
                                      Command = if ($Body) { $script:Prelude + $Body } else { $null } })
    }

    # 1. GoldenGate zrodla przez XAG (bez tego CRS przeniesie GG na drugi wezel) / source GG via XAG (otherwise CRS moves it)
    $t = 300
    Add 'gg_src' 'rac-first' $null $t "agctl stop goldengate $($g.SourceDeployment)" (
        "G=$crsctl; RES=$res; st(){ `$G stat res `$RES 2>/dev/null | sed -n 's/^STATE=//p' | head -1; }; " +
        "s=`$(st); [ -z `"`$s`" ] && { R skip `"`$RES not registered or CRS down`"; exit 0; }; " +
        "case `"`$s`" in OFFLINE*) R ok `"`$RES already OFFLINE`"; exit 0;; esac; " +
        "su - oracle -c '$($g.XagHome)/bin/agctl stop goldengate $($g.SourceDeployment)'; rc=`$?; " +
        "ok(){ case `"`$(st)`" in OFFLINE*) return 0;; esac; return 1; }; " +
        "W $t && R ok `"agctl rc=`$rc, `$RES OFFLINE (was: `$s)`" || { R timeout `"`$RES still `$(st)`"; exit 1; }")
    foreach ($n in $rac) { Add 'gg_src_procs' 'node' $n.Name 120 'no GoldenGate processes' (Get-GgProcsCommand 120) }

    # 2. Cel: GoldenGate (jednostka systemd z 86_oggca_target.sh), potem baza (oracle-db.service, zapas: shutdown immediate)
    #    Target: GoldenGate (systemd unit from 86_oggca_target.sh), then the database (oracle-db.service, fallback: shutdown immediate)
    foreach ($n in $tgt) {
        Add 'tgt_gg' 'node' $n.Name 180 'systemctl stop OracleGoldenGate' (
            "systemctl stop OracleGoldenGate.service; echo `"systemctl rc=`$?`"; " + (Get-GgProcsCommand 180))
        $t = 600
        Add 'tgt_db' 'node' $n.Name $t "stop database $($o.TgtDb)" (
            "ok(){ ! pgrep -f '^ora_pmon_$($o.TgtDb)`$' >/dev/null; }; ok && { R ok '$($o.TgtDb) not running'; exit 0; }; " +
            "systemctl stop oracle-db.service; echo `"systemctl rc=`$?`"; " +
            "if ! W 60; then echo 'oracle-db.service left the instance up: shutdown immediate'; " +
            "su - oracle -c `"export ORACLE_HOME=$($o.DbHome) ORACLE_SID=$($o.TgtDb); echo 'shutdown immediate' | \`$ORACLE_HOME/bin/sqlplus -S / as sysdba`"; fi; " +
            "W $t && R ok 'no ora_pmon_$($o.TgtDb)' || { R timeout 'ora_pmon_$($o.TgtDb) still running'; exit 1; }")
    }

    # 3. Baza RAC przez srvctl (serwisy schodza razem z nia) / RAC database via srvctl (its services go with it)
    $t = 600
    $srv = "su - oracle -c 'export ORACLE_HOME=$($o.DbHome); `$ORACLE_HOME/bin/srvctl status database -d $($o.SrcDb)'"
    Add 'rac_db' 'rac-first' $null $t "srvctl stop database -d $($o.SrcDb)" (
        "ok(){ ! $srv 2>/dev/null | grep -q ' is running'; }; ok && { R ok '$($o.SrcDb): no running instance'; exit 0; }; " +
        "su - oracle -c 'export ORACLE_HOME=$($o.DbHome); `$ORACLE_HOME/bin/srvctl stop database -d $($o.SrcDb)'; rc=`$?; " +
        "W $t && R ok `"srvctl rc=`$rc, no running instance`" || { R timeout `"`$($srv 2>&1 | tr '\n' ' ')`"; exit 1; }")
    foreach ($n in $rac) {
        Add 'rac_pmon' 'node' $n.Name 120 "no ora_pmon_$($o.SrcDb)<n>" (
            "ok(){ ! pgrep -f '^ora_pmon_$($o.SrcDb)[0-9]+`$' >/dev/null; }; " +
            "W 120 && R ok 'no ora_pmon_$($o.SrcDb)<n>' || { R timeout 'ora_pmon still running'; exit 1; }")
    }

    # 4. CRS po kolei na kazdym wezle (nie -all: 16.11 ggrac2 nie dostal stopu, CRS-4404) / CRS node by node (not -all)
    $t = 600
    foreach ($n in $rac) {
        Add 'crs' 'node' $n.Name $t 'crsctl stop crs' (
            "ok(){ ! pgrep -f '/bin/([o]hasd|[c]rsd)\.bin' >/dev/null && ! mountpoint -q $($g.DeployRoot); }; " +
            "ok && { R ok 'CRS already down'; exit 0; }; $crsctl stop crs; rc=`$?; " +
            "W $t && R ok `"crsctl stop crs rc=`$rc, ohasd/crsd gone, $($g.DeployRoot) not mounted`" || " +
            "{ R timeout `"rc=`$rc, still: `$(pgrep -fa '/bin/([o]hasd|[c]rsd)\.bin' | awk '{print `$2}' | xargs) `$(mountpoint $($g.DeployRoot) 2>&1)`"; exit 1; }")
    }

    # 5. Maszyny: ACPI w kolejnosci cel, RAC, DNS (Step-Stop) / VMs: ACPI, order target, RAC, DNS (Step-Stop)
    Add 'vms' 'vms' $null 300 'ACPI power button: target, RAC, DNS last' $null
    $steps.ToArray()
}

# Ostatnia linia RESULT z wyjscia polecenia / the last RESULT line of a command's output
function ConvertFrom-ShutdownResult {
    param([AllowEmptyCollection()][object[]]$Lines = @())
    $last = @($Lines | ForEach-Object { "$_" } | Where-Object { $_ -match '^\s*RESULT (\w+)\s*(.*)$' } | Select-Object -Last 1)
    if (-not $last.Count) { return [pscustomobject]@{ Result = 'error'; Detail = 'no RESULT line (ssh failed or the command broke)' } }
    $m = [regex]::Match($last[0], '^\s*RESULT (\w+)\s*(.*)$')
    [pscustomobject]@{ Result = $m.Groups[1].Value; Detail = $m.Groups[2].Value.Trim() }
}

# Trwajacy test automatu testow: proces pwsh z run_test.ps1 albo sampler.ps1 (poza tym procesem)
# A running test of the test automation: a pwsh process with run_test.ps1 or sampler.ps1 (not this one)
function Get-RunningTestProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name like 'pwsh%' or Name like 'powershell%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and "$($_.CommandLine)" -match '(run_test|sampler)\.ps1' } |
        ForEach-Object { [pscustomobject]@{ Pid = $_.ProcessId; Script = ([regex]::Match("$($_.CommandLine)", '(run_test|sampler)\.ps1')).Value } })
}

Export-ModuleMember -Function Get-ShutdownSteps, ConvertFrom-ShutdownResult, Get-RunningTestProcesses
