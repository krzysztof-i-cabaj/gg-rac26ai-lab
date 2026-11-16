# ==============================================================================
# Tytul:        run_test.ps1
# Opis:         Jeden test awarii T1-T10 (TESTS.md) z zapisem dowodow pod film: stan bazowy
#               (Assert-Baseline, odmowa startu), offsety zegarow, reset danych, probkowniki (crs, gg src,
#               gg tgt, lag) z czasem hosta, obciazenie przez oba watki (loadgen z ggtgt), awaria, czekanie
#               na powrot (najpierw zaklocenie, potem caly lancuch na jednym wezle), zatrzymanie obciazenia
#               w bazie, porownanie danych z kontrola SEQ, events/lag/load.csv, compare.json, summary.json,
#               summary_all.csv, commands.txt (kazde polecenie z t_rel_s), wycinki logow, maskowany transkrypt.
#               -Back: start wylaczonych wezlow, lacze interconnect, potem mierzony powrot GG i serwisu.
#               -Repeat: przed kolejnym przebiegiem testu, ktory przesuwa stan, idzie <test>-back.
# Description [EN]: One failure test T1-T10 (TESTS.md) with evidence for the video: base state
#               (Assert-Baseline, refuses to start), clock offsets, data reset, samplers (crs, gg src, gg tgt,
#               lag) on the host clock, load through both threads (loadgen from ggtgt), fault, recovery wait
#               (a disturbance first, then the whole chain on one node), load stopped in the database, data
#               comparison with a SEQ check, events/lag/load.csv, compare.json, summary.json, summary_all.csv,
#               commands.txt (every command with t_rel_s), log excerpts, masked transcript.
#               -Back: start powered-off nodes, interconnect link on, then a measured return of GG and the service.
#               -Repeat: a state-moving test runs <test>-back before the next run.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.6 (T4b: zgoda na zywo, INTERVENTION READY + plik approve_intervention, t_intervention_ready, approval_wait_s); 1.5 (T4b: interwencja Intervention z pliku przypadku, t_intervention, config_rev, harness_commit, test_variant, observe_s); 1.4 (harness_error, data_checked, attempt; 1.3: Sh oddaje linie, nie tablice; 1.2: video: A4 oczekiwanie, A5 sesja, A6 agent_notes, baseline po przebiegu, dziennik)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab po lab.cmd validate; $env:LAB_PASS; PowerShell 7, VirtualBox, OpenSSH z kluczem
# Requirements [EN]: - lab after lab.cmd validate; $env:LAB_PASS; PowerShell 7, VirtualBox, OpenSSH with a key
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T2 -ApprovedBy Kris [-Repeat 3] [-FilmMode] [-DryRun]
#                    .\tests\run_test.ps1 -Test T2 -Back -ApprovedBy Kris   # mierzony powrot do stanu bazowego
# Usage [EN]:        .\tests\run_test.ps1 -Test T2 -ApprovedBy Kris [-Repeat 3] [-FilmMode] [-DryRun] [-Back]
#                    exit code: 0 = every run passed, 1 = a run failed or was refused, 2 = refused before the start
# ==============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^T([1-9]|10)b?$')][string]$Test,
    [int]$Repeat = 1,
    [switch]$Back,
    [string]$Session = $env:LAB_TEST_SESSION,   # A5: name of the agent session running the tests
    [switch]$NoBaseline,                        # skip lab.cmd baseline after each run
    [string]$ApprovedBy,
    [string]$InvokedBy = 'agent',
    [switch]$FilmMode,
    [switch]$ManualStepDone,
    [int]$LoadRate = 10,
    [double]$LagOkSec = 30,
    [string]$ConfigPath,
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Repo = Resolve-Path (Join-Path $PSScriptRoot '..')
Import-Module (Join-Path $Repo 'host\modules\Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $Repo 'host\modules\VmBuilder.psm1') -Force -DisableNameChecking   # Invoke-VBox, Get-VmState
foreach ($m in 'Config', 'Binaries', 'Guest', 'Evidence', 'Tests') { Import-Module (Join-Path $Repo "host\$m.psm1") -Force -DisableNameChecking }
if (-not $ConfigPath) { $ConfigPath = Join-Path $Repo 'lab.config.psd1' }
$cfg = Get-GgConfig -Path $ConfigPath
$key = $cfg.Ssh.KeyPath -replace '^~', $HOME
$rac = @(Get-Nodes -Config $cfg -Role rac); $tgt = @(Get-Nodes -Config $cfg -Role tgt)[0]
# T4b: a variant of T4 in its own case file (T04b_*.ps1)
$caseFile = @(Get-ChildItem (Join-Path $Repo 'tests\cases') -Filter ("T{0:D2}{1}_*.ps1" -f [int]($Test -replace '\D'), $(if ($Test -match 'b$') { 'b' } else { '' })))[0]
$case = & $caseFile.FullName
# Lab configuration revision (the video tells runs apart by it): GG service singleton (MAA), XAG --use_local_services
$configRev = 'maa-singleton-local-svc'
$harnessCommit = try { (& git -C $Repo rev-parse --short HEAD 2>$null) } catch { $null }
$testId = $case.Id; $kind = $case.Kind; $target = $case.Target
if ($Back) {
    # The back plan is computed from the live state at the start of the run (Get-BackPlan)
    $testId = "$($case.Id)-back"; $kind = 'back'; $target = $rac[0].Name
    $fault = [pscustomobject]@{ Where = 'plan'; Node = $target; NeedsApproval = $false; Display = "back to the base state on $target (Get-BackPlan)" }
} else {
    $fault = Get-FaultCommand -Kind $kind -Target $target -Config $cfg
}
# T4b: a manual intervention AfterSec seconds after the fault (not in a -back run)
$iv = $null
if (-not $Back -and $case.ContainsKey('Intervention')) {
    $iv = Get-FaultCommand -Kind $case.Intervention.Kind -Target $case.Intervention.Target -Config $cfg
    $iv | Add-Member -NotePropertyName AfterSec -NotePropertyValue ([int]$case.Intervention.AfterSec)
    # Live approval (Kris 16.11, OBS): at AfterSec the harness only announces the move and waits for the file
    # approve_intervention in the run directory; the agent creates it after Kris says "tak"
    $iv | Add-Member -NotePropertyName LiveApproval -NotePropertyValue ([bool]$case.Intervention['LiveApproval'])
    $iv | Add-Member -NotePropertyName ApprovalTimeoutSec -NotePropertyValue ([int]$(if ($case.Intervention['ApprovalTimeoutSec']) { $case.Intervention['ApprovalTimeoutSec'] } else { 600 }))
}

# Film A1: a power-off, a link cut, a destructive test or a manual intervention runs only with a named approver
if (($fault.NeedsApproval -or $case.Destructive -or $iv) -and -not $ApprovedBy) {
    Write-Host "REFUSED $testId ($($fault.Display)): needs -ApprovedBy <name> (fault or destructive test)"
    exit 2
}
if ($case.Id -eq 'T6' -and -not $Back -and -not $DryRun -and -not $ManualStepDone) {
    Write-Host 'REFUSED T6: set "Critical to deployment health" ON for EXT1 in the Web UI first, then add -ManualStepDone'
    exit 2
}
$pdbSrc = $cfg.Oracle.SrcPdb; $pdbTgt = $cfg.Oracle.TgtPdb
$loadSec = $case.PreSec + $case.TimeoutSec + $case.PostSec
if ($iv -and $iv.LiveApproval) { $loadSec += $iv.ApprovalTimeoutSec }   # the recovery wait may grow by the approval wait

if ($DryRun) {
    Write-Host "DRYRUN $testId '$($case.Title)' x$Repeat, invoked_by=$InvokedBy approved_by=$ApprovedBy session=$Session"
    $x = $case.Expected
    Write-Host "DRYRUN expected (A4): expected.json + summary.json before the fault: final_node=$($x.FinalNode) recovers=$($x.Recovers) rto_s=$($x.RtoS) data_loss=$($x.DataLoss)"
    Write-Host "DRYRUN agent_notes.md (A6): template in the run directory (before / after / interventions '- ✋ ...')"
    Write-Host "DRYRUN baseline: probe.sh crs|gg|lag --once on $($rac[0].Name) and $($tgt.Name), Assert-Baseline (lag < $LagOkSec s)"
    if ($Back) { Write-Host "DRYRUN back prep: VBoxManage startvm for powered-off RAC VMs, setlinkstate3 on for running ones, wait for nodes Active and instances ONLINE" }
    Write-Host "DRYRUN reset: loadgen.sh stop, sql/99_reset_demo.sql $pdbSrc"
    Write-Host "DRYRUN samplers: crs + gg src on $($rac.Name -join ','), gg + lag on $($tgt.Name)"
    Write-Host "DRYRUN load: [$($tgt.Name)] loadgen.sh $LoadRate $loadSec"
    Write-Host "DRYRUN wait $($case.PreSec) s of load"
    if ($Back) { Write-Host "DRYRUN fault plan: srvctl relocate service -db $($cfg.Oracle.SrcDb) -service $($cfg.Oracle.GgService) -oldinst <current> -newinst $($cfg.Oracle.SrcDb)1, then agctl relocate goldengate $($cfg.Ogg.SourceDeployment) --node $target (only what moved)" }
    else { Write-Host "DRYRUN fault $($fault.Where): $($fault.Display)" }
    if ($iv) {
        Write-Host "DRYRUN intervention at $($iv.AfterSec) s after the fault: $($iv.Display)   (t_intervention, ✋ in agent_notes.md)"
        if ($iv.LiveApproval) { Write-Host "DRYRUN   live approval: INTERVENTION READY, then waits up to $($iv.ApprovalTimeoutSec) s for <run dir>\approve_intervention (approved_by=<name>)" }
        foreach ($st in @($iv.PSObject.Properties['Steps'] | ForEach-Object Value)) { Write-Host "DRYRUN   $st" }
    }
    Write-Host "DRYRUN recovery wait up to $($case.TimeoutSec) s (disturbance seen, chain on one node, lag < $LagOkSec s), observe $($case.PostSec) s"
    Write-Host "DRYRUN stop load: [$($tgt.Name)] loadgen.sh stop (kill session for module LOADGEN)"
    Write-Host "DRYRUN compare: compare.sh + SEQ check on source and target"
    if (-not $NoBaseline) { Write-Host "DRYRUN after the run: lab.cmd baseline (duration -> summary.json back_to_base_s, back_to_base.json)" }
    Write-Host "DRYRUN journal: results/DZIENNIK_TESTOW.md and results/summary_all.csv after every run"
    Write-Host "DRYRUN results/$testId-<yyyyMMdd-HHmmss>/ events.csv lag.csv load.csv compare.json summary.json commands.txt transcript.txt"
    if ($Repeat -gt 1) { Write-Host "DRYRUN between runs: lab.cmd baseline (already after every run)" }
    exit 0
}

if (-not $env:LAB_PASS) { throw 'LAB_PASS is empty' }
$secrets = @($env:LAB_PASS)
# Film S1: every command goes to the command log with its host time and output
$script:CmdLog = [System.Collections.Generic.List[object]]::new()
function Add-CmdLog([string]$Node, [string]$Cmd, [object[]]$Out) { $script:CmdLog.Add([pscustomobject]@{ Ts = [datetime]::UtcNow; Node = $Node; Command = $Cmd; Output = @($Out) }) }
function Sh([object]$Node, [string]$Cmd, [switch]$AllowFail, [switch]$NoLog) {
    $t = [datetime]::UtcNow
    try { $out = @(Invoke-LabSsh -Ip $Node.PublicIp -Command $Cmd -KeyPath $key -AllowFail:$AllowFail) }
    finally {
        if (-not $NoLog) { $script:CmdLog.Add([pscustomobject]@{ Ts = $t; Node = $Node.Name; Command = $Cmd; Output = @(if (Get-Variable out -Scope Local -ErrorAction Ignore) { $out } else { '(ssh failed)' }) }) }
    }
    # Lines to the pipeline (callers wrap in @()); ", $out" made @(Sh) + @(Sh) two arrays (T8 refused, 16.11)
    $out
}
function Invoke-HostStep([object]$Step) {
    $va = @($Step.Args); Invoke-VBox @va | Out-Null; Add-CmdLog 'host' $Step.Display @()
}
function Get-LiveRac { foreach ($n in $rac) { Sh $n 'true' -AllowFail -NoLog | Out-Null; if ($LASTEXITCODE -eq 0) { return $n } }; throw 'no RAC node answers' }
function Get-ProbeOnce {
    $r = Get-LiveRac
    $lines = @(Sh $r 'bash /root/lab/shared/probe.sh crs 1 --once; bash /root/lab/shared/probe.sh gg 1 --once' -AllowFail) +
             @(Sh $tgt 'bash /root/lab/shared/probe.sh gg 1 --once; bash /root/lab/shared/probe.sh lag 1 --once' -AllowFail)
    @($lines | ForEach-Object { [pscustomobject]@{ Ts = [datetime]::UtcNow; Via = ''; Line = $_ } })
}
function Get-Compare {
    # compare.sh prints COMPARE lines and SEQ lines (rows, distinct SEQ, min, max per instance). It connects to the
    # local instance: a node that answers SSH but whose instance is down (T4 16.11: ggcdb1 not restarted) gives
    # no COMPARE line -> try the next RAC node; no node with COMPARE lines = the source was not compared ($null)
    $s = $null
    foreach ($n in $rac) {
        $o = @(Sh $n 'bash /root/lab/shared/compare.sh' -AllowFail)
        if (@($o | Where-Object { $_ -like 'COMPARE *' }).Count) { $s = $o; break }
    }
    if ($null -eq $s) { return $null }
    $t = @(Sh $tgt 'bash /root/lab/shared/compare.sh' -AllowFail)
    [pscustomobject]@{ Tables = @(Compare-CompareLines -Source $s -Target $t)
                       SeqSource = @($s | Where-Object { $_ -like 'SEQ *' }); SeqTarget = @($t | Where-Object { $_ -like 'SEQ *' }) }
}
# Killing the local ssh client does not stop LOADGEN.RUN in the database: stop it there, then wait for the client
function Stop-Load([object]$Proc) { Sh $tgt 'bash /root/lab/shared/loadgen.sh stop' -AllowFail | Out-Null; if ($Proc -and -not $Proc.WaitForExit(60000)) { $Proc.Kill($true) } }
# -back prep: nodes Active and instances ONLINE (a node that boots does not answer SSH for a while)
function Wait-RacUp([int]$TimeoutSec) {
    $until = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $until) {
        try {
            $st = ConvertTo-BaselineState (Get-ProbeOnce) $cfg
            $active = @($st.Nodes.Values | Where-Object { $_ -eq 'Active' }).Count; $online = @($st.Instances.Values | Where-Object { $_ -eq 'ONLINE' }).Count
            if ($active -eq $rac.Count -and $online -eq $rac.Count) { return }
        } catch { Write-Host "   waiting: $($_.Exception.Message)" }
        Start-Sleep -Seconds 10
    }
    throw "RAC not back within $TimeoutSec s (every node Active, every instance ONLINE)"
}

