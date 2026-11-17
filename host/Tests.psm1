# ==============================================================================
# Tytul:        Tests.psm1
# Opis:         Uprzaz testow awarii: polecenie awarii dla rodzaju (relocate, poweroff, abort, kill-sm,
#               kill-ext, link-down), kontrola stanu bazowego (Test-BaselineState / Assert-Baseline: test
#               odmawia startu z lista odchylen), odczyt probek surowych (probe.sh) do zdarzen, laga
#               i obciazenia, SSH do wezlow labu, porownanie danych z kontrola SEQ.
# Description [EN]: Failure-test harness: fault command per kind (relocate, poweroff, abort, kill-sm,
#               kill-ext, link-down), base state check (Test-BaselineState / Assert-Baseline: the test
#               refuses to start with a list of deviations), raw probe samples to events, lag and load,
#               SSH to lab nodes, data comparison with a SEQ check.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.6 (kroki DDL testu T10: Get-T10StepPlan, Invoke-T10Steps, Get-T10Verdict); 1.5 (Read-InterventionApproval, Steps galezi gg-move z wezlem i uzytkownikiem); 1.4 (gg-move: interwencja T4b, relocate albo start GG na wezle, VIP -f gdy start odmowiony); 1.3 (T4 abort = kill -9 PMON zamiast srvctl stop, CRS-2974); 1.2 (Read-RawLines czyta plik otwarty przez sampler, Invoke-LabSsh oddaje linie)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7; host/Config.psm1, Guest.psm1, Evidence.psm1; OpenSSH z kluczem
# Requirements [EN]: - PowerShell 7; host/Config.psm1, Guest.psm1, Evidence.psm1; OpenSSH with a key
#
# Uzycie [PL]:       tests/run_test.ps1 -Test T2 -ApprovedBy Kris   (moduly laduje run_test.ps1)
# Usage [EN]:        tests/run_test.ps1 -Test T2 -ApprovedBy Kris
# ==============================================================================
Set-StrictMode -Version Latest
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Get-RacNodeOfInstance([hashtable]$Config, [string]$Instance) {
    $num = [int]($Instance.Substring($Config.Oracle.SrcDb.Length))
    @(Get-Nodes -Config $Config -Role rac)[$num - 1].Name
}

