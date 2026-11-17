# ==============================================================================
# Tytul:        Evidence.psm1
# Opis:         Dowody z testow awarii (wymagania do filmu): katalog wyniku, zmiany stanu z probek
#               (events.csv), znaczniki t_* liczone z events.csv i lag.csv, odcinki lancucha i RTO
#               (summary.json), statystyki odstepu probek, maskowanie transkryptu, summary_all.csv.
#               Jeden zegar: host, UTC, milisekundy. Pliki UTF-8 bez BOM, LF.
# Description [EN]: Evidence of the failure tests (video requirements): result directory, state
#               changes from samples (events.csv), t_* markers computed from events.csv and lag.csv,
#               chain segments and RTO (summary.json), sample interval stats, transcript masking,
#               summary_all.csv. One clock: the host, UTC, milliseconds. UTF-8 without BOM, LF.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.8 (dziennik: polskie przyczyny krokow DDL T10); 1.7 (t_lag_ok = pierwszy trwaly powrot ponizej progu, lag_relapses; dziennik z T4b, "blad automatu"); 1.6 (znaczniki spoza lancucha, np. t_intervention, w segments_measured; nota T4b); 1.5 (segments_measured: odcinki w zmierzonej kolejnosci znacznikow); 1.4 (znaczniki przy zmianie wezla, odcinki w odwrotnej kolejnosci, uwagi PL w dzienniku, measurement_error; 1.3: bez bledow indeksu w Get-Markers, porownanie nie zrobione = nie porownywane; 1.2: A4 Get-ExpectedMatch, A6 Get-InterventionCount, dziennik Write-TestJournal)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7; uzywa go tests/run_test.ps1
# Requirements [EN]: - PowerShell 7; used by tests/run_test.ps1
#
# Uzycie [PL]:       Import-Module host\Evidence.psm1; Get-Markers -Events $e -Lag $l -LagOkSec 30
# Usage [EN]:        Import-Module host\Evidence.psm1; Get-Markers -Events $e -Lag $l -LagOkSec 30
# ==============================================================================
Set-StrictMode -Version Latest
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# Chain order (film E2) and the marker each resource sets when it comes back
$script:Chain = @(
    @{ Resource = 'svc';  State = 'ONLINE';  Marker = 't_service_online' }
    @{ Resource = 'acfs'; State = 'ONLINE';  Marker = 't_acfs_online' }
    @{ Resource = 'vip';  State = 'ONLINE';  Marker = 't_vip_online' }
    @{ Resource = 'sm';   State = 'ONLINE';  Marker = 't_sm_running' }
    @{ Resource = 'EXT1'; State = 'RUNNING'; Marker = 't_ext_running' }
    @{ Resource = 'DP1';  State = 'RUNNING'; Marker = 't_dp_running' }
    @{ Resource = 'REP1'; State = 'RUNNING'; Marker = 't_rep_running' }
)
$script:MarkerOrder = @('t_fault', 't_crs_detect', 't_service_online', 't_acfs_online', 't_vip_online', 't_sm_running',
                        't_ext_running', 't_dp_running', 't_rep_running', 't_lag_ok')
$script:SegmentNames = @('fault_to_detect', 'detect_to_service', 'service_to_acfs', 'acfs_to_vip', 'vip_to_sm',
                         'sm_to_ext', 'ext_to_dp', 'dp_to_rep', 'rep_to_lag_ok')
$script:DownStates = @('OFFLINE', 'UNKNOWN', 'INTERMEDIATE', 'STOPPED', 'ABENDED', 'UNREACHABLE')

function Format-UtcMs([datetime]$Ts) { $Ts.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $script:Inv) }
function Format-Rel([double]$Sec) { $Sec.ToString('F3', $script:Inv) }
function ConvertTo-Num($v) { if ($null -eq $v -or "$v" -eq '') { $null } else { [double]::Parse("$v", $script:Inv) } }