$failedRuns = 0
for ($run = 1; $run -le $Repeat; $run++) {
    # Nothing from an earlier run may reach this one (summary, marks, fault time)
    $tFault = [datetime]::UtcNow; $recovered = $false; $dataOk = $false; $refused = $false; $disturbed = $false
    $dataChecked = $false; $harnessError = $false; $tIntervention = $null; $ivRc = $null; $tObserveEnd = $null
    $tIvReady = $null; $ivApprovedBy = $null; $ivDone = $false
    $marks = [System.Collections.Generic.List[object]]::new(); $offsets = [ordered]@{}; $cmp = $null; $base = $null
    $verdict = $null; $seqCheck = @(); $faultSteps = @(); $expectGg = $null
    $script:CmdLog = [System.Collections.Generic.List[object]]::new()
    $dir = New-EvidenceDir -TestId $testId -Root (Join-Path $Repo 'results')
    $stop = Join-Path $dir '.stop'
    # Video: run_no counts runs of this invocation (-Repeat); attempt counts every run directory of this test
    $attempt = @(Get-ChildItem (Join-Path $Repo 'results') -Directory | Where-Object Name -match "^$([regex]::Escape($testId))-\d{8}-\d{6}").Count
    # A6: the agent fills this in (before the fault, after the run, every manual intervention as "- ✋ <what> · <why>")
    Write-LabText (Join-Path $dir 'agent_notes.md') ((@("# 📝 $testId przebieg $run — notatki agenta", '', "Sesja: $Session", '',
        '## Przed testem (co sprawdzone)', '', '- ', '', '## Po teście (co widać)', '', '- ', '',
        '## Interwencje ręczne', '', '<!-- jedna linia na interwencję: - ✋ <co> · <dlaczego> -->', '', '## Uwagi', '', '- ') -join "`n") + "`n")
    Start-Transcript -Path (Join-Path $dir 'transcript.txt') | Out-Null
    $procs = @(); $load = $null; $notes = [System.Collections.Generic.List[string]]::new(); $notes.Add($case.Notes)
    try {
        Write-Host "== $testId run $run/$Repeat -> $dir"
        # Z3: clock offsets of every VM (chrony) at the start
        foreach ($n in $cfg.Nodes) {
            $o = @(Sh $n "chronyc tracking | sed -n 's/^System time *: *\([0-9.]*\) seconds \(fast\|slow\).*/\1 \2/p'" -AllowFail) -join ' '
            if ($o -match '([\d.]+) (fast|slow)') { $offsets[$n.Name] = [math]::Round([double]$Matches[1] * 1000 * $(if ($Matches[2] -eq 'slow') { -1 } else { 1 }), 3) }
        }
        if ($Back) {
            # Not measured: powered-off nodes start, the interconnect link comes back (T7), the cluster settles
            $vm = @{}; foreach ($n in $rac) { $vm[$n.Name] = Get-VmState -Name $n.Name }
            $moved = ConvertTo-BaselineState (Get-ProbeOnce) $cfg
            foreach ($p in (Get-BackPlan -State $moved -Config $cfg -VmStates $vm).Prep) {
                Write-Host "   back prep: $($p.Display)"
                if ($p.Where -eq 'host') { Invoke-HostStep $p } else { Wait-RacUp -TimeoutSec $case.TimeoutSec }
            }
            $base = ConvertTo-BaselineState (Get-ProbeOnce) $cfg
            $faultSteps = @((Get-BackPlan -State $base -Config $cfg).Measured)
            $expectGg = $rac[0].Name
        } else {
            # S3: base state before the test; outside it the test refuses to start
            $base = ConvertTo-BaselineState (Get-ProbeOnce) $cfg
            try { Assert-Baseline -State $base -Config $cfg -LagOkSec $LagOkSec } catch { $refused = $true; throw }
            $faultSteps = @($fault)
            $expectGg = Get-ExpectedGgNode -Kind $kind -Target $target -Base $base -Config $cfg
        }
        Write-LabJson (Join-Path $dir 'baseline.json') $base
        # A4: the expectation goes to disk before the load and the fault; summary.json is replaced at the end
        $expWritten = Format-UtcMs ([datetime]::UtcNow)
        Write-LabJson (Join-Path $dir 'expected.json') ([ordered]@{ written_utc = $expWritten; test_id = $testId; run_no = $run; session = $Session; expected = $case.Expected })
        Write-LabJson (Join-Path $dir 'summary.json') ([ordered]@{ test_id = $testId; run_no = $run; phase = 'expected_before_fault'; session = $Session
                                                                  expected_written_utc = $expWritten; expected = $case.Expected })
        # Tests without a fault (T8-T10) and a -back run with nothing to move need no disturbance
        $disturbed = ($kind -eq 'none' -or -not $faultSteps.Count)
        Sh $tgt 'bash /root/lab/shared/loadgen.sh stop' -AllowFail | Out-Null   # a load left by an aborted run
        Sh (Get-LiveRac) "bash -c 'source /root/lab/lib.sh; sysdba_file /root/lab/sql/99_reset_demo.sql $pdbSrc'" | Out-Null
        # Samplers on the host clock; crs and gg src move to the other RAC node when one goes silent
        $racList = @($rac | ForEach-Object { "$($_.Name)=$($_.PublicIp)" }); $tgtList = @("$($tgt.Name)=$($tgt.PublicIp)")
        foreach ($s in @(@{ M = 'crs'; N = $racList; F = 'raw_crs.txt' }, @{ M = 'gg'; N = $racList; F = 'raw_gg_src.txt'; I = 2 },
                         @{ M = 'gg'; N = $tgtList; F = 'raw_gg_tgt.txt'; I = 2 }, @{ M = 'lag'; N = $tgtList; F = 'raw_lag.txt' })) {
            # Start-Process joins the arguments with spaces: quote every path
            $a = @('-NoProfile', '-File', "`"$(Join-Path $Repo 'tests\sampler.ps1')`"", '-Mode', $s.M, '-Nodes', ($s.N -join ','),
                   '-OutFile', "`"$(Join-Path $dir $s.F)`"", '-StopFile', "`"$stop`"", '-KeyPath', "`"$key`"", '-IntervalSec', "$(if ($s.ContainsKey('I')) { $s.I } else { 1 })")
            $procs += Start-Process pwsh -ArgumentList $a -PassThru -WindowStyle Hidden
        }
        # Load from ggtgt: it survives every RAC fault; one session per service = both redo threads
        $loadCmd = "bash /root/lab/shared/loadgen.sh $LoadRate $loadSec"
        $load = Start-Process ssh -ArgumentList @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-i', $key,
                    "root@$($tgt.PublicIp)", $loadCmd) -PassThru -WindowStyle Hidden `
                    -RedirectStandardOutput (Join-Path $dir 'loadgen.txt') -RedirectStandardError (Join-Path $dir 'loadgen.err')
        Add-CmdLog $tgt.Name "$loadCmd   (background, output in loadgen.txt)" @()
        Start-Sleep -Seconds $case.PreSec
        if ($FilmMode) {
            for ($c = 10; $c -ge 1; $c--) { Write-Host ("`n   >>> {0}  FAULT IN {1,2} s  [{2}]" -f [datetime]::UtcNow.ToString('HH:mm:ss.fff'), $c, $fault.Display); Start-Sleep -Seconds 1 }
        }
        # Fault: t_fault = host time right before the first command
        $tFault = [datetime]::UtcNow
        $marks.Add([pscustomobject]@{ ts_utc = Format-UtcMs $tFault; t_rel_s = '0.000'; mark = "fault: $($fault.Display)" })
        if ($FilmMode) { Write-Host ("`n   ##### {0}  {1} #####`n" -f $tFault.ToString('HH:mm:ss.fff'), $fault.Display) }
        foreach ($f in $faultSteps) {
            switch ($f.Where) {
                'host' { Invoke-HostStep $f }
                'node' {
                    Sh ($rac | Where-Object Name -eq $f.Node) $f.Command -AllowFail | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "fault command failed (rc $LASTEXITCODE): $($f.Display)" }
                }
            }
        }
        # Recovery: a disturbance seen first, then the whole chain on one node (the expected one), processes RUNNING, lag OK
        $deadline = $tFault.AddSeconds($case.TimeoutSec)
        while ([datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 3
            $raw = @(Read-RawLines @((Join-Path $dir 'raw_crs.txt'), (Join-Path $dir 'raw_gg_src.txt'), (Join-Path $dir 'raw_gg_tgt.txt'), (Join-Path $dir 'raw_lag.txt')) |
                     Where-Object { $_.Ts -gt $tFault } | Sort-Object Ts)
            if (-not $disturbed) { $disturbed = Test-Disturbed -Samples @(ConvertTo-StateSamples $raw) -Base $base }
            # T4b: the on-call intervention, once, AfterSec after the fault (t_intervention = host time before the command).
            # Live approval: INTERVENTION READY first (t_intervention_ready), the move only after approve_intervention appears
            if ($iv -and -not $ivDone -and $iv.LiveApproval -and -not $tIvReady -and ([datetime]::UtcNow - $tFault).TotalSeconds -ge $iv.AfterSec) {
                $tIvReady = [datetime]::UtcNow
                $deadline = @($deadline, $tIvReady.AddSeconds($iv.ApprovalTimeoutSec + $case.TimeoutSec - $iv.AfterSec)) | Sort-Object | Select-Object -Last 1
                $marks.Add([pscustomobject]@{ ts_utc = Format-UtcMs $tIvReady; t_rel_s = Format-Rel ($tIvReady - $tFault).TotalSeconds; mark = "intervention ready: $($iv.Display)" })
                Write-Host ("`n   ##### {0}  INTERVENTION READY ({1:F1} s after the fault): waiting up to {2} s for {3} #####" -f $tIvReady.ToString('HH:mm:ss.fff'), ($tIvReady - $tFault).TotalSeconds, $iv.ApprovalTimeoutSec, (Join-Path $dir 'approve_intervention'))
                foreach ($st in @($iv.PSObject.Properties['Steps'] | ForEach-Object Value)) { Write-Host "   #####   $st" }
                Write-Host ''
                continue
            }
            if ($iv -and -not $ivDone -and $iv.LiveApproval -and $tIvReady) {
                $ivApprovedBy = Read-InterventionApproval -Path (Join-Path $dir 'approve_intervention')
                if (-not $ivApprovedBy) {
                    if (([datetime]::UtcNow - $tIvReady).TotalSeconds -ge $iv.ApprovalTimeoutSec) {
                        $ivDone = $true; $notes.Add("intervention not approved within $($iv.ApprovalTimeoutSec) s: $($iv.Display)")
                        Write-Host "   ##### intervention not approved within $($iv.ApprovalTimeoutSec) s: no move #####"
                    } else { Start-Sleep -Seconds 1; continue }   # 3 s loop + 1 s: the move starts within ~4 s of the approval
                }
            }
            if ($iv -and -not $ivDone -and ($tIvReady -and $ivApprovedBy -or -not $iv.LiveApproval) -and ([datetime]::UtcNow - $tFault).TotalSeconds -ge $iv.AfterSec) {
                $ivDone = $true
                $tIntervention = [datetime]::UtcNow
                if ($iv.LiveApproval) { Write-Host ("`n   ##### {0}  INTERVENTION APPROVED by {1}: running on {2} as root #####`n" -f $tIntervention.ToString('HH:mm:ss.fff'), $ivApprovedBy, $iv.Node) }
                $marks.Add([pscustomobject]@{ ts_utc = Format-UtcMs $tIntervention; t_rel_s = Format-Rel ($tIntervention - $tFault).TotalSeconds; mark = "intervention: $($iv.Display)" })
                Write-Host ("   ✋ intervention at {0:F1} s: {1}" -f ($tIntervention - $tFault).TotalSeconds, $iv.Display)
                Sh ($rac | Where-Object Name -eq $iv.Node) $iv.Command -AllowFail | Out-Null
                $ivRc = $LASTEXITCODE
                if ($ivRc -ne 0) { $notes.Add("intervention failed (rc $ivRc): $($iv.Display)") }
                continue
            }
            if (Test-Recovered -State (ConvertTo-BaselineState $raw $cfg) -Disturbed $disturbed -ExpectGgNode $expectGg -LagOkSec $LagOkSec) { $recovered = $true; break }
        }
        if (-not $recovered) { $notes.Add("no recovery within $($case.TimeoutSec) s$(if (-not $disturbed) { ' (no disturbance seen after the fault)' })") }
        $marks.Add([pscustomobject]@{ ts_utc = Format-UtcMs ([datetime]::UtcNow); t_rel_s = Format-Rel ([datetime]::UtcNow - $tFault).TotalSeconds; mark = "recovered=$recovered" })
        Start-Sleep -Seconds $case.PostSec
        $tObserveEnd = [datetime]::UtcNow   # observe_s: fault to the end of the observation (recovery wait + PostSec)
        Stop-Load $load
        # D1: replication catches up after the load stops; compare until equal or 180 s
        $until = [datetime]::UtcNow.AddSeconds(180)
        do {
            $cmp = Get-Compare
            if ($null -eq $cmp) { break }   # the source could not be read on any node: not compared, not "rows differ"
            $seqCheck = @(Get-SeqCheck -Source $cmp.SeqSource -Target $cmp.SeqTarget)
            $verdict = Get-DataVerdict -Tables $cmp.Tables -SeqCheck $seqCheck
            if ($verdict.Ok) { break }
            Start-Sleep -Seconds 10
        } while ([datetime]::UtcNow -lt $until)
        if ($null -eq $cmp) {
            $dataOk = $false; $dataChecked = $false
            $notes.Add('data: compare not run (compare.sh gave no COMPARE line on any RAC node: no open instance)')
            Write-LabJson (Join-Path $dir 'compare.json') ([ordered]@{ ts_utc = Format-UtcMs ([datetime]::UtcNow); data_ok = $null; data_checked = $false
                                                                    reason = 'compare not run: no RAC node with an open instance' })
        } else {
        $dataOk = [bool]$verdict.Ok; $dataChecked = $true
        if (-not $dataOk) { $notes.Add("data: $($verdict.Reason)") }
        Write-LabJson (Join-Path $dir 'compare.json') ([ordered]@{ ts_utc = Format-UtcMs ([datetime]::UtcNow); data_ok = $dataOk; reason = $verdict.Reason
                                                                tables = $cmp.Tables; seq_check = $seqCheck; seq_source = $cmp.SeqSource; seq_target = $cmp.SeqTarget })
        }
    } catch {
        $notes.Add("run error: $($_.Exception.Message)"); Write-Host "ERROR $($_.Exception.Message)"
        $harnessError = -not $refused   # a script fault, not a cluster result (the video tells them apart)
        if ($refused) { $notes.Add('refused: the lab is not in the base state, no fault was injected') }
    } finally {
        New-Item -ItemType File -Path $stop -Force | Out-Null
        foreach ($p in $procs) { if (-not $p.WaitForExit(15000)) { $p.Kill($true) } }
        if ($load -and -not $load.HasExited) { Stop-Load $load }
        Stop-Transcript | Out-Null
    }
    # Evidence files (failed runs too, film D4); a refused run has no fault event
    $rawAll = @(Read-RawLines @(Get-ChildItem $dir -Filter 'raw_*.txt' | ForEach-Object FullName))
    $faultEv = @(if (-not $refused) { [pscustomobject]@{ Ts = $tFault; Resource = 'fault'; Node = $fault.Node; State = 'injected'; Source = 'host'; Raw = (Protect-Text $fault.Display $secrets) } })
    $events = @(Get-StateChanges -Samples (@($faultEv) + @(ConvertTo-StateSamples $rawAll)) -FaultUtc $tFault -TestId $testId -RunNo $run)
    $lag = @(ConvertTo-LagRows $rawAll $tFault)
    Write-LabCsv (Join-Path $dir 'events.csv') $events
    Write-LabCsv (Join-Path $dir 'lag.csv') $lag
    Write-LabCsv (Join-Path $dir 'load.csv') @(ConvertTo-LoadRows $rawAll $tFault)
    Write-LabCsv (Join-Path $dir 'film_marks.csv') @($marks)
    $markers = if ($refused) { [ordered]@{ t_fault = $null } } else { Get-Markers -Events $events -Lag $lag -LagOkSec $LagOkSec }
    if ($iv -and -not $refused) {
        if ($iv.LiveApproval) { $markers['t_intervention_ready'] = if ($tIvReady) { [math]::Round(($tIvReady - $tFault).TotalSeconds, 3) } else { $null } }
        $markers['t_intervention'] = if ($tIntervention) { [math]::Round(($tIntervention - $tFault).TotalSeconds, 3) } else { $null }
    }
    # A6: the intervention as a ✋ line in agent_notes.md (the agent adds the reason in its own words if it wants)
    if ($tIntervention) {
        $an = Join-Path $dir 'agent_notes.md'
        $who = if ($iv.LiveApproval) { "agent za zgodą: $ivApprovedBy" } else { 'automat testów' }
        $line = "- ✋ t_rel_s={0:F3} [{4} root] ``{1}`` (rc {2}; {5}) · {3}: dyżurny przenosi GoldenGate na węzeł serwisu" -f ($tIntervention - $tFault).TotalSeconds, $iv.Display, $ivRc, $testId, $iv.Node, $who
        Write-LabText $an (([IO.File]::ReadAllText($an)) -replace '(<!-- jedna linia na interwencję[^\n]*-->)', "`$1`n$line")
    }
    $intervals = [ordered]@{}
    foreach ($f in Get-ChildItem $dir -Filter 'raw_*.txt') {
        $intervals[$f.BaseName] = Get-SampleIntervalStats @(Read-RawLines @($f.FullName) | Where-Object { $_.Line -like 'TICK*' } | ForEach-Object Ts)
    }
    $baseGg = if ($base) { $base.GgNode } else { $null }; $baseSvc = if ($base) { $base.ServiceNode } else { $null }
    $smEv = @($events | Where-Object resource -eq 'sm')
    $evicted = @($events | Where-Object { $_.resource -like 'node:*' -and $_.state_to -ne 'Active' } | ForEach-Object node | Select-Object -Unique)
    $smUps = @($smEv | Where-Object { $_.state_to -eq 'ONLINE' -and $_.state_from })
    $pass = [bool]($recovered -and $dataOk -and -not $refused)
    $extra = [ordered]@{
        stage = $cfg.Ogg.HaStage; synthetic = $false; title = $case.Title
        # video: which lab configuration and harness version, which variant, how long the run was watched
        config_rev = $configRev; harness_commit = $harnessCommit
        test_variant = if ($case.ContainsKey('Variant')) { $case.Variant } else { $null }
        observe_s = if ($tObserveEnd) { [math]::Round(($tObserveEnd - $tFault).TotalSeconds, 1) } else { $null }
        intervention_command = if ($iv) { $iv.Display } else { $null }
        intervention_rc = $ivRc
        intervention_node = if ($iv) { "$($iv.Node) root" } else { $null }
        intervention_steps = if ($iv) { @($iv.PSObject.Properties['Steps'] | ForEach-Object Value) } else { $null }
        intervention_invoked_by = if (-not $iv) { $null } elseif ($iv.LiveApproval) { 'agent' } else { 'harness' }
        intervention_approved_by = if ($iv -and $iv.LiveApproval) { $ivApprovedBy } elseif ($iv) { $ApprovedBy } else { $null }
        approval_wait_s = if ($tIvReady -and $tIntervention) { [math]::Round(($tIntervention - $tIvReady).TotalSeconds, 1) } else { $null }
        versions = [ordered]@{ binaries = @(Get-BinaryStatus -Config $cfg | ForEach-Object { "$($_.Kind)=$($_.Version)" }) }
        fault_kind = $kind; fault_command = (Protect-Text ((@($faultSteps | ForEach-Object Display) -join ' ; ')) $secrets)
        final_node = if ($smEv.Count) { $smEv[-1].node } else { $baseGg }
        expected_gg_node = $expectGg
        evicted_node = ($evicted -join ',')
        xag_action = if (-not $smUps.Count) { 'none' } elseif ($smUps[-1].node -eq $baseGg) { 'restart_in_place' } else { 'relocate' }
        xag_restarts = $smUps.Count
        service_moved = [bool](@($events | Where-Object { $_.resource -eq 'svc' -and $_.node -ne $baseSvc -and $_.node -ne '-' }).Count)
        sample_interval_s = [ordered]@{ declared = [ordered]@{ crs = 1; gg = 2; lag = 1 }; measured = $intervals }
        clock_offsets_ms = $offsets
        refused = $refused; disturbed = $disturbed; recovered = $recovered; data_ok = $dataOk; data_checked = $dataChecked; pass = $pass
        harness_error = $harnessError; attempt = $attempt
        measurement_error = $null   # set by hand afterwards when a probe measured wrong (T1 16.11: lag); the video skips the run
        invoked_by = $InvokedBy; approved_by = $ApprovedBy
        notes = @($notes | Where-Object { $_ })
    }
    $summary = Get-RunSummary -Markers $markers -TestId $testId -RunNo $run -Lag $lag -LagOkSec $LagOkSec -Extra $extra
    # A4: expectation vs result; A5: session
    $em = if ($refused) { [pscustomobject]@{ match = $null; checks = @() } }
          else { Get-ExpectedMatch -Expected $case.Expected -Actual @{ FinalNode = $summary.final_node; Recovered = $recovered; DataOk = $(if ($dataChecked) { $dataOk } else { $null }); RtoS = $summary.rto_s } }
    if ($harnessError) { $em.match = $null }   # the run did not finish: nothing to compare with the expectation
    $expAt = if (Get-Variable expWritten -ErrorAction Ignore) { $expWritten } else { $null }
    foreach ($kv in @(@('session', $Session), @('expected', $case.Expected), @('expected_written_utc', $expAt),
                      @('expected_match', $em.match), @('expected_check', @($em.checks)), @('agent_notes', 'agent_notes.md'))) {
        $summary | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force
    }
    Write-LabJson (Join-Path $dir 'summary.json') $summary
    # S1: every command with ts_utc, t_rel_s and its output (masked)
    Write-LabText (Join-Path $dir 'commands.txt') (Protect-Text ((Format-CommandLog -Entries @($script:CmdLog) -FaultUtc $tFault) -join "`n") $secrets)
    # S2: log excerpts from the nodes that answer (masked)
    $logDir = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'logs')
    foreach ($n in @($rac) + @($tgt)) {
        $txt = @(Sh $n "for f in /u01/app/grid/diag/crs/*/crs/trace/alert.log /u01/app/oracle/diag/rdbms/*/*/trace/alert_*.log /u01/app/grid/diag/crs/*/crs/trace/*goldengate*.trc $($cfg.Ogg.DeployRoot)/*/var/log/ggserr.log; do [ -f `$f ] && { echo `"== `$f`"; tail -n 300 `$f; }; done" -AllowFail -NoLog) -join "`n"
        if ($txt) { Write-LabText (Join-Path $logDir "$($n.Name).txt") (Protect-Text $txt $secrets) }
    }
    $tr = Join-Path $dir 'transcript.txt'
    if (Test-Path $tr) { Write-LabText $tr (Protect-Text ([IO.File]::ReadAllText($tr)) $secrets) }
    # Back to the base state after every run, its duration in the same run directory (film: what the return costs)
    $baseOk = $true
    if (-not $NoBaseline) {
        Write-Host "== $testId run ${run}: lab.cmd baseline"
        $tb = [datetime]::UtcNow
        $bout = @(& pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') baseline 2>&1 | ForEach-Object { "$_" })
        $baseOk = ($LASTEXITCODE -eq 0)
        $bsec = [math]::Round(([datetime]::UtcNow - $tb).TotalSeconds, 1)
        Write-LabText (Join-Path $dir 'back_to_base.txt') (Protect-Text ($bout -join "`n") $secrets)
        $phases = @(foreach ($l in $bout) { if ($l -match '^\s*\[([^\]]+)\]\s+BASELINE ') { ConvertFrom-BaselineLines -Node $Matches[1] -Lines @($l) } })
        Write-LabJson (Join-Path $dir 'back_to_base.json') ([ordered]@{ seconds = $bsec; ok = $baseOk; phases = $phases })
        $summary | Add-Member -NotePropertyName back_to_base_s -NotePropertyValue $bsec -Force
        $summary | Add-Member -NotePropertyName back_to_base_ok -NotePropertyValue $baseOk -Force
        Write-LabJson (Join-Path $dir 'summary.json') $summary
        Write-Host "== back to base: ok=$baseOk in $bsec s"
    }
    # D3: aggregate every summary.json under results/ (sample excluded)
    $all = @(Get-ChildItem (Join-Path $Repo 'results') -Recurse -Filter 'summary.json' | Where-Object FullName -notmatch '\\sample\\' |
             ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    Write-LabCsv (Join-Path $Repo 'results\summary_all.csv') @(Get-SummaryAll $all)
    Write-TestJournal -Root (Join-Path $Repo 'results')   # for Kris: one row per run
    Write-Host ("== {0} run {1}: pass={2} refused={3} rto_s={4} ({5}) data_ok={6} expected_match={7} final_node={8} -> {9}" -f $testId, $run, $pass, $refused, $summary.rto_s, $summary.rto_basis, $dataOk, $em.match, $summary.final_node, $dir)
    if (-not $pass) { $failedRuns++ }
    if ($refused) { Write-Host "STOP: run $run refused (lab not in the base state), runs $($run + 1)..$Repeat not started"; break }
    # lab.cmd baseline above already put the lab back (powered-off VMs and a cut link too); without it the next run stops
    if (-not $baseOk -and $run -lt $Repeat) { Write-Host "STOP: lab.cmd baseline failed after run $run (back_to_base.txt), runs $($run + 1)..$Repeat not started"; $failedRuns++; break }
}
exit ([int]($failedRuns -gt 0))