# Fault command per kind. Where = host (VBoxManage) or node (SSH as root on Node).
function Get-FaultCommand {
    param([Parameter(Mandatory)][ValidateSet('relocate', 'poweroff', 'abort', 'kill-sm', 'kill-ext', 'link-down', 'gg-move', 'none')][string]$Kind,
          [string]$Target, [Parameter(Mandatory)][hashtable]$Config)
    $o = $Config.Ogg; $ora = $Config.Oracle
    switch ($Kind) {
        'poweroff'  { [pscustomobject]@{ Where = 'host'; Node = $Target; Args = @('controlvm', $Target, 'poweroff'); NeedsApproval = $true
                                         Display = "VBoxManage controlvm $Target poweroff" } }
        # NIC3 = intnet ggrac-ic (interconnect); Test-VmPlanNics guards the index
        'link-down' { [pscustomobject]@{ Where = 'host'; Node = $Target; Args = @('controlvm', $Target, 'setlinkstate3', 'off'); NeedsApproval = $true
                                         Display = "VBoxManage controlvm $Target setlinkstate3 off" } }
        # Instance crash: kill -9 of PMON (CRS sees a failure; srvctl stop -stopoption abort is a planned stop
        # and is refused while the singleton service gg_srcpdb runs there, CRS-2974)
        'abort'     { $n = Get-RacNodeOfInstance $Config $Target
                      $c = "p=`$(pgrep -f '[o]ra_pmon_$Target'); [ -n `"`$p`" ] || { echo 'no pmon process'; exit 3; }; kill -9 `$p"
                      [pscustomobject]@{ Where = 'node'; Node = $n; NeedsApproval = $false; Command = $c; Display = $c } }
        'relocate'  { [pscustomobject]@{ Where = 'node'; Node = $Target; NeedsApproval = $false
                                         Command = "$($o.XagHome)/bin/agctl relocate goldengate $($o.SourceDeployment) --node $Target"
                                         Display = "$($o.XagHome)/bin/agctl relocate goldengate $($o.SourceDeployment) --node $Target" } }
        # T4b on-call move: relocate when GoldenGate still runs, else start it on the target node; a start refused
        # because oggvip runs elsewhere (CRS-2525) moves the VIP first (-f), then starts again
        'gg-move'   { $a = "$($o.XagHome)/bin/agctl"; $d = $o.SourceDeployment; $v = $Config.Network.OggVipName
                      $c = "if $a status goldengate $d | grep -q 'is running on'; then echo 'branch: relocate'; $a relocate goldengate $d --node $Target; exit `$?; fi; echo 'branch: start'; " +
                           "$a start goldengate $d --node $Target && exit 0; echo 'agctl start refused: crsctl relocate resource $v first'; echo 'branch: vip+start'; " +
                           "$($ora.GridHome)/bin/crsctl relocate resource $v -n $Target -f && $a start goldengate $d --node $Target"
                      # Steps: the whole branch with node and user, for the live approval (T4b, video)
                      $steps = @("[$Target root] if '$a status goldengate $d' says 'is running on': $a relocate goldengate $d --node $Target",
                                 "[$Target root] else: $a start goldengate $d --node $Target",
                                 "[$Target root] if that start is refused: $($ora.GridHome)/bin/crsctl relocate resource $v -n $Target -f, then $a start goldengate $d --node $Target")
                      [pscustomobject]@{ Where = 'node'; Node = $Target; NeedsApproval = $true; Command = $c; Steps = $steps
                                         Display = "agctl relocate|start goldengate $d --node $Target (crsctl relocate resource $v -f if refused)" } }
        # [S]/[e]: pgrep -f must not match the ssh bash -c that runs it; no PID = the fault did not happen
        'kill-sm'   { $c = "p=`$(pgrep -f '$($o.Home)/bin/[S]erviceManager'); [ -n `"`$p`" ] || { echo 'no ServiceManager process'; exit 3; }; kill -9 `$p"
                      [pscustomobject]@{ Where = 'node'; Node = $Target; NeedsApproval = $false; Command = $c; Display = $c } }
        'kill-ext'  { $c = "p=`$(pgrep -f '[e]xtract.*$($o.Extract.ToUpper())'); [ -n `"`$p`" ] || { echo 'no extract process'; exit 3; }; kill -9 `$p"
                      [pscustomobject]@{ Where = 'node'; Node = $Target; NeedsApproval = $true; Command = $c; Display = $c } }
        'none'      { [pscustomobject]@{ Where = 'none'; Node = ''; NeedsApproval = $false; Display = '(no fault)' } }
    }
}

# Base state (TESTS.md): GoldenGate, service, ACFS, VIP on the first RAC node, nodes Active,
# instances ONLINE, EXT1/DP1/REP1 RUNNING, lag below the threshold. Returns the deviations.
function Test-BaselineState {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Config, [double]$LagOkSec = 30)
    $home1 = @(Get-Nodes -Config $Config -Role rac)[0].Name
    $dev = [System.Collections.Generic.List[string]]::new()
    foreach ($k in 'GgNode', 'ServiceNode', 'AcfsNode', 'VipNode') {
        if ($State[$k] -ne $home1) { $dev.Add("$k is '$($State[$k])', base state is $home1") }
    }
    foreach ($n in $State.Nodes.Keys) { if ($State.Nodes[$n] -ne 'Active') { $dev.Add("node $n is $($State.Nodes[$n])") } }
    foreach ($i in $State.Instances.Keys) { if ($State.Instances[$i] -ne 'ONLINE') { $dev.Add("instance $i is $($State.Instances[$i])") } }
    foreach ($p in 'EXT1', 'DP1', 'REP1') {
        $s = if ($State.Processes.ContainsKey($p)) { $State.Processes[$p] } else { 'missing' }
        if ($s -ne 'RUNNING') { $dev.Add("$p is $s") }
    }
    if ($null -eq $State.LagSec -or $State.LagSec -lt 0 -or $State.LagSec -ge $LagOkSec) { $dev.Add("lag is $($State.LagSec) s (threshold $LagOkSec s)") }
    $dev
}
function Assert-Baseline {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Config, [double]$LagOkSec = 30)
    $dev = @(Test-BaselineState -State $State -Config $Config -LagOkSec $LagOkSec)
    if ($dev.Count) { throw "lab is not in the base state, the test does not start: $($dev -join '; ')" }
}