# results/<TestId>-<yyyyMMdd-HHmmss>/ ; an existing directory is never reused (D4)
function New-EvidenceDir([string]$TestId, [string]$Root) {
    $dir = Join-Path $Root ("{0}-{1}" -f $TestId, (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
    if (Test-Path $dir) { $dir += '-' + [guid]::NewGuid().ToString('N').Substring(0, 4) }
    New-Item -ItemType Directory -Path $dir | Out-Null
    $dir
}

# Samples (Ts, Resource, Node, State, Source, Raw) -> state changes only (film E1): the first state of
# each resource, then a row whenever its state or node changes.
function Get-StateChanges {
    param([object[]]$Samples, [datetime]$FaultUtc, [string]$TestId, [int]$RunNo)
    $last = @{}
    foreach ($s in @($Samples | Sort-Object Ts)) {
        $key = $s.Resource
        $prev = $last[$key]
        if ($prev -and $prev.State -eq $s.State -and $prev.Node -eq $s.Node) { continue }
        [pscustomobject][ordered]@{
            ts_utc = Format-UtcMs $s.Ts
            t_rel_s = Format-Rel ($s.Ts.ToUniversalTime() - $FaultUtc.ToUniversalTime()).TotalSeconds
            test_id = $TestId; run_no = $RunNo; resource = $s.Resource; node = $s.Node
            state_from = if ($prev) { $prev.State } else { '' }; state_to = $s.State; source = $s.Source; raw = $s.Raw
        }
        $last[$key] = $s
    }
}

function Get-SampleIntervalStats([datetime[]]$Times) {
    $t = @($Times | Sort-Object)
    $d = @(for ($i = 1; $i -lt $t.Count; $i++) { ($t[$i] - $t[$i - 1]).TotalSeconds }) | Sort-Object
    if (-not $d.Count) { return [pscustomobject]@{ samples = $t.Count; median_s = $null; max_s = $null } }
    $mid = [int][math]::Floor($d.Count / 2)
    $median = if ($d.Count % 2) { $d[$mid] } else { ($d[$mid - 1] + $d[$mid]) / 2 }
    [pscustomobject]@{ samples = $t.Count; median_s = [math]::Round($median, 3); max_s = [math]::Round($d[-1], 3) }
}

function Get-LagAfterFault([object[]]$Lag, $FaultRel) {
    @($Lag | ForEach-Object { [pscustomobject]@{ rel = ConvertTo-Num $_.t_rel_s; lag = ConvertTo-Num $_.lag_s } } |
      Where-Object { $null -ne $_.rel -and $null -ne $_.lag -and ($null -eq $FaultRel -or $_.rel -ge $FaultRel) } | Sort-Object rel)
}
function Get-LagOkRel([object[]]$Lag, [double]$LagOkSec, [double]$LagStableSec) {
    $first = $Lag | Where-Object { $_.lag -ge $LagOkSec } | Select-Object -First 1
    if (-not $first) { return $null }
    foreach ($c in @($Lag | Where-Object { $_.rel -gt $first.rel -and $_.lag -lt $LagOkSec })) {
        $again = $Lag | Where-Object { $_.rel -gt $c.rel -and $_.rel -le $c.rel + $LagStableSec -and $_.lag -ge $LagOkSec } | Select-Object -First 1
        if (-not $again) { return $c.rel }
    }
    $null
}

# Markers in seconds relative to t_fault, computed from events.csv and lag.csv rows (film E3).
function Get-Markers {
    param([object[]]$Events, [object[]]$Lag, [double]$LagOkSec = 30, [double]$LagStableSec = 20)
    $m = [ordered]@{}; foreach ($k in $script:MarkerOrder) { $m[$k] = $null }
    $ev = @($Events | ForEach-Object { $_ | Add-Member -NotePropertyName rel -NotePropertyValue (ConvertTo-Num $_.t_rel_s) -Force -PassThru } | Sort-Object rel)
    # node_from: the node of the previous event of the same resource (T1: svc ONLINE -> ONLINE on another node is a move)
    $lastNode = @{}
    foreach ($e in $ev) { $e | Add-Member -NotePropertyName node_from -NotePropertyValue $lastNode["$($e.resource)"] -Force; $lastNode["$($e.resource)"] = $e.node }
    # StrictMode: @(...)[0] on an empty array is an error, Select-Object -First 1 gives $null
    $fault = $ev | Where-Object resource -eq 'fault' | Select-Object -First 1
    if (-not $fault) { throw 'events.csv has no fault event' }
    $m.t_fault = $fault.rel
    $after = @($ev | Where-Object { $_.rel -ge $fault.rel -and $_.resource -ne 'fault' })
    # Detection: a node leaving the cluster; without one (abort, kill) the first chain resource going down
    $node = $after | Where-Object { $_.resource -like 'node:*' -and $_.state_to -ne 'Active' } | Select-Object -First 1
    $down = $after | Where-Object { $_.resource -match '^(inst:.*|svc|acfs|vip|sm|EXT1|DP1)$' -and $_.state_to -in $script:DownStates } | Select-Object -First 1
    $det = if ($node) { $node } else { $down }
    if ($det) { $m.t_crs_detect = $det.rel }
    foreach ($c in $script:Chain) {
        $hit = $after | Where-Object { $_.resource -eq $c.Resource -and $_.state_to -eq $c.State -and $_.state_from -and
                                       ($_.state_from -ne $c.State -or ($_.node_from -and $_.node_from -ne '-' -and $_.node -ne '-' -and $_.node_from -ne $_.node)) } |
               Select-Object -First 1
        if ($hit) { $m[$c.Marker] = $hit.rel }
    }
    # Lag OK: the first sample below the threshold after the first one at or above it that is not followed by
    # another high sample within LagStableSec (a dip inside the outage is no return). Later high samples are
    # relapses (Get-RunSummary: lag_relapses), not the recovery: T3 16.11 had one sample of 34 s at 343.5 s and
    # the old rule (after the LAST high sample) gave t_lag_ok 344.6 s instead of 40.3 s
    $lag = @(Get-LagAfterFault -Lag $Lag -FaultRel $m.t_fault)
    $t = Get-LagOkRel -Lag $lag -LagOkSec $LagOkSec -LagStableSec $LagStableSec
    if ($null -ne $t) { $m.t_lag_ok = $t }
    $m
}

# summary.json body (film D2): markers, segments, RTO, lag maximum, threshold.
function Get-RunSummary {
    param([System.Collections.IDictionary]$Markers, [string]$TestId, [int]$RunNo, [object[]]$Lag, [double]$LagOkSec = 30, [hashtable]$Extra = @{})
    # A pair in reverse order (T1: DP1 RUNNING before EXT1 RUNNING) is no segment: named in segments_out_of_order
    $rev = [System.Collections.Generic.List[string]]::new()
    $seg = for ($i = 0; $i -lt $script:SegmentNames.Count; $i++) {
        $a = $Markers[$script:MarkerOrder[$i]]; $b = $Markers[$script:MarkerOrder[$i + 1]]
        if ($null -ne $a -and $null -ne $b) {
            if ($b -lt $a) { $rev.Add($script:SegmentNames[$i]); continue }
            [pscustomobject]@{ name = $script:SegmentNames[$i]; seconds = [math]::Round($b - $a, 3) }
        }
    }
    # Measured order (16.11): markers present, sorted by time (a tie keeps the chain order), consecutive pairs
    # Extra markers outside the chain (T4b: t_intervention) take part here only, after the chain ones on a tie
    $keys = @($script:MarkerOrder) + @($Markers.Keys | Where-Object { $_ -notin $script:MarkerOrder })
    $present = @($(for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]
        if ($Markers.Contains($k) -and $null -ne $Markers[$k]) { [pscustomobject]@{ key = $k; t = [double]$Markers[$k]; idx = $i } }
    }) | Sort-Object t, idx)
    $measured = for ($i = 0; $i -lt $present.Count - 1; $i++) {
        $a = $present[$i]; $b = $present[$i + 1]
        [pscustomobject][ordered]@{
            name = '{0}_to_{1}' -f $a.key.Substring(2), $b.key.Substring(2)
            from = $a.key; to = $b.key
            from_t_rel_s = $a.t; to_t_rel_s = $b.t
            seconds = [math]::Round($b.t - $a.t, 3)
        }
    }
    # RTO to the Replicat restart when it had an outage, else to lag OK, else to the Extract restart
    $basis = foreach ($k in 'rep_running', 'lag_ok', 'ext_running') { if ($null -ne $Markers["t_$k"]) { $k; break } }
    $lagAfter = @($Lag | Where-Object { (ConvertTo-Num $_.t_rel_s) -ge $Markers.t_fault } | ForEach-Object { ConvertTo-Num $_.lag_s })
    # Relapses: lag at or above the threshold again after t_lag_ok (one per crossing), reported apart from the RTO
    $relapses = @(); $prevHigh = $false
    if ($null -ne $Markers['t_lag_ok']) {
        foreach ($p in @(Get-LagAfterFault -Lag $Lag -FaultRel $Markers.t_lag_ok)) {
            $high = $p.lag -ge $LagOkSec
            if ($high -and -not $prevHigh) { $relapses += $p.rel }
            $prevHigh = $high
        }
    }
    $s = [ordered]@{
        test_id = $TestId; run_no = $RunNo
        markers = $Markers
        segments = @($seg)
        segments_out_of_order = @($rev)
        segments_measured = @($measured)
        rto_s = if ($basis) { [math]::Round($Markers["t_$basis"] - $Markers.t_fault, 3) } else { $null }
        rto_basis = $basis
        lag_max_s = if ($lagAfter.Count) { ($lagAfter | Measure-Object -Maximum).Maximum } else { $null }
        lag_ok = [ordered]@{ seconds = $LagOkSec; source = 'target heartbeat view (ggadmin.gg_lag)' }
        lag_jump = [bool]($lagAfter | Where-Object { $_ -ge $LagOkSec })
        lag_relapses = $relapses.Count
        lag_relapse_first_s = if ($relapses.Count) { $relapses[0] } else { $null }
    }
    foreach ($k in $Extra.Keys) { $s[$k] = $Extra[$k] }
    [pscustomobject]$s
}

# Masks secrets and Windows user paths (film S1 and the public-content rule).
function Protect-Text([string]$Text, [string[]]$Secrets) {
    foreach ($s in @($Secrets | Where-Object { $_ })) { $Text = $Text.Replace($s, '********') }
    $Text -replace '(?i)\b[A-Z]:\\Users\\[^\\\s"'']+', 'C:\Users\<user>'
}

# summary_all.csv rows (film D3): median, min, max per test over every run, failed ones included.
function Get-SummaryAll([object[]]$Runs) {
    foreach ($g in @($Runs | Group-Object test_id | Sort-Object Name)) {
        $r = @($g.Group | Where-Object { $null -ne $_.rto_s } | ForEach-Object { [double]$_.rto_s } | Sort-Object)
        $med = $null
        if ($r.Count) { $mid = [int][math]::Floor($r.Count / 2); $med = if ($r.Count % 2) { $r[$mid] } else { ($r[$mid - 1] + $r[$mid]) / 2 } }
        [pscustomobject][ordered]@{
            test_id = $g.Name; runs = $g.Count; passed = @($g.Group | Where-Object { $_.pass -eq $true }).Count
            rto_median_s = $med; rto_min_s = if ($r.Count) { $r[0] } else { $null }; rto_max_s = if ($r.Count) { $r[-1] } else { $null }
            lag_max_s = (@($g.Group | ForEach-Object { $_.lag_max_s } | Where-Object { $null -ne $_ }) | Measure-Object -Maximum).Maximum
            # video: A4 matches among comparable runs, back-to-base durations
            expected_match = "$(@($g.Group | Where-Object { $_.PSObject.Properties['expected_match'] -and $_.expected_match -eq $true }).Count)/$(@($g.Group | Where-Object { $_.PSObject.Properties['expected_match'] -and $null -ne $_.expected_match }).Count)"
            back_to_base_max_s = (@($g.Group | Where-Object { $_.PSObject.Properties['back_to_base_s'] -and $null -ne $_.back_to_base_s } | ForEach-Object { [double]$_.back_to_base_s }) | Measure-Object -Maximum).Maximum
        }
    }
}