# Raw sampler lines "<ts>`t<node>`t<probe line>" -> objects
function Read-RawLines([string[]]$Paths) {
    foreach ($p in $Paths) {
        if (-not (Test-Path $p)) { continue }
        # The sampler still holds the file open for writing: share ReadWrite, skip its unfinished last line
        $fs = [IO.FileStream]::new($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { $txt = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false)).ReadToEnd() } finally { $fs.Dispose() }
        $lines = @($txt -split "`r?`n")
        $lines = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() }   # after the last "`n": '' or a partial line
        foreach ($l in $lines) {
            $f = $l -split "`t", 3
            if ($f.Count -lt 3) { continue }
            [pscustomobject]@{ Ts = [datetime]::Parse($f[0], $script:Inv, [Globalization.DateTimeStyles]::AdjustToUniversal); Via = $f[1]; Line = $f[2] }
        }
    }
}
# Probe lines -> state samples for Get-StateChanges (RES/INST/NODE/PROC)
function ConvertTo-StateSamples([object[]]$Raw) {
    foreach ($r in $Raw) {
        $w = -split $r.Line
        switch ($w[0]) {
            'RES'  { [pscustomobject]@{ Ts = $r.Ts; Resource = $w[1]; Node = $w[2]; State = $w[3]; Source = 'crsctl'; Raw = $r.Line } }
            'INST' { [pscustomobject]@{ Ts = $r.Ts; Resource = "inst:$($w[1])"; Node = $w[2]; State = $w[3]; Source = 'crsctl'; Raw = $r.Line } }
            'NODE' { [pscustomobject]@{ Ts = $r.Ts; Resource = "node:$($w[1])"; Node = $w[1]; State = $w[2]; Source = 'olsnodes'; Raw = $r.Line } }
            'PROC' { [pscustomobject]@{ Ts = $r.Ts; Resource = $w[1]; Node = $w[2]; State = $w[3]; Source = 'adminclient'; Raw = $r.Line } }
        }
    }
}
# Lag rows (film L1) and load rows per second and instance (film L5)
function ConvertTo-LagRows([object[]]$Raw, [datetime]$FaultUtc) {
    foreach ($r in @($Raw | Where-Object { $_.Line -match '^LAG -?\d+' })) {
        $v = [int](-split $r.Line)[1]
        if ($v -lt 0) { continue }
        [pscustomobject][ordered]@{ ts_utc = Format-UtcMs $r.Ts; t_rel_s = Format-Rel ($r.Ts - $FaultUtc).TotalSeconds; lag_s = $v; source = 'ggadmin.gg_lag incoming_lag+incoming_heartbeat_age' }
    }
}
function ConvertTo-LoadRows([object[]]$Raw, [datetime]$FaultUtc) {
    $prev = @{}
    foreach ($r in @($Raw | Where-Object { $_.Line -match '^(SRC|TGT)LOAD ' } | Sort-Object Ts)) {
        $w = -split $r.Line
        $key = "$($w[0]):$($w[1])"; $n = [long]$w[2]
        $rate = $null
        if ($prev.ContainsKey($key)) {
            $dt = ($r.Ts - $prev[$key].Ts).TotalSeconds
            if ($dt -gt 0) { $rate = [math]::Round(($n - $prev[$key].N) / $dt, 2) }
        }
        $prev[$key] = @{ Ts = $r.Ts; N = $n }
        [pscustomobject][ordered]@{ ts_utc = Format-UtcMs $r.Ts; t_rel_s = Format-Rel ($r.Ts - $FaultUtc).TotalSeconds
                                    side = $(if ($w[0] -eq 'SRCLOAD') { 'source' } else { 'target' }); inst = $w[1]; rows_total = $n; rows_per_s = $rate }
    }
}
# One probe round (probe.sh --once) -> base state hashtable for Assert-Baseline
function ConvertTo-BaselineState([object[]]$Raw, [hashtable]$Config) {
    $s = @{ Nodes = @{}; Instances = @{}; Processes = @{}; LagSec = $null; GgNode = $null; ServiceNode = $null; AcfsNode = $null; VipNode = $null }
    foreach ($r in $Raw) {
        $w = -split $r.Line
        switch ($w[0]) {
            'RES'  { switch ($w[1]) { 'svc' { $s.ServiceNode = $w[2] } 'acfs' { $s.AcfsNode = $w[2] } 'vip' { $s.VipNode = $w[2] } 'sm' { $s.GgNode = $w[2] } } }
            'INST' { $s.Instances[$w[1]] = $w[3] }
            'NODE' { $s.Nodes[$w[1]] = $w[2] }
            'PROC' { $s.Processes[$w[1]] = $w[3] }
            'LAG'  { $s.LagSec = [int]$w[1] }
        }
    }
    $s
}