# A4 (video): expectation vs result. 'nie wiemy' / 'nie dotyczy' are not compared; match = $null when nothing is.
function Get-ExpectedMatch {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Expected, [Parameter(Mandatory)][hashtable]$Actual)
    $known = { param($v) $null -ne $v -and "$v" -notin 'nie wiemy', 'nie dotyczy', '' }
    $checks = @(
        if (& $known $Expected.FinalNode) { [pscustomobject]@{ field = 'final_node'; expected = $Expected.FinalNode; actual = $Actual.FinalNode; match = ($Actual.FinalNode -eq $Expected.FinalNode) } }
        if ($Expected.Recovers -is [bool]) { [pscustomobject]@{ field = 'recovers'; expected = $Expected.Recovers; actual = [bool]$Actual.Recovered; match = ([bool]$Actual.Recovered -eq $Expected.Recovers) } }
        # DataOk $null = no compare was made (harness error before it): shown, not compared
        if ("$($Expected.DataLoss)" -eq '0') { [pscustomobject]@{ field = 'data_loss'; expected = 0; actual = $(if ($null -eq $Actual.DataOk) { 'compare not run' } elseif ($Actual.DataOk) { 0 } else { 'rows differ' }); match = $(if ($null -eq $Actual.DataOk) { $null } else { [bool]$Actual.DataOk }) } }
        if ($Expected.RtoS -is [int] -or $Expected.RtoS -is [double]) {
            [pscustomobject]@{ field = 'rto_s'; expected = "<= $($Expected.RtoS)"; actual = $Actual.RtoS; match = ($null -ne $Actual.RtoS -and [double]$Actual.RtoS -le [double]$Expected.RtoS) }
        }
    )
    $cmp = @($checks | Where-Object { $null -ne $_.match })
    [pscustomobject]@{ match = $(if ($cmp.Count) { -not @($cmp | Where-Object { -not $_.match }).Count } else { $null }); checks = $checks }
}
# A6: manual interventions = lines "- ✋ ..." in agent_notes.md
function Get-InterventionCount([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    @([IO.File]::ReadAllLines($Path) | Where-Object { $_ -match '^\s*-\s*✋' }).Count
}
# Notes stay English in summary.json (code and data); the journal for Kris shows them in Polish (Kris 16.11).
# An unknown note stays as it is.
$script:CaseNotesPl = @{
    'Check whether agctl relocate moved gg_srcpdb (notes).' = 'Sprawdź, czy agctl relocate przeniósł gg_srcpdb.'
    'Start ggrac1 again before T2-back.' = 'Przed T2-back uruchomić ggrac1.'
    'GoldenGate should stay on ggrac1; record lag_jump.' = 'GoldenGate powinien zostać na ggrac1; zapisać lag_jump.'
    'Same segment list as T2.' = 'Te same odcinki co w T2.'
    'As T4, then after 120 s by hand: GoldenGate moved to ggrac2 (agctl relocate or start).' = 'Jak T4, a po 120 s ręcznie: GoldenGate przeniesiony na ggrac2 (agctl relocate albo start).'
    'Record what XAG did: restart in place or relocate.' = 'Zapisać, co zrobił XAG: restart na miejscu czy przeniesienie.'
    'Manual step before: Critical to deployment health ON for EXT1 (Web UI); export the profile before and after.' = 'Ręcznie przed testem: Critical to deployment health ON dla EXT1 (Web UI); eksport profilu przed i po.'
    'setlinkstate3 on afterwards; record evicted_node.' = 'Po teście setlinkstate3 on; zapisać evicted_node.'
    'Baseline under load, 10 minutes.' = 'Obciążenie bazowe, 10 minut.'
    'Runs after every test; here on its own.' = 'Działa po każdym teście; tu osobno.'
    'DDL steps of TESTS.md T10 by hand during PostSec (LAB: automate after the first run).' = 'Kroki DDL z TESTS.md T10 ręcznie w czasie PostSec (LAB: zautomatyzować po pierwszym przebiegu).'
    'DDL steps of TESTS.md T10 run by the test automation (t10_steps.log).' = 'Kroki DDL z TESTS.md T10 wykonuje automat testów (t10_steps.log).'
}
function ConvertTo-PolishNote([string]$Note) {
    if ($script:CaseNotesPl.ContainsKey($Note)) { return $script:CaseNotesPl[$Note] }
    $n = $Note
    $n = $n -replace '^no recovery within (\d+) s', 'brak powrotu w ciągu $1 s' -replace ' \(no disturbance seen after the fault\)', ' (po awarii nie widać zakłócenia)'
    $n = $n -replace '^refused: the lab is not in the base state, no fault was injected$', 'odmowa: lab nie był w stanie bazowym, awarii nie wywołano'
    $n = $n -replace '^run error: lab is not in the base state, the test does not start: ', 'błąd automatu: lab nie jest w stanie bazowym, test nie startuje: '
    $n = $n -replace '^run error: ', 'błąd automatu: '
    # Deviations of Test-BaselineState (host/Tests.psm1)
    $n = $n -replace "(\w+) is '([^']*)', base state is (\w+)", "`$1 = '`$2', w stanie bazowym `$3" -replace '\b(\w+) is missing\b', 'brak $1' `
            -replace '\blag is ([\d.]*) s \(threshold ([\d.]+) s\)', 'lag $1 s (próg $2 s)' -replace '\b(EXT1|DP1|REP1) is (\w+)\b', '$1 w stanie $2'
    if ($n -match '^data: ') {
        $n = $n -replace '^data: ', 'dane: ' -replace 'tables differ: ', 'różne tabele: ' -replace 'no compare result', 'brak wyniku porównania' `
                -replace 'no load rows on the source \(loadgen did not write\)', 'brak wierszy obciążenia na źródle (loadgen nie pisał)' `
                -replace 'SEQ check: ', 'kontrola SEQ: ' -replace '\bmissing\b', 'brakuje' -replace '\bextra\b', 'nadmiarowe' -replace '\bduplicates\b', 'duplikaty'
    }
    # T10 DDL steps (Get-T10Verdict, host/Tests.psm1)
    $n = $n -replace '^DDL steps did not run: ', 'kroki DDL niewykonane: ' -replace '^DDL steps failed: ', 'kroki DDL nieudane: ' `
            -replace '^DDL steps: values differ$', 'kroki DDL: różne wartości' -replace 'skipped after a failed step', 'pominięty po nieudanym kroku' `
            -replace ' not seen within (\d+) s', ' niewidoczne w ciągu $1 s' -replace 'values differ: ', 'różne wartości: '
    $n
}
# Journal for Kris (results/DZIENNIK_TESTOW.md), rebuilt from every summary.json after each run; it carries the clock time
# (internal file), the film uses durations only
function Write-TestJournal([string]$Root) {
    # a relative -Root is resolved against the PowerShell location, not [Environment]::CurrentDirectory (test session 16.11)
    $Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
    $rows = foreach ($d in @(Get-ChildItem $Root -Directory | Where-Object { $_.Name -match '^(T\d+b?(?:-back)?)-(\d{8}-\d{6})' -and (Test-Path (Join-Path $_.FullName 'summary.json')) })) {
        $null = $d.Name -match '^(T\d+b?(?:-back)?)-(\d{8}-\d{6})'
        $utc = [datetime]::ParseExact($Matches[2], 'yyyyMMdd-HHmmss', $null, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        $s = Get-Content -Raw (Join-Path $d.FullName 'summary.json') | ConvertFrom-Json
        $p = { param($n) if ($s.PSObject.Properties[$n]) { $s.$n } else { $null } }
        # A measurement error marked afterwards wins: a refusal caused by a wrong probe is no refusal of the lab
        $res = if (& $p 'measurement_error') { "⚠️ błąd pomiaru ($(& $p 'measurement_error'))" } elseif (& $p 'refused') { '⛔ odmowa' } elseif (& $p 'harness_error') { '⚠️ błąd automatu' } elseif ((& $p 'phase') -eq 'expected_before_fault') { '⛔ przerwany' } elseif (& $p 'pass') { '✅ zaliczony' } else { '❌ niezaliczony' }
        $em = & $p 'expected_match'
        $notes = @(& $p 'notes') | Where-Object { $_ } | Select-Object -First 2 | ForEach-Object { ConvertTo-PolishNote $_ }
        # string interpolation is culture-invariant (81.5, not 81,5 on a Polish Windows)
        [pscustomobject]@{ Utc = $utc; Line = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | `{12}` |',
            $utc.ToLocalTime().ToString('dd.MM HH:mm'), (& $p 'test_id'), (& $p 'run_no'), $res,
            $(if ($null -ne (& $p 'rto_s')) { & $p 'rto_s' } else { '–' }),
            $(if ($em -eq $true) { 'tak' } elseif ($em -eq $false) { '**nie**' } else { '–' }),
            $(if (& $p 'final_node') { & $p 'final_node' } else { '–' }),
            $(if (& $p 'data_ok') { '0 straconych' } elseif ((& $p 'refused') -or (& $p 'data_checked') -eq $false -or (& $p 'phase') -eq 'expected_before_fault') { 'nie sprawdzone' } else { 'różnice' }),
            $(if ($null -ne (& $p 'back_to_base_s')) { & $p 'back_to_base_s' } else { '–' }),
            (Get-InterventionCount (Join-Path $d.FullName 'agent_notes.md')),
            $(if (& $p 'session') { & $p 'session' } else { '–' }),
            (($notes -join '; ') -replace '\|', '/'), "results/$($d.Name)") }
    }
    $head = @('# 🧪 Dziennik testów T1–T10', '',
              '> 🎯 Jeden wiersz na przebieg, od najnowszego. Plik odbudowuje `tests/run_test.ps1` po każdym przebiegu z `summary.json` i `agent_notes.md`.', '',
              '| Kiedy | Test | Przebieg | Wynik | RTO s | Zgodne z oczekiwaniem | Węzeł GG na końcu | Dane | Powrót do bazy s | Interwencje | Sesja | Uwagi | Katalog |',
              '|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    Write-LabText (Join-Path $Root 'DZIENNIK_TESTOW.md') ((@($head) + @($rows | Sort-Object Utc -Descending | ForEach-Object Line)) -join "`n")
}

function Write-LabText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
function Write-LabCsv([string]$Path, [object[]]$Rows) {
    if (-not @($Rows).Count) { Write-LabText $Path ''; return }
    Write-LabText $Path (((@($Rows) | ConvertTo-Csv -UseQuotes AsNeeded) -join "`n") + "`n")
}
function Write-LabJson([string]$Path, $Object) { Write-LabText $Path (($Object | ConvertTo-Json -Depth 8) + "`n") }

# Film S1: command log, one line per command ("<ts_utc> t_rel_s=<s> [<node>] $ <command>"), output indented
function Format-CommandLog([object[]]$Entries, [datetime]$FaultUtc) {
    foreach ($e in @($Entries | Where-Object { $_ } | Sort-Object Ts)) {
        '{0} t_rel_s={1} [{2}] $ {3}' -f (Format-UtcMs $e.Ts), (Format-Rel ($e.Ts - $FaultUtc).TotalSeconds), $e.Node, $e.Command
        foreach ($l in @($e.Output)) { "    $l" }
    }
}

Export-ModuleMember -Function ConvertTo-PolishNote, Format-UtcMs, Format-Rel, New-EvidenceDir, Get-StateChanges, Get-SampleIntervalStats, Get-Markers,
    Get-RunSummary, Protect-Text, Get-SummaryAll, Write-LabText, Write-LabCsv, Write-LabJson, Format-CommandLog,
    Get-ExpectedMatch, Get-InterventionCount, Write-TestJournal