# Something really happened after the fault: a sample that differs from the base state.
# Without it a check right after the fault sees the old, healthy state and calls it recovered.
function Test-Disturbed {
    param([object[]]$Samples, [Parameter(Mandatory)][hashtable]$Base)
    $map = @{ svc = 'ServiceNode'; acfs = 'AcfsNode'; vip = 'VipNode'; sm = 'GgNode' }
    foreach ($s in @($Samples)) {
        if ($map.ContainsKey($s.Resource)) { if ($s.State -ne 'ONLINE' -or $s.Node -ne $Base[$map[$s.Resource]]) { return $true } }
        elseif ($s.Resource -like 'inst:*') { if ($s.State -ne 'ONLINE') { return $true } }
        elseif ($s.Resource -like 'node:*') { if ($s.State -ne 'Active') { return $true } }
        elseif ($s.Resource -in 'EXT1', 'DP1', 'REP1') { if ($s.State -ne 'RUNNING') { return $true } }
    }
    $false
}
# Recovered: after a disturbance, the whole chain (service, ACFS, VIP, XAG) ONLINE on one node,
# on the expected node when there is one, EXT1/DP1/REP1 RUNNING and lag below the threshold
function Test-Recovered {
    param([Parameter(Mandatory)][hashtable]$State, [bool]$Disturbed, [string]$ExpectGgNode, [double]$LagOkSec = 30)
    if (-not $Disturbed) { return $false }
    $n = $State.GgNode
    if (-not $n -or $n -eq '-') { return $false }
    foreach ($k in 'ServiceNode', 'AcfsNode', 'VipNode') { if ($State[$k] -ne $n) { return $false } }
    if ($ExpectGgNode -and $n -ne $ExpectGgNode) { return $false }
    foreach ($p in 'EXT1', 'DP1', 'REP1') { if (-not $State.Processes.ContainsKey($p) -or $State.Processes[$p] -ne 'RUNNING') { return $false } }
    $null -ne $State.LagSec -and $State.LagSec -ge 0 -and $State.LagSec -lt $LagOkSec
}
# Node GoldenGate must end on: the relocation target, or the other node when its own node dies; else no expectation
function Get-ExpectedGgNode {
    param([string]$Kind, [string]$Target, [Parameter(Mandatory)][hashtable]$Base, [Parameter(Mandatory)][hashtable]$Config)
    $names = @(Get-Nodes -Config $Config -Role rac | ForEach-Object Name)
    if ($Kind -eq 'relocate') { return $Target }
    if ($Kind -in 'poweroff', 'link-down' -and $Target -eq $Base.GgNode) { return $names | Where-Object { $_ -ne $Target } | Select-Object -First 1 }
    $null
}
# <test>-back: Prep (not measured) starts powered-off RAC VMs, puts the interconnect link back (T7) and waits
# for the cluster; Measured moves the singleton service (-failback NO) back first, then GoldenGate to its node:
# --use_local_services keeps GG on the node of the service (XAG docs). Admin-managed service = -oldinst/-newinst
# (relocate) and -instance (start); -currentnode/-targetnode and -node are policy-managed only (desupported in 26ai).
# LAB: whether the service relocation stops or drags GG along (XAG dependency): try both orders on the live lab.
function Get-BackPlan {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Config, [hashtable]$VmStates = @{})
    $rac = @(Get-Nodes -Config $Config -Role rac); $home1 = $rac[0].Name; $o = $Config.Ogg; $ora = $Config.Oracle
    $prep = foreach ($n in $rac) {
        if ($VmStates.ContainsKey($n.Name) -and $VmStates[$n.Name] -ne 'running') {
            [pscustomobject]@{ Where = 'host'; Node = $n.Name; Args = @('startvm', $n.Name, '--type', 'headless'); Display = "VBoxManage startvm $($n.Name) --type headless" }
        } else {
            [pscustomobject]@{ Where = 'host'; Node = $n.Name; Args = @('controlvm', $n.Name, 'setlinkstate3', 'on'); Display = "VBoxManage controlvm $($n.Name) setlinkstate3 on" }
        }
    }
    $prep = @($prep) + @([pscustomobject]@{ Where = 'wait'; Node = ''; Display = 'wait until every RAC node is Active and every instance ONLINE' })
    $names = @($rac | ForEach-Object Name)
    $inst = { param($node) "$($ora.SrcDb)$([array]::IndexOf($names, $node) + 1)" }
    $meas = @(
        if ($State.ServiceNode -ne $home1) {
            $d = if ($State.ServiceNode -in $names) { "srvctl relocate service -db $($ora.SrcDb) -service $($ora.GgService) -oldinst $(& $inst $State.ServiceNode) -newinst $(& $inst $home1)" }
                 else { "srvctl start service -db $($ora.SrcDb) -service $($ora.GgService) -instance $(& $inst $home1)" }
            [pscustomobject]@{ Where = 'node'; Node = $home1; Command = "runuser -l oracle -c '$d'"; Display = $d }
        }
        if ($State.GgNode -ne $home1) {
            $verb = if ($State.GgNode -in $names) { 'relocate' } else { 'start' }
            $c = "$($o.XagHome)/bin/agctl $verb goldengate $($o.SourceDeployment) --node $home1"
            [pscustomobject]@{ Where = 'node'; Node = $home1; Command = $c; Display = $c }
        }
    )
    [pscustomobject]@{ Prep = $prep; Measured = $meas }
}
# Film D1: SEQ lines "SEQ <inst> <rows> <distinct> <min> <max>" per side -> missing / duplicate counts per instance
function Get-SeqCheck([string[]]$Source, [string[]]$Target) {
    $parse = {
        param($lines)
        $h = [ordered]@{}
        foreach ($l in @($lines)) {
            if ("$l" -match '^\s*SEQ\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$') {
                $h[$Matches[1]] = @{ Rows = [long]$Matches[2]; Distinct = [long]$Matches[3]; Min = [long]$Matches[4]; Max = [long]$Matches[5] }
            }
        }
        $h
    }
    $s = & $parse $Source; $t = & $parse $Target
    $zero = @{ Rows = [long]0; Distinct = [long]0; Min = [long]0; Max = [long]0 }
    foreach ($i in @($s.Keys) + @($t.Keys | Where-Object { -not $s.Contains($_) })) {
        $a = if ($s.Contains($i)) { $s[$i] } else { $zero }; $b = if ($t.Contains($i)) { $t[$i] } else { $zero }
        [pscustomobject][ordered]@{
            inst = $i; source_rows = $a.Rows; target_rows = $b.Rows
            missing = [math]::Max(0, $a.Distinct - $b.Distinct); extra_target = [math]::Max(0, $b.Distinct - $a.Distinct)
            duplicates_source = $a.Rows - $a.Distinct; duplicates_target = $b.Rows - $b.Distinct
            source_min = $a.Min; source_max = $a.Max; target_min = $b.Min; target_max = $b.Max
        }
    }
}
# data_ok: every table equal, load rows really written (an empty compare must never pass), SEQ complete
function Get-DataVerdict([object[]]$Tables, [object[]]$SeqCheck) {
    $why = [System.Collections.Generic.List[string]]::new()
    $tabs = @($Tables | Where-Object { $_ })
    if (-not $tabs.Count) { $why.Add('no compare result') }
    $bad = @($tabs | Where-Object { -not $_.Match } | ForEach-Object Table)
    if ($bad.Count) { $why.Add("tables differ: $($bad -join ', ')") }
    $le = @($tabs | Where-Object { $_.Table -eq 'SALES.LOAD_EVENTS' })
    if (-not $le.Count -or -not $le[0].SourceRows) { $why.Add('no load rows on the source (loadgen did not write)') }
    $seq = @($SeqCheck | Where-Object { $_ -and ($_.missing -or $_.extra_target -or $_.duplicates_target) } |
             ForEach-Object { "inst $($_.inst): missing $($_.missing), extra $($_.extra_target), duplicates $($_.duplicates_target)" })
    if ($seq.Count) { $why.Add("SEQ check: $($seq -join '; ')") }
    [pscustomobject]@{ Ok = ($why.Count -eq 0); Reason = ($why -join '; ') }
}

# SSH as root to a lab node (key auth, no host keys kept). Returns output lines; throws on rc != 0 unless -AllowFail.
function Invoke-LabSsh {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Command, [string]$KeyPath, [switch]$AllowFail, [int]$TimeoutSec = 10)
    $opts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-o', "ConnectTimeout=$TimeoutSec",
              '-o', 'LogLevel=ERROR', '-i', $KeyPath)
    $out = @(& ssh @opts "root@$Ip" $Command 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) { throw "ssh $Ip exit $LASTEXITCODE : $Command" }
    # Lines to the pipeline; ", $out" nested the array inside @() in the caller (T8 refused in the base state, 16.11)
    $out
}

# T4b live approval: the file approve_intervention in the run directory; returns approved_by (unknown when not
# named) or $null while the file is missing
function Read-InterventionApproval([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($Path), '(?m)^\s*approved_by\s*=\s*(\S+)')
    if ($m.Success) { $m.Groups[1].Value } else { 'unknown' }
}

# ------------------------------------------------------------------------------
# T10 DDL steps (guest/shared/t10_ddl_steps.sh). 16.11 the steps ran from a separate hand-written script and the
# first T10 run passed with no DDL at all; now the test automation runs them and T10 cannot pass without them.
# ------------------------------------------------------------------------------
# Plan: Src = action on the source, WaitTgt = target action polled until it prints 1, Compare = row read on both sides.
# Cleanup = run even after a failed step, so the next run starts from the same table.
function Get-T10StepPlan {
    @(
        [pscustomobject]@{ Name = 'insert101'; Src = 'insert101'; WaitTgt = 'has_row101'; Compare = $null; Cleanup = $false; Title = 'insert id 101 (VECTOR, BOOLEAN, JSON) + commit' }
        [pscustomobject]@{ Name = 'row101'; Src = $null; WaitTgt = $null; Compare = 'row101'; Cleanup = $false; Title = 'row 101 equal on source and target' }
        [pscustomobject]@{ Name = 'ddl_add'; Src = 'ddl_add'; WaitTgt = 'has_note'; Compare = $null; Cleanup = $false; Title = 'alter table sales.types26 add (note varchar2(30))' }
        [pscustomobject]@{ Name = 'insert102'; Src = 'insert102'; WaitTgt = 'has_row102'; Compare = $null; Cleanup = $false; Title = 'insert id 102 with note + commit' }
        [pscustomobject]@{ Name = 'row102'; Src = $null; WaitTgt = $null; Compare = 'row102'; Cleanup = $false; Title = 'row 102 (with note) equal on source and target' }
        [pscustomobject]@{ Name = 'cleanup'; Src = 'cleanup'; WaitTgt = 'no_note'; Compare = $null; Cleanup = $true; Title = 'delete 101,102 + commit + alter table drop column note' }
        [pscustomobject]@{ Name = 'cleanup_rows'; Src = $null; WaitTgt = 'no_rows'; Compare = $null; Cleanup = $true; Title = 'rows 101,102 gone on the target' }
    )
}
# "T10 <action> <value>" -> Ok (no "error"), Value; no line for the action = not Ok (ssh failed, script missing)
function ConvertFrom-T10Line {
    param([AllowEmptyCollection()][object[]]$Lines = @(), [Parameter(Mandatory)][string]$Action)
    $l = @($Lines | ForEach-Object { "$_" } | Where-Object { $_ -match "^\s*T10\s+$([regex]::Escape($Action))(\s|$)" } | Select-Object -Last 1)
    if (-not $l.Count) { return [pscustomobject]@{ Ok = $false; Value = $null; Detail = "no 'T10 $Action' line: $((@($Lines) -join ' ').Trim())" } }
    $v = ($l[0] -replace "^\s*T10\s+$([regex]::Escape($Action))\s*", '').Trim()
    if ($v -match '^error\b') { return [pscustomobject]@{ Ok = $false; Value = $null; Detail = $v } }
    [pscustomobject]@{ Ok = $true; Value = $v; Detail = '' }
}
# Runs the plan. Src / Tgt: scriptblocks { param($action) <output lines> }; Log: { param($message) }.
# seconds_to_target = from the end of the last source command to the first target answer 1 (0.1 s).
# Checked = the first source command really ran (an error there = the steps did not run).
function Invoke-T10Steps {
    param([Parameter(Mandatory)][object[]]$Plan, [Parameter(Mandatory)][scriptblock]$Src, [Parameter(Mandatory)][scriptblock]$Tgt,
          [scriptblock]$Log = {}, [int]$WaitSec = 90, [double]$PollSec = 1)
    $steps = [System.Collections.Generic.List[object]]::new()
    $checked = $false; $failed = $false; $tRef = [datetime]::UtcNow; $valuesMatch = $true
    foreach ($p in $Plan) {
        if ($failed -and -not $p.Cleanup) {
            $steps.Add([pscustomobject][ordered]@{ name = $p.Name; seconds_to_target = $null; ok = $false; detail = 'skipped after a failed step' }); continue
        }
        $ok = $true; $sec = $null; $detail = ''
        if ($p.Src) {
            & $Log "SRC $($p.Name): $($p.Title)"
            $r = ConvertFrom-T10Line -Lines @(& $Src $p.Src) -Action $p.Src
            $tRef = [datetime]::UtcNow
            if ($r.Ok) { if ($steps.Count -eq 0) { $checked = $true }; & $Log "SRC $($p.Name) done ($($r.Value))" }
            else { $ok = $false; $detail = "source: $($r.Detail)"; & $Log "SRC $($p.Name) FAILED: $($r.Detail)" }
        }
        if ($ok -and $p.WaitTgt) {
            $seen = $false
            do {
                $r = ConvertFrom-T10Line -Lines @(& $Tgt $p.WaitTgt) -Action $p.WaitTgt
                if ($r.Ok -and $r.Value -eq '1') { $seen = $true; break }
                if ($PollSec -gt 0) { Start-Sleep -Milliseconds ([int]($PollSec * 1000)) }
            } while (([datetime]::UtcNow - $tRef).TotalSeconds -lt $WaitSec)
            if ($seen) { $sec = [math]::Round(([datetime]::UtcNow - $tRef).TotalSeconds, 1); & $Log "TGT $($p.Name): $($p.WaitTgt) after $sec s" }
            else { $ok = $false; $detail = "target: $($p.WaitTgt) not seen within $WaitSec s"; & $Log "TGT $($p.Name): $($p.WaitTgt) NOT SEEN in $WaitSec s" }
        }
        if ($ok -and $p.Compare) {
            $s = ConvertFrom-T10Line -Lines @(& $Src $p.Compare) -Action $p.Compare
            $t = ConvertFrom-T10Line -Lines @(& $Tgt $p.Compare) -Action $p.Compare
            & $Log "CMP $($p.Name) src: $($s.Value)"; & $Log "CMP $($p.Name) tgt: $($t.Value)"
            if (-not ($s.Ok -and $t.Ok -and $s.Value -and $s.Value -ne 'none' -and $s.Value -ceq $t.Value)) {
                $ok = $false; $valuesMatch = $false
                $detail = if (-not ($s.Ok -and $t.Ok)) { "read failed: $($s.Detail) $($t.Detail)".Trim() } else { "values differ: source '$($s.Value)', target '$($t.Value)'" }
                & $Log "CMP $($p.Name) DIFF"
            } else { & $Log "CMP $($p.Name) MATCH" }
        }
        if (-not $ok -and -not $p.Cleanup) { $failed = $true }
        $steps.Add([pscustomobject][ordered]@{ name = $p.Name; seconds_to_target = $sec; ok = $ok; detail = $detail })
        if (-not $checked) { break }   # the first source command did not run: nothing else is meaningful
    }
    [pscustomobject]@{ Checked = $checked; Steps = $steps.ToArray(); ValuesMatch = ($checked -and $valuesMatch) }
}
# Pass rule for a test with Steps = 'ddl-types': no steps run = measurement error ddl_not_run (16.11 by hand);
# steps ran but something did not arrive or differs = fail with the reason; everything arrived and equal = ok.
function Get-T10Verdict {
    param([object]$Result)
    if (-not $Result -or -not $Result.Checked) {
        $why = if ($Result -and @($Result.Steps).Count) { @($Result.Steps)[0].detail } else { 'steps not started' }
        return [pscustomobject]@{ Ok = $false; MeasurementError = 'ddl_not_run'; Reason = "DDL steps did not run: $why" }
    }
    $bad = @($Result.Steps | Where-Object { -not $_.ok } | ForEach-Object { "$($_.name) ($($_.detail))" })
    if ($bad.Count) { return [pscustomobject]@{ Ok = $false; MeasurementError = $null; Reason = "DDL steps failed: $($bad -join '; ')" } }
    if (-not $Result.ValuesMatch) { return [pscustomobject]@{ Ok = $false; MeasurementError = $null; Reason = 'DDL steps: values differ' } }
    [pscustomobject]@{ Ok = $true; MeasurementError = $null; Reason = '' }
}

Export-ModuleMember -Function Get-T10StepPlan, ConvertFrom-T10Line, Invoke-T10Steps, Get-T10Verdict,
    Read-InterventionApproval, Get-FaultCommand, Test-BaselineState, Assert-Baseline, Read-RawLines, ConvertTo-StateSamples,
    ConvertTo-LagRows, ConvertTo-LoadRows, ConvertTo-BaselineState, Invoke-LabSsh, Get-RacNodeOfInstance,
    Test-Disturbed, Test-Recovered, Get-ExpectedGgNode, Get-BackPlan, Get-SeqCheck, Get-DataVerdict
