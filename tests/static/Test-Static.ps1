# ==============================================================================
# Tytul:        Test-Static.ps1
# Opis:         Testy bez maszyn wirtualnych: konfiguracja, adresy, nazwy plikow,
#               staging binariow, konce linii, naglowki skryptow. Bez Pestera.
# Description [EN]: VM-free tests: config, addresses, file names, binary staging,
#               line endings, script headers. No Pester dependency.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.3 (lab.cmd shutdown: kolejnosc krokow, bash -n, wzorce pgrep / step order, bash -n, pgrep patterns)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7
# Requirements [EN]: - PowerShell 7
#
# Uzycie [PL]:       pwsh tests/static/Test-Static.ps1 [-Only Test-Name]
# Usage [EN]:        pwsh tests/static/Test-Static.ps1 [-Only Test-Name]
# ==============================================================================
[CmdletBinding()]
param([string]$Only)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Passed = 0

function Assert-True([bool]$Cond, [string]$Msg) { if (-not $Cond) { throw "ASSERT: $Msg" } }
function Assert-Equal($Expected, $Actual, [string]$Msg) {
    if ($Expected -ne $Actual) { throw "ASSERT: $Msg (expected '$Expected', got '$Actual')" }
}
function Import-LabModules {
    foreach ($m in 'Common', 'Config', 'Binaries', 'VmPlan') {
        Import-Module (Join-Path $Repo "host\$(if ($m -eq 'Common') { 'modules\' })$m.psm1") -Force -DisableNameChecking
    }
}
# Tymczasowy config: kopia lab.config.psd1 z podmiana tekstu / temp config: copy with text replaced
# -Regex: klucze to wyrazenia regularne, wartosci to zamiany .NET ($1) / keys are regexes, values .NET replacements
function New-TempConfig([hashtable]$Replace, [switch]$Regex) {
    $text = Get-Content -Raw (Join-Path $Repo 'lab.config.psd1')
    foreach ($k in $Replace.Keys) {
        if ($Regex) {
            Assert-True ([regex]::IsMatch($text, $k)) "New-TempConfig: pattern not found: $k"
            $text = [regex]::Replace($text, $k, $Replace[$k])
        } else { $text = $text.Replace($k, $Replace[$k]) }
    }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("gglab-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $p = Join-Path $dir 'lab.config.psd1'
    Set-Content -Path $p -Value $text -Encoding utf8NoBOM
    $p
}

# ------------------------------------------------------------------------------
# Task 1
# ------------------------------------------------------------------------------
function Test-ConfigLoads {
    Import-LabModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    Assert-Equal 'gg.lab.test'   $c.Network.Domain 'domain'
    Assert-Equal '192.168.58.1'  $c.Network.HostIp 'host ip'
    Assert-Equal 'ggrac-scan'    $c.Network.ScanName 'scan name'
    Assert-Equal '192.168.58.40' $c.Network.OggVip 'oggvip'
    Assert-Equal 'ggcdb'         $c.Oracle.SrcDb 'source cdb'
    Assert-Equal 'SRCPDB'        $c.Oracle.SrcPdb 'source pdb'
    Assert-Equal 'TGTPDB'        $c.Oracle.TgtPdb 'target pdb'
    Assert-Equal 'gg_srcpdb'     $c.Oracle.GgService 'gg service'
    Assert-Equal 'A'             $c.Ogg.HaStage 'ha stage'
    Assert-Equal '192.168.58.11' @(Get-Nodes -Config $c -Role rac)[0].PublicIp 'ggrac1 ip'
    Assert-Equal 'ggtgt'         @(Get-Nodes -Config $c -Role tgt)[0].Name 'target node'
}
function Test-NoIpCollision {
    Import-LabModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $ips = @(Get-LabIpList -Config $c)
    # host + 4 wezly + 2 VIP + 3 SCAN + oggvip / host + 4 nodes + 2 VIPs + 3 SCAN + oggvip
    Assert-Equal 11 $ips.Count 'address count'
    Assert-Equal $ips.Count (@($ips | Sort-Object -Unique)).Count 'addresses unique'
    foreach ($ip in $ips) { Assert-True ($ip -like '192.168.58.*') "public address outside 192.168.58.0/24: $ip" }
    $bad = New-TempConfig @{ "VipIp = '192.168.58.22'" = "VipIp = '192.168.58.21'" }
    $threw = $false
    try { Get-GgConfig -Path $bad | Out-Null } catch { $threw = $_.Exception.Message -match 'duplicate' }
    Assert-True $threw 'duplicate VIP must be rejected'
}
function Test-StageNameSpaces {
    Import-LabModules
    Assert-Equal 'V1054596-01-OracleDatabaseGridInfrastructure23.26.1.0.0forLinux_x86-64.zip' `
        (Get-StageName 'V1054596-01-OracleDatabaseGridInfrastructure23.26.1.0.0forLinux x86-64.zip') 'spaces to _'
}
function Test-BinaryMissingReported {
    Import-LabModules
    $p = New-TempConfig @{ "DbZip    = 'V1054592-01" = "DbZip    = 'MISSING-V1054592-01" }
    $c = Get-GgConfig -Path $p
    $db = Get-BinaryStatus -Config $c | Where-Object Name -eq 'DbZip'
    Assert-True (-not $db.Present) 'missing DB zip must be Present=false'
    & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') plan -ConfigPath $p *> $null
    Assert-True ($LASTEXITCODE -ne 0) "plan must exit non-zero when a binary is missing (got $LASTEXITCODE)"
}
# Sztuczne ZIP-y do testow binariow (bez paczek Oracle) / fake ZIPs for binary tests (no Oracle packages)
function New-TestDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("gglab-zip-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d | Out-Null
    $d
}
function New-TestZip([string]$Path, [hashtable]$Entries) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($k in $Entries.Keys) {
            $w = [IO.StreamWriter]::new($z.CreateEntry($k).Open())
            try { $w.Write([string]$Entries[$k]) } finally { $w.Dispose() }
        }
    } finally { $z.Dispose() }
    $Path
}
# Wersja GG z release notes w ZIP-ie; katalog komponentu OUI (23.4.0.0.0) to nie wydanie
# GG version from the release notes in the ZIP; the OUI component dir (23.4.0.0.0) is not the release
function Test-OggVersionFromReleaseNotes {
    Import-LabModules
    $d = New-TestDir
    $comp = 'fbo_ggs_Linux_x64_Oracle_services_shiphome/Disk1/stage/Components/oracle.oggcore.services/23.4.0.0.0/1/x.jar'
    $ok = New-TestZip (Join-Path $d 'p40225913_2326402OGGRU_Linux-x86-64.zip') @{ $comp = ''; 'oracle-goldengate-release-notes-23.26.4.0.2.pdf' = '' }
    Assert-Equal '23.26.4.0.2' (Get-OggInfo $ok).Version 'version from the release notes'
    $bare = New-TestZip (Join-Path $d 'p1_Linux-x86-64.zip') @{ $comp = '' }
    Assert-Equal '?' (Get-OggInfo $bare).Version 'only the OUI component dir: unknown, never 23.4'
    Assert-Equal '23.26.4' (Get-OggInfo (Join-Path $d 'gg_23.26.4_x.zip')).Version 'dotted version in the file name'
}
# Readme RU DB 23.26.4: OPatch >= 12.2.0.1.53 / DB RU 23.26.4 readme: OPatch >= 12.2.0.1.53
function Test-OPatchMinVersion {
    Import-LabModules
    $d = New-TestDir
    $new = New-TestZip (Join-Path $d 'new.zip') @{ 'OPatch/version.txt' = "OPATCH_VERSION:12.2.0.1.55`n" }
    $old = New-TestZip (Join-Path $d 'old.zip') @{ 'OPatch/version.txt' = 'OPATCH_VERSION:12.2.0.1.47' }
    $none = New-TestZip (Join-Path $d 'none.zip') @{ 'readme.txt' = '' }
    $i = Get-OPatchInfo $new
    Assert-Equal '12.2.0.1.55' $i.Version 'OPatch version read from OPatch/version.txt'
    Assert-True $i.Valid '.55 >= .53'
    Assert-True (-not (Get-OPatchInfo $old).Valid) '.47 < .53 must be rejected'
    Assert-True (-not (Get-OPatchInfo $none).Valid) 'ZIP without OPatch/version.txt must be rejected'
    Assert-True (Test-VersionAtLeast '12.2.0.1.100' '12.2.0.1.53') 'numeric compare, not text'
    Assert-True (-not (Test-VersionAtLeast 'abc' '12.2.0.1.53')) 'non-numeric version is not enough'
}
# 85_install_xag.sh robi cd xag && ./xagsetup.sh: xag/ musi byc na gorze ZIP-a
# 85_install_xag.sh does cd xag && ./xagsetup.sh: xag/ must be at the top of the ZIP
function Test-XagZipLayout {
    Import-LabModules
    $d = New-TestDir
    Assert-True (Get-XagInfo (New-TestZip (Join-Path $d 'ok.zip') @{ 'xag/xagsetup.sh' = '' })).Valid 'xag/xagsetup.sh at the top'
    Assert-True (-not (Get-XagInfo (New-TestZip (Join-Path $d 'bad.zip') @{ 'xagpack/xag/xagsetup.sh' = '' })).Valid) 'nested layout must be rejected'
}
# Plan na sztucznym katalogu: puste OggBundle to nie brak; stary OPatch i zly uklad XAG to problemy
# Plan on a fake dir: empty OggBundle is not missing; old OPatch and a bad XAG layout are problems
function Test-PlanBinaryChecks {
    $d = New-TestDir
    New-TestZip (Join-Path $d 'p6880880_old.zip') @{ 'OPatch/version.txt' = 'OPATCH_VERSION:12.2.0.1.47' } | Out-Null
    New-TestZip (Join-Path $d 'xag_bad.zip') @{ 'xagpack/xag/xagsetup.sh' = '' } | Out-Null
    $p = New-TempConfig -Regex @{
        "(?m)^(\s*Dir\s*=\s*)'[^']*'"       = "`$1'$d'"
        "(?m)^(\s*OPatch\s*=\s*)'[^']*'"    = "`$1'p6880880_old.zip'"
        "(?m)^(\s*XagZip\s*=\s*)'[^']*'"    = "`$1'xag_bad.zip'"
        "(?m)^(\s*OggBundle\s*=\s*)'[^']*'" = "`$1''"
    }
    $r = Invoke-PlanText @('-ConfigPath', $p)
    Assert-True ($r.Exit -ne 0) 'plan must be NOT READY'
    Assert-True ($r.Text -notmatch 'missing GG bundle') 'empty OggBundle is optional, not missing'
    Assert-True ($r.Text -match 'OPatch too old: 12\.2\.0\.1\.47 < 12\.2\.0\.1\.53') 'old OPatch reported'
    Assert-True ($r.Text -match 'XAG ZIP layout: no xag/xagsetup\.sh') 'bad XAG layout reported'
}
function Test-PdbNameNoDash {
    Import-LabModules
    $p = New-TempConfig @{ "SrcPdb    = 'SRCPDB'" = "SrcPdb    = 'SRC-PDB'" }
    $msg = ''
    try { Get-GgConfig -Path $p | Out-Null } catch { $msg = $_.Exception.Message }
    Assert-True ($msg -match 'OGG-08221') "PDB name with dash must be rejected with OGG-08221 hint, got: '$msg'"
}
function Test-LineEndingsLf {
    $bad = foreach ($d in 'guest', 'kickstart', 'ogg', 'sql', 'response') {
        $dir = Join-Path $Repo $d
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -Recurse -File | Where-Object {
                $b = [IO.File]::ReadAllBytes($_.FullName)
                for ($i = 0; $i -lt $b.Length - 1; $i++) { if ($b[$i] -eq 13 -and $b[$i + 1] -eq 10) { return $true } }
                $false
            } | ForEach-Object { $_.FullName }
        }
    }
    Assert-True (-not $bad) "CRLF found in: $($bad -join ', ')"
    $attr = Join-Path $Repo '.gitattributes'
    Assert-True ((Test-Path $attr) -and ((Get-Content -Raw $attr) -match '\*\.sh\s+text eol=lf')) '.gitattributes must force LF for *.sh'
}

# ------------------------------------------------------------------------------
# Task 2
# ------------------------------------------------------------------------------
function Get-TestVmPlan {
    Import-LabModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    @(Get-VmPlan -Config $c -SharedDir 'X:\vms\gg-rac26ai-shared')
}
function Test-VmPlanNics {
    $p = Get-TestVmPlan
    foreach ($vm in $p) {
        $want = if ($vm.Role -eq 'rac') { 3 } else { 2 }
        Assert-Equal $want @($vm.Nics).Count "NIC count on $($vm.Name)"
        Assert-Equal 'hostonly' $vm.Nics[0].Type "nic1 on $($vm.Name)"
        Assert-Equal 'nat' $vm.Nics[1].Type "nic2 on $($vm.Name)"
    }
    $rac1 = $p | Where-Object Name -eq 'ggrac1'
    Assert-Equal 'intnet' $rac1.Nics[2].Type 'nic3 type'
    Assert-Equal 'ggrac-ic' $rac1.Nics[2].Target 'nic3 network'
}
function Test-VmPlanSharedOnlyRac {
    $p = Get-TestVmPlan
    foreach ($vm in $p | Where-Object Role -ne 'rac') { Assert-Equal 0 @($vm.SharedDisks).Count "no shared disks on $($vm.Name)" }
    $r1 = ($p | Where-Object Name -eq 'ggrac1').SharedDisks
    $r2 = ($p | Where-Object Name -eq 'ggrac2').SharedDisks
    Assert-Equal 2 @($r1).Count 'shared disks on ggrac1'
    Assert-Equal 'X:\vms\gg-rac26ai-shared\gg-rac26ai-DATA1.vdi' $r1[0].Path 'DATA1 path'
    Assert-Equal $r1[1].Path $r2[1].Path 'FRA1 is the same file on both nodes'
    Assert-Equal 61440 $r1[0].SizeMb 'DATA1 size'
    Assert-Equal 2 $r1[0].Port 'DATA1 SATA port (0 = OS disk, 1 = DVD)'
}
function Test-BootOrderDiskFirst {
    foreach ($vm in Get-TestVmPlan) { Assert-Equal 'disk,dvd' ($vm.Boot -join ',') "boot order on $($vm.Name)" }
}
function Test-DestroyOnlyTagged {
    Import-LabModules
    $vms = @(
        [pscustomobject]@{ Name = 'ggrac1'; Description = 'vbox-lab:gg-rac26ai' }
        [pscustomobject]@{ Name = 'OGG-host01'; Description = 'Oracle GG - host01' }
        [pscustomobject]@{ Name = 'prim01'; Description = '' }
        [pscustomobject]@{ Name = 'ggtgt'; Description = 'vbox-lab:gg-rac26ai-old' }
    )
    $list = @(Get-DestroyList -Vms $vms -LabName 'gg-rac26ai')
    Assert-Equal 'ggrac1' ($list -join ',') 'only VMs tagged exactly with this lab'
}
function Test-DryRunVerbsResolve {
    # Kazdy krok w trybie -DryRun konczy sie bez bledu (np. brak funkcji po imporcie modulow)
    # Every verb in -DryRun ends without error (e.g. a function lost after module import)
    foreach ($v in 'status', 'build', 'stop') {
        & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') $v -DryRun *> $null
        Assert-Equal 0 $LASTEXITCODE "lab.ps1 $v -DryRun exit code"
    }
    & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') destroy all -DryRun *> $null
    Assert-Equal 0 $LASTEXITCODE 'lab.ps1 destroy all -DryRun exit code'
}
function Invoke-PlanText([string[]]$PlanArgs) {
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') plan @PlanArgs 2>&1 | Out-String
    [pscustomobject]@{ Text = $out; Exit = $LASTEXITCODE }
}
function Test-SpaceCheckWarnOnly {
    # SpaceCheck = 'warn': brak miejsca tylko ostrzega, nie trafia na liste NOT READY
    # SpaceCheck = 'warn': low space only warns, never lands on the NOT READY list
    $p = New-TempConfig @{ 'MinFreeGb   = 300' = 'MinFreeGb   = 999999' }
    $r = Invoke-PlanText @('-ConfigPath', $p)
    Assert-True ($r.Text -match 'WARN free space') 'plan must warn about free space'
    Assert-True ($r.Text -notmatch '-\s+free space') 'free space must not be a NOT READY problem'
}
function Test-DriveOverride {
    $r = Invoke-PlanText @('-Drive', 'C')
    Assert-True ($r.Text -match 'free on C:') "plan -Drive C must report drive C:, got: $($r.Text.Substring(0, [Math]::Min(200, $r.Text.Length)))"
    # Litera, ktorej nie ma zaden dysk na tym komputerze / a letter no drive uses on this machine
    $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Name)
    $free = [char[]](90..65) | Where-Object { "$_" -notin $used } | Select-Object -First 1
    $r = Invoke-PlanText @('-Drive', "$free")
    Assert-True ($r.Exit -ne 0 -and $r.Text -match "drive ${free}: not found") "unknown drive $free must fail with a clear message"
}
# Dyski OS dynamiczne (rosna do limitu), wspoldzielone RAC stale (VirtualBox: shareable tylko fixed)
# OS disks dynamic (grow up to the limit), RAC shared disks fixed (VirtualBox: shareable needs fixed)
function Test-PlanDiskStartAndMax {
    $vb = [IO.File]::ReadAllText((Join-Path $Repo 'host\modules\VmBuilder.psm1'))
    $line = ($vb -split "`n" | Where-Object { $_ -match 'createmedium disk' }) -join ' '
    Assert-True ($line -and $line -notmatch 'Fixed') "OS disk must be dynamic (no --variant Fixed): $line"
    $r = Invoke-PlanText @()
    Assert-True ($r.Text -match 'fixed now 90 GB') 'plan shows the fixed shared disks allocated at once'
    Assert-True ($r.Text -match 'OS dynamic up to 300 GB') 'plan shows the dynamic OS disks limit'
    Assert-True ($r.Text -match 'max 390 GB') 'plan shows the maximum'
}
function Test-PlanTotals {
    Import-LabModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $t = Get-PlanTotals -Config $c
    # 15.11 build: 10 GB RAC nodes swapped (4.2 GB HugePages for SGA 4 GB + GI + installer): 14 GB each
    Assert-Equal 36864 $t.RamMb 'RAM total (2+14+14+6 GB)'
    Assert-Equal 390 $t.DiskGb 'disk total: OS 20+100+100+80 + shared 60+30'
}
# Build attempt 7 (15.11): the first chrony sync stepped the guest clock by +80..180 s (VirtualBox lost time during the
# install), so a date-based deadline in wait_until expired at once: 8 s of real time ended a 60 s wait. The deadline
# must use a clock that chrony does not step (/proc/uptime).
function Test-WaitUntilMonotonic {
    $lib = [IO.File]::ReadAllText((Join-Path $Repo 'guest\lib.sh'))
    $fn = [regex]::Match($lib, '(?s)\nwait_until\(\) \{(.*?)\n\}').Groups[1].Value
    Assert-True ($fn -ne '') 'wait_until found'
    Assert-True ($fn -notmatch 'date \+%s') 'wait_until does not use the wall clock (date +%s) for its deadline'
    Assert-True ($fn -match 'uptime_s' -and $lib -match '(?m)^uptime_s\(\) \{.*/proc/uptime') 'wait_until counts /proc/uptime (not stepped by chrony)'
    $calls = @'
DRY_RUN=0; NODE_NAME=t; n=0
f() { n=$((n+1)); [ $n -ge 2 ]; }
sleep() { :; }
( wait_until 60 "second try" f ); echo "rc=$?"
( wait_until 0 "never" false ) 2>/dev/null; echo "rc=$?"
'@
    $out = @(Invoke-BashFunction 'guest\lib.sh' @('log', 'ok', 'warn', 'die', 'uptime_s', 'wait_until') $calls)
    Assert-Equal 'rc=0' ($out -match '^rc=')[0] 'condition met on the second try'
    Assert-Equal 'rc=1' ($out -match '^rc=')[1] 'condition never met: timeout, rc 1'
}
# Build attempt 6 (15.11): OL 9.8 (chrony 4.8) ships no /etc/chrony.d, prereq on ggrac1 died on
# "install: cannot create regular file '/etc/chrony.d/lab-client.conf'": write_if_changed creates the parent directory
function Test-WriteIfChangedCreatesDir {
    $calls = @'
DRY_RUN=0; d=$(mktemp -d)
echo hello | write_if_changed "$d/new/sub/file.conf"; echo "rc=$?"
cat "$d/new/sub/file.conf"
echo hello | write_if_changed "$d/new/sub/file.conf"; echo "rc=$?"
'@
    $out = @(Invoke-BashFunction 'guest\lib.sh' @('write_if_changed') $calls)
    Assert-Equal 'rc=0' ($out -match '^rc=')[0] 'missing parent directory: file written, rc 0 (changed)'
    Assert-True ($out -contains 'hello') 'content written'
    Assert-Equal 'rc=1' ($out -match '^rc=')[1] 'same content again: rc 1 (unchanged)'
}
# Build attempts 2 and 5 (15.11): gginfra with 1 GB hung in the OL 9 installer on "Checking storage configuration"
# while the 6-10 GB VMs installed in 10 min. The RHEL/OL 9 installer needs at least 1.5 GB: every node gets 2 GB or more.
function Test-NodeRamInstallerMinimum {
    Import-LabModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    foreach ($n in $c.Nodes) { Assert-True ($n.Ram -ge 2048) "$($n.Name): Ram $($n.Ram) MB is below the 2048 MB the OL 9 installer needs" }
}

# ------------------------------------------------------------------------------
# Task 3
# ------------------------------------------------------------------------------
# Render kickstartu do katalogu tymczasowego / render a kickstart into a temp dir
function Get-TestKs([string]$Node, [switch]$Masked, [string]$ConfigPath) {
    Import-LabModules
    Import-Module (Join-Path $Repo 'host\Kickstart.psm1') -Force -DisableNameChecking
    if (-not $ConfigPath) { $ConfigPath = Join-Path $Repo 'lab.config.psd1' }
    $c = Get-GgConfig -Path $ConfigPath
    $out = Join-Path ([IO.Path]::GetTempPath()) ("gglab-ks-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $p = Invoke-RenderKickstart -Config $c -Node $Node -RepoRoot $Repo -OutDir $out -Masked:$Masked
    [IO.File]::ReadAllText($p)
}
function Get-KsHostsBlock([string]$Ks) {
    ([regex]::Match($Ks, "(?s)cat >> /etc/hosts <<'EOF'\n(.*?)\nEOF")).Groups[1].Value
}
function Test-KsHasHostsForAllNodes {
    $names = 'gginfra', 'ggrac1', 'ggrac2', 'ggtgt', 'ggrac1-vip', 'ggrac2-vip', 'ggrac1-priv', 'ggrac2-priv', 'oggvip'
    foreach ($n in 'gginfra', 'ggrac1', 'ggrac2', 'ggtgt') {
        $h = Get-KsHostsBlock (Get-TestKs $n -Masked)
        foreach ($name in $names) { Assert-True ($h -match "(?m)\s$([regex]::Escape($name))\.gg\.lab\.test\s+$([regex]::Escape($name))$") "$n /etc/hosts lacks $name" }
        # SCAN tylko przez DNS (3 adresy, round-robin) / SCAN only via DNS (3 addresses, round-robin)
        Assert-True ($h -notmatch 'scan') "$n /etc/hosts must not contain the SCAN name"
        Assert-True ($h -notmatch '192\.168\.58\.3[123]\b') "$n /etc/hosts must not contain SCAN addresses"
    }
    Assert-True ((Get-KsHostsBlock (Get-TestKs 'ggrac1' -Masked)) -match '(?m)^10\.58\.0\.12\s+ggrac2-priv') 'ggrac2-priv on the interconnect address'
}
function Test-KsMaskedHasNoPass {
    $old = $env:LAB_PASS
    try {
        $env:LAB_PASS = 'Static_Test_Pass_42'
        foreach ($n in 'gginfra', 'ggrac1', 'ggtgt') {
            Assert-True ((Get-TestKs $n -Masked) -notmatch 'Static_Test_Pass_42') "masked $n kickstart contains the password"
        }
        Assert-True ((Get-TestKs 'ggrac1') -match "LAB_PASS='Static_Test_Pass_42'") 'real render must carry LAB_PASS'
        $env:LAB_PASS = 'bad pass;rm'
        $threw = $false
        try { Get-TestKs 'ggrac1' | Out-Null } catch { $threw = $_.Exception.Message -match 'LAB_PASS' }
        Assert-True $threw 'LAB_PASS with spaces or ; must be rejected'
    } finally { $env:LAB_PASS = $old }
}
function Test-KsKernelLock {
    $ks = Get-TestKs 'ggrac1' -Masked
    $post = ([regex]::Match($ks, '(?s)%post.*%end')).Value
    # Lock exactly the installed kernel* packages (a bare 'kernel*' glob would also lock uninstalled ones)
    Assert-True ($post -match "rpm -qa [^\n]*'kernel\*'") 'RAC %post must list installed kernel* packages'
    Assert-True ($post -match "dnf -y -q --disablerepo='\*' versionlock add `"\`$\{kpkgs\[@\]\}`"") 'RAC %post must versionlock them'
    Assert-True ($ks -match '(?m)^python3-dnf-plugin-versionlock$') 'versionlock plugin in %packages'
    Assert-True ($ks -match '(?m)^repo --name=ol9_UEKR8 ') 'uek: UEK repo'
    Assert-True ($ks -match '(?m)^kernel-uek$') 'uek: kernel-uek package'
    $p = New-TempConfig @{ "Kernel  = 'uek'" = "Kernel  = 'rhck'" }
    $rh = Get-TestKs 'ggrac1' -Masked -ConfigPath $p
    Assert-True ($rh -notmatch 'UEKR') 'rhck: no UEK repo'
    Assert-True ($rh -match '(?m)^-kernel-uek') 'rhck: kernel-uek excluded'
    Assert-True ((Get-TestKs 'gginfra' -Masked) -notmatch 'versionlock add') 'gginfra: no kernel lock needed'
}
function Test-KsResolverPointsInfra {
    foreach ($n in 'ggrac1', 'ggrac2', 'ggtgt') {
        $ks = Get-TestKs $n -Masked
        Assert-True ($ks -match '(?m)^nameserver 192\.168\.58\.10$') "$n resolv.conf must point to gginfra"
        Assert-True ($ks -match '(?m)^dns=none$') "$n NetworkManager must not overwrite resolv.conf"
        Assert-True ($ks -match '(?m)^search gg\.lab\.test$') "$n search domain"
    }
    Assert-True ((Get-TestKs 'gginfra' -Masked) -notmatch 'dns=none') 'gginfra keeps the NAT resolver (dnsmasq upstream)'
}
function Test-KsPenaltyExempt {
    foreach ($n in 'gginfra', 'ggrac1', 'ggrac2', 'ggtgt') {
        Assert-True ((Get-TestKs $n -Masked) -match 'PerSourcePenaltyExemptList 192\.168\.58\.1/32') "$n PerSourcePenaltyExemptList"
    }
}
function Test-KsRoleContent {
    $rac = Get-TestKs 'ggrac2' -Masked
    foreach ($pkg in 'oracle-ai-database-preinstall-26ai', 'nfs-utils', 'bind-utils') { Assert-True ($rac -match "(?m)^$pkg$") "rac package $pkg" }
    Assert-True ($rac -match '(?m)^network .*--device=enp0s9 --ip=10\.58\.0\.12 ') 'rac interconnect on enp0s9'
    Assert-True ($rac -match 'useradd .* grid') 'rac: grid user'
    Assert-True ($rac -match 'ORACLE_SID=\+ASM2') 'ggrac2: +ASM2'
    Assert-True ($rac -match 'ORACLE_SID=ggcdb2') 'ggrac2: ggcdb2'
    Assert-True ($rac -match 'PATH=/u01/app/xag/bin:') 'XAG before GI in PATH'
    Assert-True ($rac -match '(?m)^part /u01 ') 'rac: /u01 partition'
    $tgt = Get-TestKs 'ggtgt' -Masked
    Assert-True ($tgt -match '(?m)^oracle-ai-database-preinstall-26ai$') 'tgt preinstall'
    Assert-True ($tgt -notmatch '--device=enp0s9|--add-interface=enp0s9') 'tgt: no interconnect'
    Assert-True ($tgt -notmatch 'useradd .* grid') 'tgt: no grid user'
    Assert-True ($tgt -match 'ORACLE_SID=tgtcdb') 'tgt SID'
    $inf = Get-TestKs 'gginfra' -Masked
    foreach ($pkg in 'dnsmasq', 'chrony', 'bind-utils') { Assert-True ($inf -match "(?m)^$pkg$") "infra package $pkg" }
    Assert-True ($inf -notmatch 'preinstall') 'infra: no Oracle preinstall'
    foreach ($ks in $rac, $tgt, $inf) {
        Assert-True ($ks -notmatch '\{\{[A-Z_]+\}\}') 'unresolved token'
        Assert-True ($ks -notmatch "`r") 'CR in rendered kickstart'
        Assert-True ($ks -notmatch '#@@') 'role section markers must not leak'
    }
}

# ------------------------------------------------------------------------------
# Task 4
# ------------------------------------------------------------------------------
function Get-BashExe {
    # Git Bash, never WSL's System32\bash.exe (it may have no distribution installed)
    foreach ($p in "$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") { if (Test-Path $p) { return $p } }
    throw 'Git Bash not found (needed for bash -n)'
}
# Every script and template has the PL/EN header and its own file name in Tytul
function Test-ScriptHeaders {
    $files = @(
        Get-ChildItem (Join-Path $Repo 'guest') -Recurse -File -Include '*.sh' -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $Repo 'sql') -File -Filter '*.sql' -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $Repo 'kickstart') -File -Filter '*.tmpl' -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $Repo 'ogg') -File -Filter '*.tmpl' -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $Repo 'response') -File -Filter '*.tmpl' -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $Repo 'host') -File -Filter '*.psm1'
        Get-ChildItem (Join-Path $Repo 'tests') -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue
        Get-Item (Join-Path $Repo 'lab.ps1')
    ) | Where-Object { $_.FullName -notmatch '\\out\\' }
    $bad = foreach ($f in $files) {
        $head = (Get-Content -TotalCount 30 $f.FullName) -join "`n"
        $miss = @('Description \[EN\]:', 'Wymagania \[PL\]:', 'Requirements \[EN\]:', 'Uzycie \[PL\]:', 'Usage \[EN\]:', 'Konwencje:\s+<repo>/SETTINGS\.md' |
            Where-Object { $head -notmatch $_ })
        if ($head -notmatch "Tytul:\s+$([regex]::Escape($f.Name))\b") { $miss += 'Tytul' }
        if ($miss) { "$($f.Name) [$($miss -join ', ')]" }
    }
    Assert-True (-not $bad) "header problems: $($bad -join '; ')"
}
function Test-BashSyntax {
    $bash = Get-BashExe
    $sh = @(Get-ChildItem (Join-Path $Repo 'guest') -Recurse -File -Filter '*.sh')
    Assert-True ($sh.Count -ge 4) 'guest scripts present (lib.sh + infra)'
    $bad = foreach ($f in $sh) {
        $err = & $bash -n $f.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { "$($f.Name): $err" }
    }
    Assert-True (-not $bad) "bash -n: $($bad -join '; ')"
}
function Get-TestGuestFiles([string]$Node) {
    Import-LabModules
    Import-Module (Join-Path $Repo 'host\Guest.psm1') -Force -DisableNameChecking
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $out = Join-Path ([IO.Path]::GetTempPath()) ("gglab-guest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir = Write-GuestFiles -Config $c -Node $Node -OutDir $out
    @{ Env = [IO.File]::ReadAllText((Join-Path $dir 'lab.env')); Hosts = [IO.File]::ReadAllText((Join-Path $dir 'hosts.env')) }
}
function Test-GuestEnvRendered {
    $old = $env:LAB_PASS
    try {
        $env:LAB_PASS = 'Static_Test_Pass_42'
        $g = Get-TestGuestFiles 'gginfra'
        Assert-True ($g.Env -notmatch 'Static_Test_Pass_42') 'lab.env must not carry the password'
        foreach ($kv in "NODE_NAME='gginfra'", "NODE_ROLE='infra'", "LAB_DOMAIN='gg.lab.test'", "SCAN_NAME='ggrac-scan'",
                        "SCAN_IPS='192.168.58.31 192.168.58.32 192.168.58.33'", "OGG_VIP='192.168.58.40'", "INFRA_IP='192.168.58.10'",
                        "PUBLIC_SUBNET='192.168.58.0/24'", "RAC_NODES='ggrac1 ggrac2'") {
            Assert-True ($g.Env.Contains($kv)) "lab.env lacks $kv"
        }
        # dnsmasq answers SCAN round-robin from three host lines with the same name
        $scan = @($g.Hosts -split "`n" | Where-Object { $_ -match '\sggrac-scan\.gg\.lab\.test\s' })
        Assert-Equal 3 $scan.Count 'SCAN lines in hosts.env'
        Assert-True ($g.Hosts -match '(?m)^192\.168\.58\.11\s+ggrac1\.gg\.lab\.test\s+ggrac1$') 'ggrac1 record (first name = PTR)'
        Assert-True ($g.Hosts -match '(?m)^192\.168\.58\.40\s+oggvip\.gg\.lab\.test') 'oggvip record'
        Assert-True ($g.Env -notmatch "`r" -and $g.Hosts -notmatch "`r") 'LF only'
        $r = Get-TestGuestFiles 'ggrac2'
        Assert-True ($r.Env.Contains("NODE_NUM='2'")) 'ggrac2 NODE_NUM'
        Assert-True ($r.Env.Contains("GRID_HOME='/u01/app/23.26/grid'")) 'GRID_HOME'
    } finally { $env:LAB_PASS = $old }
}
function Test-InfraStepDryRun {
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') infra -DryRun 2>&1 | Out-String
    Assert-Equal 0 $LASTEXITCODE "lab.ps1 infra -DryRun exit code: $out"
    foreach ($s in 'infra/10_dnsmasq.sh', 'infra/20_chrony.sh', 'infra/90_validate.sh') {
        Assert-True ($out -match "DRYRUN \[gginfra\] bash /root/lab/$([regex]::Escape($s))") "infra -DryRun must show $s"
    }
}
function Test-InfraScriptsUseLabEnv {
    $dns = Get-Content -Raw (Join-Path $Repo 'guest\infra\10_dnsmasq.sh')
    Assert-True ($dns -match 'addn-hosts=') 'dnsmasq reads the lab hosts file'
    Assert-True ($dns -match 'no-hosts') 'dnsmasq ignores /etc/hosts (single source: hosts.env)'
    Assert-True ($dns -notmatch '192\.168\.58\.') 'no hard-coded lab addresses in 10_dnsmasq.sh'
    $val = Get-Content -Raw (Join-Path $Repo 'guest\infra\90_validate.sh')
    foreach ($w in 'SCAN_IPS', 'dig -x', 'OGG_VIP', 'Leap status', 'finish_checks') { Assert-True ($val.Contains($w)) "90_validate.sh lacks $w" }
}

# ------------------------------------------------------------------------------
# Task 5
# ------------------------------------------------------------------------------
function Get-TestGuestFile([string]$Node, [string]$File) {
    Import-LabModules
    Import-Module (Join-Path $Repo 'host\Guest.psm1') -Force -DisableNameChecking
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $out = Join-Path ([IO.Path]::GetTempPath()) ("gglab-guest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir = Write-GuestFiles -Config $c -Node $Node -OutDir $out -RepoRoot $Repo
    $p = Join-Path $dir $File
    Assert-True (Test-Path $p) "$File not rendered for $Node"
    [IO.File]::ReadAllText($p)
}
function Test-GridRspRendered {
    $old = $env:LAB_PASS
    try {
        $env:LAB_PASS = 'Static_Test_Pass_42'
        $r = Get-TestGuestFile 'ggrac1' 'gridsetup.rsp'
        # 26ai (23.26) key names; the oracle.install.* names of earlier releases are not in the 23.26 sample
        foreach ($kv in 'oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v23.0.0',
                        'installOption=CRS_CONFIG', 'clusterUsage=RAC', 'ORACLE_BASE=/u01/app/grid',
                        'INVENTORY_LOCATION=/u01/app/oraInventory', 'OSASM=asmadmin', 'scanType=LOCAL_SCAN',
                        'scanName=ggrac-scan', 'clusterName=ggrac',
                        'clusterNodes=ggrac1:ggrac1-vip,ggrac2:ggrac2-vip',
                        'networkInterfaceList=enp0s3:192.168.58.0:1,enp0s9:10.58.0.0:5',
                        'storageOption=FLEX_ASM_STORAGE', 'diskGroupName=DATA', 'redundancy=EXTERNAL',
                        'diskList=/dev/oracleasm/DATA1', 'diskString=/dev/oracleasm/*', 'executeRootScript=false') {
            Assert-True ($r -match "(?m)^$([regex]::Escape($kv))$") "gridsetup.rsp lacks $kv"
        }
        $legacy = @([regex]::Matches($r, '(?m)^oracle\.install\.(?!responseFileVersion)[^=]+=') | ForEach-Object Value)
        Assert-True ($legacy.Count -eq 0) "gridsetup.rsp has pre-26ai keys: $($legacy -join ' ')"
        Assert-True ($r -notmatch 'Static_Test_Pass_42') 'gridsetup.rsp must not carry the password'
        Assert-True ($r -match '(?m)^sysasmPassword=@@LAB_PASS@@$') 'SYSASM password placeholder (filled on the VM)'
        Assert-True ($r -match '(?m)^asmsnmpPassword=@@LAB_PASS@@$') 'ASMSNMP password placeholder (filled on the VM)'
        Assert-True ($r -notmatch '\{\{[A-Z_]+\}\}') 'unresolved token in gridsetup.rsp'
        Assert-True ($r -notmatch "`r") 'LF only'
    } finally { $env:LAB_PASS = $old }
}
function Test-GuestBinaryEnv {
    $e = Get-TestGuestFile 'ggrac1' 'lab.env'
    Assert-True ($e.Contains("GRID_ZIP='V1054596-01-OracleDatabaseGridInfrastructure23.26.1.0.0forLinux_x86-64.zip'")) 'GRID_ZIP stage name (no spaces)'
    Assert-True ($e.Contains("DB_ZIP='V1054592-01-OracleDatabase23.26.1.0.0forLinux_x86-64.zip'")) 'DB_ZIP stage name'
    Assert-True ($e.Contains("ASM_DISKS='DATA1:61440 FRA1:30720'")) 'ASM_DISKS name:MiB list'
    Assert-True ($e -match "(?m)^GRID_RU_ID='[0-9]*'$") 'GRID_RU_ID present (may be empty)'
}
function Test-RacStepsDryRun {
    $order = @{
        prereq = @('[ggrac1] bash /root/lab/rac/10_os_prereq.sh', '[ggrac2] bash /root/lab/rac/10_os_prereq.sh')
        shared = @('[ggrac1] bash /root/lab/rac/20_asm_udev.sh', '[ggrac2] bash /root/lab/rac/20_asm_udev.sh',
                   '[ggrac1] bash /root/lab/rac/30_ssh_equivalence.sh keygen grid', '[ggrac2] bash /root/lab/rac/30_ssh_equivalence.sh verify oracle')
        grid   = @('[ggrac1] bash /root/lab/rac/40_install_grid.sh stage', '[ggrac2] bash /root/lab/rac/40_install_grid.sh cvuqdisk',
                   '[ggrac1] bash /root/lab/rac/40_install_grid.sh install', '[ggrac1] bash /root/lab/rac/40_install_grid.sh root',
                   '[ggrac2] bash /root/lab/rac/40_install_grid.sh root', '[ggrac1] bash /root/lab/rac/40_install_grid.sh ahf',
                   '[ggrac2] bash /root/lab/rac/40_install_grid.sh ahf', '[ggrac1] bash /root/lab/rac/40_install_grid.sh config',
                   '[ggrac1] bash /root/lab/rac/90_validate.sh grid')
    }
    foreach ($verb in 'prereq', 'shared', 'grid') {
        $out = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') $verb -DryRun 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE "lab.ps1 $verb -DryRun exit: $out"
        $pos = -1
        foreach ($line in $order[$verb]) {
            $i = $out.IndexOf("DRYRUN $line")
            Assert-True ($i -gt $pos) "$verb -DryRun: '$line' missing or out of order"
            $pos = $i
        }
    }
}
function Test-GridResumeNeverWipes {
    $g = Get-Content -Raw (Join-Path $Repo 'guest\rac\40_install_grid.sh')
    Assert-True ($g -match 'rootcrs\.sh -deconfig') 'partial root.sh state must name the deconfig command'
    Assert-True ($g -match 'gi_partial') 'partial gridSetup state is detected'
    # The script only prints recovery commands; it never removes a home or deconfigures on its own.
    # Printed help (heredocs to stderr, die messages) is allowed to name them: strip it first.
    $g = [regex]::Replace($g, '(?ms)<<EOF\r?\n.*?^EOF\r?$', '')
    $g = [regex]::Replace($g, '(?m)^\s*.*\bdie "[^"]*"', '')
    foreach ($bad in 'rm -rf "\$GRID_HOME', 'rm -rf \$GRID_HOME', '^\s*(run\s+)?"?\$GRID_HOME"?/crs/install/rootcrs\.sh', 'deinstall -silent') {
        Assert-True ($g -notmatch "(?m)$bad") "40_install_grid.sh must not run: $bad"
    }
}
function Test-RacValidateGrid {
    $v = Get-Content -Raw (Join-Path $Repo 'guest\rac\90_validate.sh')
    foreach ($w in 'crsctl check cluster -all', 'olsnodes -n', 'srvctl status scan_listener', 'asmcmd lsdg', 'chronyc -n sources', 'INFRA_IP', 'finish_checks') {
        Assert-True ($v.Contains($w)) "rac 90_validate.sh lacks $w"
    }
}
# Build attempt 10 (15.11): dbca failed ORA-15001 "disk group DATA does not exist or is not mounted" while ASM had DATA
# mounted: the DB oracle binary runs setgid asmdba, the udev rule gave the disks grid:asmadmin 0660. gridSetup had
# warned PRVF-9992 "Expected = asmdba; Found = asmadmin". Disks: grid:asmdba 0660 (rule, check, manual).
function Test-AsmDiskGroupAsmdba {
    $u = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\20_asm_udev.sh'))
    Assert-True ($u -match 'OWNER=\\"grid\\", GROUP=\\"asmdba\\", MODE=\\"0660\\"') 'udev rule: grid:asmdba 0660'
    Assert-True ($u -match '"grid:asmdba 660"') 'udev check expects grid:asmdba 660'
    Assert-True ($u -notmatch 'GROUP=\\"asmadmin\\"') 'no asmadmin group on the ASM disks'
    foreach ($f in 'docs\MANUAL.md', 'docs\MANUAL_PL.md') {
        Assert-True ([IO.File]::ReadAllText((Join-Path $Repo $f)) -notmatch 'GROUP="asmadmin"') "${f}: disks grid:asmdba"
    }
}
# Build attempt 10 (16.11): 04_tgt_users_pdb.sql failed ORA-03405 "End of query reached; no additional text should follow"
# on "GRANT ...;   -- comment": a comment after the semicolon of a SQL statement reaches the 26ai server. Comments go
# on their own line (PL/SQL blocks are not affected).
function Test-SqlNoCommentAfterSemicolon {
    $hits = foreach ($f in Get-ChildItem (Join-Path $Repo 'sql') -Filter '*.sql') {
        $i = 0
        foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
            $i++
            if ($l -match '^\s*(GRANT|REVOKE|CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|EXEC|SELECT)\b.*;\s*--') { "$($f.Name):$i" }
        }
    }
    Assert-True (-not $hits) "SQL statement with a comment after the semicolon: $($hits -join ', ')"
}
# Build attempt 10 (16.11): oggconf did everything (credential store, trandata, heartbeat, Extract started) but adminclient
# exited 2: the first "ALTER CREDENTIALSTORE DELETE" hit a missing alias (OGG-15409). Also the path alias ggtgt_dp logs
# in to the target as oggadmin and must carry the GoldenGate admin password, not LAB_PASS.
function Test-AdminclientRun {
    $lib = [IO.File]::ReadAllText((Join-Path $Repo 'guest\lib.sh'))
    $fn = [regex]::Match($lib, '(?s)\nadminclient_run\(\) \{(.*?)\n\}').Groups[1].Value
    Assert-True ($fn -ne '') 'adminclient_run found'
    $iDel = $fn.IndexOf('DELETE USER'); $iMain = $fn.IndexOf("grep -v '^[[:space:]]*--'")
    Assert-True ($iDel -ge 0 -and $iDel -lt $iMain) 'DELETE of the aliases runs before the main session'
    Assert-True ($fn -match '(?s)DELETE USER.*?\|\| true') 'the DELETE session result is ignored (missing alias on the first run)'
    Assert-True ($fn -match '\[ "\$u" = "\$OGG_ADMIN_USER" \]') 'an alias for the GoldenGate admin user gets ogg_admin_pass'
    Assert-True ($fn -match 'warn "adminclient') 'a failed command in the main session is a warning, the caller validates'
}
# Build attempt 10 (16.11): "crsctl status resource oggvip" and "agctl config goldengate oggsource" both return rc 0 for a
# missing resource (CRS-2613 / XAG-212), so phase vip skipped appvipcfg. Existence = NAME= line / no XAG-212.
function Test-XagExistenceChecks {
    $calls = @'
GRID_HOME=/x
crsctl_out=''
crs_status() { echo "$crsctl_out"; }
crsctl_out="CRS-2613: Could not find resource 'oggvip'."; crs_res_exists oggvip; echo "missing=$?"
crsctl_out=$'NAME=oggvip\nTYPE=app.appviptypex2.type\nSTATE=OFFLINE'; crs_res_exists oggvip; echo "present=$?"
'@
    $out = @(Invoke-BashFunction 'guest\lib.sh' @('crs_res_exists') ("crs_res_exists_cmd() { crs_status; }`n" + $calls))
    Assert-Equal 'missing=1' ($out -match '^missing=')[0] 'CRS-2613 text means the resource is missing'
    Assert-Equal 'present=0' ($out -match '^present=')[0] 'NAME= line means the resource exists'
    $x = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\87_xag_register.sh'))
    Assert-True ($x -match 'if crs_res_exists "\$OGG_VIP_NAME"; then') 'phase vip uses crs_res_exists'
    Assert-True ($x -match "grep -q 'XAG-212'") 'phase add treats XAG-212 as not registered'
}
# Build attempt 10 (16.11): registerServiceManager.sh (line 92) runs "oggca.sh -silent -checkpoint -responseFile
# /u01/stage/oggca_target.rsp" again; the script had removed the file right after oggca: INS-10101. The response file
# stays until the end (trap on EXIT) and is rendered again when oggca was skipped but the registration is due.
function Test-OggcaRspKeptForRegister {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\tgt\86_oggca_target.sh'))
    Assert-True ($t -match "trap 'rm -f `"\`$RSP`"' EXIT") 'the response file is removed on exit, not right after oggca'
    $iTrap = $t.IndexOf("trap 'rm -f"); $iOggca = $t.IndexOf('oggca.sh -silent -responseFile')
    Assert-True ($iTrap -ge 0 -and $iTrap -lt $iOggca) 'trap set before oggca runs'
    $reg = [regex]::Match($t, '(?s)else\s+reg=.*?run "\$reg"').Value
    Assert-True ($reg -match '\[ -f "\$RSP" \] \|\| render_secret') 'the register branch renders the response file when it is missing'
    Assert-True ($t -notmatch '(?m)^\s*run rm -f "\$RSP"') 'no early rm of the response file'
}
# Build attempt 10 (16.11): oggca.sh INS-85080 — GoldenGate 23.26 strong password policy: 8-30 chars with a lowercase,
# an uppercase, a digit and one of - ! @ % & * . # _. LAB_PASS (letters, digits, _) may lack the special one.
# The GoldenGate admin password = LAB_PASS plus the missing classes (_ A a 1), in oggca, adminclient and agctl.
function Test-OggAdminPassPolicy {
    $calls = @'
DRY_RUN=0; NODE_NAME=t
LAB_PASS=Abcdefgh1; echo "a=$(ogg_admin_pass)"
LAB_PASS=abc_defgh; echo "b=$(ogg_admin_pass)"
LAB_PASS=Abc_def12; echo "c=$(ogg_admin_pass)"
LAB_PASS=ABCDEFGH1234567890ABCDEFGH123; ( ogg_admin_pass ) >/dev/null 2>&1; echo "long=$?"
'@
    $out = @(Invoke-BashFunction 'guest\lib.sh' @('log', 'ok', 'warn', 'die', 'need_lab_pass', 'ogg_admin_pass') $calls)
    Assert-True ($out -contains 'a=Abcdefgh1_') 'special character added'
    Assert-True ($out -contains 'b=abc_defghA1') 'uppercase and digit added'
    Assert-True ($out -contains 'c=Abc_def12') 'a compliant LAB_PASS is used as is'
    Assert-True ($out -contains 'long=1') 'over 30 characters after the additions: stop'
    foreach ($f in 'ogg\oggca_source.rsp.tmpl', 'ogg\oggca_target.rsp.tmpl') {
        $r = [IO.File]::ReadAllText((Join-Path $Repo $f))
        Assert-True ($r -match '(?m)^ADMINISTRATOR_PASSWORD=@@OGG_ADMIN_PASS@@$') "$f uses the GoldenGate admin password token"
    }
    $lib = [IO.File]::ReadAllText((Join-Path $Repo 'guest\lib.sh'))
    Assert-True ($lib -match 'OGG_ADMIN_PASS@@/\$\(ogg_admin_pass\)') 'render_secret fills the GoldenGate token'
    Assert-True ($lib -match "PASSWORD %s\\n' `"\`$url`" `"\`$dep`" `"\`$OGG_ADMIN_USER`" `"\`$\(ogg_admin_pass\)`"") 'adminclient CONNECT uses the GoldenGate password'
    Assert-True ([IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\87_xag_register.sh')) -match "printf '%s\\n' `"\`$\(ogg_admin_pass\)`" \| `"\`$AGCTL`"") 'agctl gets the GoldenGate password'
}
# Build attempt 10 (16.11): tgt/60_create_db.sh ended rc=0 at 06:50, run_step.sh waited on the lock for 20+ min:
# lsof showed tnslsnr holding the lock file (started by the step, inherited the flock fd). flock -o closes the fd
# before the command runs, so daemons the step starts do not keep the step "running".
function Test-RunStepLockNotInherited {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\run_step.sh'))
    Assert-True ($t -match 'setsid flock -o "\$lock" bash -c') 'the step runs under flock -o (lock fd not inherited)'
}
# 15.11: stop a running build after the current step (RAM change before dbca): logs\STOP blocks every build step;
# plan, status, ssh, start, stop and destroy still work
function Test-StopFileBlocksSteps {
    $lab = [IO.File]::ReadAllText((Join-Path $Repo 'lab.ps1'))
    Assert-True ($lab -match "Test-Path \(Join-Path \`$RepoRoot 'logs\\STOP'\)") 'lab.ps1 checks logs\STOP'
    Assert-True ($lab -match "'plan', 'status', 'ssh', 'start', 'stop', 'shutdown', 'destroy'") 'read-only and VM control verbs are not blocked'
    $iStop = $lab.IndexOf("logs\STOP"); $iSwitch = $lab.IndexOf('switch ($Verb)')
    Assert-True ($iStop -gt 0 -and $iStop -lt $iSwitch) 'the check runs before the step dispatch'
}
# Kris 15.11: "lab.cmd ssh ggrac1" as in the other vbox-lab labs (bank1, kurs): interactive root shell on one VM,
# not logged in steps.csv; a missing or unknown VM name is an error with the list of names
function Test-SshVerb {
    $lab = [IO.File]::ReadAllText((Join-Path $Repo 'lab.ps1'))
    Assert-True ($lab -match "(?s)ValidateSet\([^)]*'ssh'") "'ssh' in the verb list"
    Assert-True ($lab -match "(?m)^\s*'ssh'\s+\{ Step-Ssh \}") "'ssh' dispatches to Step-Ssh"
    $fn = [regex]::Match($lab, '(?s)function Step-Ssh \{(.*?)\n\}').Groups[1].Value
    Assert-True ($fn -match 'BatchMode=no' -and $fn -match 'root@') 'Step-Ssh opens an interactive root session'
    Assert-True ($fn -match 'throw') 'Step-Ssh refuses a missing or unknown VM name'
    Assert-True ($lab -match "-in 'plan', 'status', 'ssh'") 'ssh is not logged in steps.csv'
}
# Build attempt 10 (15.11): on GI 23.26 "crsctl check ctss" is an invalid argument and there is no ora.ctssd
# resource (crsctl stat res -init). Time comes from chrony only. The check accepts: no ora.ctssd, or CTSS Observer.
function Test-ValidateCtssOptional {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\90_validate.sh'))
    $line = @($t -split "`n" | Where-Object { $_ -match 'check "CTSS' })
    Assert-True ($line.Count -eq 1) 'one CTSS check'
    Assert-True ($line[0] -match '\^NAME=ora\.ctssd') 'the CTSS check greps NAME=ora.ctssd (crsctl stat res returns 0 also for a missing resource)'
    Assert-True ($line[0] -match 'Observer') 'with ora.ctssd present it must be in Observer mode'
}
# Build attempt 10 (15.11): gridSetup finished ("Successfully Setup Software"), the inventory lists the home WITHOUT
# CRS="true" (root.sh adds it), and phase root refused: "GI not installed yet". Phase root needs a registered home;
# phase install leaves a done marker, so a re-run skips it instead of calling the finished install partial.
function Test-GridPhasesAfterSoftwareInstall {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\40_install_grid.sh'))
    $root = [regex]::Match($t, '(?s)\n    root\)(.*?);;').Groups[1].Value
    Assert-True ($root -match 'gi_registered \|\|') 'phase root needs a registered home, not CRS=true'
    $inst = [regex]::Match($t, '(?s)\n    install\)(.*?);;').Groups[1].Value
    Assert-True ($inst -match 'step_done grid_install') 'phase install skips after its done marker'
    Assert-True ($inst -match 'mark_done grid_install') 'phase install sets its done marker'
    $calls = @'
d=$(mktemp -d); GRID_HOME=$d/grid; INV_XML=$d/inv.xml; DONE_DIR=$d/done; mkdir -p $GRID_HOME $DONE_DIR
echo "<HOME NAME=\"OraGI\" LOC=\"$GRID_HOME\" TYPE=\"O\" IDX=\"1\"/>" > $INV_XML
gi_registered; echo "registered=$?"
gi_partial; echo "before_marker=$?"
touch $DONE_DIR/grid_install
gi_partial; echo "after_marker=$?"
'@
    $out = @(Invoke-BashFunction 'guest\rac\40_install_grid.sh' @('gi_installed', 'gi_registered', 'gi_partial') ("step_done() { [ -f `"`$DONE_DIR/`$1`" ]; }`n" + $calls))
    Assert-Equal 'registered=0' ($out -match '^registered=')[0] 'home in the inventory is registered'
    Assert-Equal 'before_marker=0' ($out -match '^before_marker=')[0] 'registered home without the install marker is partial'
    Assert-True (($out -match '^after_marker=')[0] -ne 'after_marker=0') 'finished software install (marker) is not partial'
}
# Build attempt 10 (15.11): gridSetup prereqs PRVG-11067/11138: no TCP over the interconnect ("No route to host").
# The kickstart put enp0s9 into the trusted zone offline, NetworkManager moved it back to public at boot.
# Kris: the lab (host-only network) runs without firewalld, as RAC labs usually do. Off in the kickstart and
# re-asserted by the guest scripts; the Windows rule for the kickstart server (port 8000) is a separate thing.
function Test-FirewallDisabled {
    $base = [IO.File]::ReadAllText((Join-Path $Repo 'kickstart\base.ks.tmpl'))
    Assert-True ($base -match '(?m)^firewall --disabled\s*$') 'kickstart: firewall --disabled'
    Assert-True ($base -notmatch '(?m)^firewall --enabled') 'kickstart: no firewall --enabled'
    foreach ($f in 'kickstart\role-rac.ks.tmpl', 'kickstart\role-tgt.ks.tmpl', 'kickstart\role-infra.ks.tmpl') {
        $p = Join-Path $Repo $f
        if (Test-Path $p) { Assert-True ([IO.File]::ReadAllText($p) -notmatch 'firewall-offline-cmd') "$f has no firewall-offline-cmd" }
    }
    foreach ($f in 'guest\infra\10_dnsmasq.sh', 'guest\rac\10_os_prereq.sh', 'guest\tgt\10_os_prereq.sh') {
        $t = [IO.File]::ReadAllText((Join-Path $Repo $f))
        Assert-True ($t -notmatch 'firewall-cmd') "$f does not configure firewalld zones"
        Assert-True ($t -match 'disable --now firewalld') "$f turns firewalld off on an existing VM"
    }
    foreach ($f in 'guest\infra\90_validate.sh', 'guest\rac\10_os_prereq.sh', 'guest\tgt\10_os_prereq.sh') {
        Assert-True ([IO.File]::ReadAllText((Join-Path $Repo $f)) -match 'check "firewalld off"') "$f checks firewalld off"
    }
}
# 16.11 (Kris): lab.cmd baseline = back to the base state (stage A) without touching data: services on their preferred
# instances, GoldenGate + ACFS + VIP on the node of the GG service, XAG started with retries, target database and
# GoldenGate up, then the validate checks. lab.cmd start ends with it. Each phase prints its duration (video).
# The disk snapshot formerly planned under this name is the verb snapshot (Task 12).
function Test-BaselineStep {
    $o = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') baseline -DryRun 2>&1 | Out-String
    Assert-Equal 0 $LASTEXITCODE "baseline -DryRun exit: $o"
    $pos = -1
    foreach ($line in '[ggtgt] bash /root/lab/tgt/95_baseline.sh', '[ggrac1] bash /root/lab/rac/95_baseline.sh',
                      '[ggrac1] bash /root/lab/rac/90_validate.sh grid db acfs ogg repl', '[ggtgt] bash /root/lab/tgt/90_validate.sh db ogg repl') {
        $i = $o.IndexOf("DRYRUN $line")
        Assert-True ($i -gt $pos) "baseline -DryRun: '$line' missing or out of order"
        $pos = $i
    }
    $s = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') start -DryRun 2>&1 | Out-String
    Assert-Equal 0 $LASTEXITCODE "start -DryRun exit: $s"
    Assert-True ($s.Contains('DRYRUN [ggrac1] bash /root/lab/rac/95_baseline.sh')) 'start ends with baseline'
    $r = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\95_baseline.sh'))
    foreach ($w in 'srvctl relocate service', 'srvctl start instance', 'agctl start goldengate', 'agctl relocate goldengate',
                   'srvctl stop filesystem', 'Preferred instances:', 'BASELINE ') {
        Assert-True ($r.Contains($w)) "rac/95_baseline.sh lacks $w"
    }
    foreach ($bad in 'crsctl stop', 'kill ', 'srvctl stop database', 'srvctl stop instance', '99_reset_demo', 'DELETE ') {
        Assert-True (-not $r.Contains($bad)) "rac/95_baseline.sh must not run $bad (it only puts things back)"
    }
    # Live run 16.11: lib.sh runs set -euo pipefail, inst_of returned 1 for the first node and the script exited silently
    $calls = @'
set -euo pipefail
SRC_DB=ggcdb; NAMES=(ggrac1 ggrac2)
a=$(inst_of ggrac1); b=$(inst_of ggrac2); c=$(node_of ggcdb2)
echo "got=$a,$b,$c"
'@
    $out = @(Invoke-BashFunction 'guest\rac\95_baseline.sh' @('inst_of', 'node_of') $calls)
    Assert-Equal 'got=ggcdb1,ggcdb2,ggrac2' ($out -match '^got=')[0] 'inst_of/node_of under set -e for every node'
    # Restart cycle 16.11: CRS starts the instances (and XAG) itself right after the cluster is up; an early
    # srvctl start instance raced it (PRCZ-4054 already running). Grace period first, PRCZ-4054 = success.
    Assert-True ($r -match 'wait_quiet [0-9]+ [^\r\n]*all_inst') 'instances: grace period for the CRS autostart before srvctl start instance'
    Assert-True ($r.Contains('PRCZ-4054')) 'instances: PRCZ-4054 (already running) counts as started'
    Assert-True ($r -match '(?s)for try in 1 2 3; do\s+if \[ "\$\(gg_node\)" = "\$want_node" \]') 'goldengate: each try first checks whether GoldenGate already runs'
    foreach ($fn in 'running_on', 'gg_node') {
        Assert-True ($r -match "(?m)^$fn\(\) \{.*\|\| true; \}$") "$fn never fails the script (set -e, pipefail): ends with || true"
    }
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\tgt\95_baseline.sh'))
    foreach ($w in 'systemctl start oracle-db.service', 'OracleGoldenGate.service', 'BASELINE ') { Assert-True ($t.Contains($w)) "tgt/95_baseline.sh lacks $w" }
    Import-Module (Join-Path $Repo 'host\Guest.psm1') -Force -DisableNameChecking
    $rows = @(ConvertFrom-BaselineLines -Node 'ggrac1' -Lines @('noise', 'BASELINE services 12 done srv_load2 ggcdb1->ggcdb2', 'BASELINE acfs 0 noop'))
    Assert-Equal 2 $rows.Count 'two BASELINE lines'
    Assert-Equal 'services' $rows[0].phase 'phase'
    Assert-Equal '12' "$($rows[0].seconds)" 'seconds'
    Assert-Equal 'done' $rows[0].action 'action'
    Assert-Equal 'srv_load2 ggcdb1->ggcdb2' $rows[0].detail 'detail'
    Assert-Equal 'ggrac1' $rows[1].node 'node'
}
# 16.11, first restart of ggtgt: oracle-db.service failed 203/EXEC "Permission denied" on dbstart. SELinux enforcing,
# the Oracle home is default_t and systemd (init_t) may not exec it. bash (shell_exec_t) reads the script instead.
function Test-TgtAutostartSelinux {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\tgt\60_create_db.sh'))
    Assert-True ($t -match '(?m)^ExecStart=/usr/bin/bash \$DB_HOME/bin/dbstart \$DB_HOME$') 'oracle-db.service: ExecStart through /usr/bin/bash'
    Assert-True ($t -match '(?m)^ExecStop=/usr/bin/bash \$DB_HOME/bin/dbshut \$DB_HOME$') 'oracle-db.service: ExecStop through /usr/bin/bash'
    $v = [IO.File]::ReadAllText((Join-Path $Repo 'guest\tgt\90_validate.sh'))
    Assert-True ($v -match 'check "systemd: oracle-db.service active"') 'tgt validate: oracle-db.service active (not only enabled)'
}
# 16.11 08:13: ggcdb1 terminated by LMHB (ORA-29770, LMD0 hung > 70 s). ggrac1 (2 vCPU) had load 50-140, mostly AHF/TFA
# (tfactl rediscover, ahfctl adrci) installed with GI 23.26. Kris: AHF is not needed in the lab, turn it off.
# oracle-tfa.service has Restart=always, so stopping the scheduler alone is not enough: the unit is disabled too.
function Test-AhfDisabled {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\40_install_grid.sh'))
    Assert-True ($t -match '(?m)^\s+ahf\)') '40_install_grid.sh has an ahf phase'
    Assert-True ($t -match 'ahfctl stopahf -all') 'ahf phase stops the AHF scheduler (ahfctl stopahf -all)'
    Assert-True ($t -match 'systemctl disable --now oracle-tfa') 'ahf phase disables oracle-tfa.service (Restart=always)'
    Assert-True ($t -match 'phase: stage\|cvuqdisk\|install\|root\|config\|fra\|ahf') 'usage line lists ahf'
    $v = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\90_validate.sh'))
    Assert-True ($v -match 'check "AHF/TFA off') '90_validate.sh grid checks AHF/TFA off'
}
# Build attempt 10 (15.11): the 23.26 GI image ZIP ships root.sh, so "root.sh exists" flagged a fresh home as a partial
# install before gridSetup ever ran. Partial = home registered in the inventory without CRS="true", nothing else.
function Test-GiPartialIgnoresShippedRootSh {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\40_install_grid.sh'))
    $calls = @'
d=$(mktemp -d); GRID_HOME=$d/grid; INV_XML=$d/inv.xml; mkdir -p $GRID_HOME; touch $GRID_HOME/root.sh
gi_partial; echo "fresh=$?"
echo "<HOME NAME=\"OraGI\" LOC=\"$GRID_HOME\" TYPE=\"O\" IDX=\"1\"/>" > $INV_XML
gi_partial; echo "registered=$?"
echo "<HOME NAME=\"OraGI\" LOC=\"$GRID_HOME\" TYPE=\"O\" IDX=\"1\" CRS=\"true\"/>" > $INV_XML
gi_partial; echo "installed=$?"
'@
    $out = @(Invoke-BashFunction 'guest\rac\40_install_grid.sh' @('gi_installed', 'gi_registered', 'gi_partial') ("step_done() { false; }`n" + $calls))
    Assert-True (($out -match '^fresh=')[0] -ne 'fresh=0') 'unzipped home with the shipped root.sh is not partial'
    Assert-Equal 'registered=0' ($out -match '^registered=')[0] 'home in the inventory without CRS=true is partial'
    Assert-Equal 'installed=1' ($out -match '^installed=')[0] 'installed home is not partial'
}
# Build attempt 10 (15.11): prereq failed "THP never". Oracle 26ai on UEK7+ wants Transparent HugePages = madvise
# (26ai install guide; the 26ai preinstall RPM sets it at boot), not disabled as in earlier releases. Our own
# disable-thp.service fought the preinstall RPM. Checks expect madvise, the kickstart no longer writes never.
function Test-ThpMadvise {
    foreach ($f in 'guest\rac\10_os_prereq.sh', 'guest\tgt\10_os_prereq.sh') {
        $t = [IO.File]::ReadAllText((Join-Path $Repo $f))
        Assert-True ($t -match "check `"THP madvise`"\s+grep -q '\\\[madvise\\\]' /sys/kernel/mm/transparent_hugepage/enabled") "$f checks THP madvise"
        Assert-True ($t -notmatch '\[never\]') "$f does not expect THP never"
    }
    foreach ($node in 'ggrac1', 'ggtgt') {
        $ks = Get-TestKs $node -Masked
        Assert-True ($ks -notmatch 'echo never > /sys/kernel/mm/transparent_hugepage') "${node}: kickstart does not force THP never"
        Assert-True ($ks -match 'vm\.nr_hugepages') "${node}: standard HugePages stay"
    }
}
# Build attempt 9 (15.11): %post on ggrac1/ggrac2 switched the resolver to gginfra (no dnsmasq yet during build), then
# "dnf versionlock add" tried to fetch repo metadata, failed, and set -e cut %post in half: no grid user, THP, HugePages,
# NOZEROCONF. Every dnf call in %post must work offline (--disablerepo='*'); the lock needs installed packages only.
function Test-KsPostDnfOffline {
    foreach ($node in 'gginfra', 'ggrac1', 'ggtgt') {
        $ks = Get-TestKs $node -Masked
        $post = [regex]::Match($ks, '(?s)%post.*?%end').Value
        $dnf = @([regex]::Matches($post, '(?m)^\s*dnf\s.*$') | ForEach-Object Value)
        $bad = @($dnf | Where-Object { $_ -notmatch "--disablerepo='\*'" })
        Assert-True ($bad.Count -eq 0) "${node}: dnf in %post needs the network: $($bad -join ' | ')"
    }
    Assert-True ((Get-TestKs 'ggrac1' -Masked) -match "(?m)^dnf .*--disablerepo='\*' versionlock add") 'ggrac1 still locks the kernel'
}
# Same attempt: build marked ggrac1/ggrac2 installed although %post stopped halfway; prereq found it 10 min later.
# A VM gets the installed flag only when its %post log ends with POST-INSTALL DONE.
function Test-BuildChecksPostDone {
    $lab = [IO.File]::ReadAllText((Join-Path $Repo 'lab.ps1'))
    $fn = [regex]::Match($lab, '(?s)function Install-VmOs\b[^{]*\{(.*?)\n\}').Groups[1].Value
    $iPost = $fn.IndexOf('POST-INSTALL DONE'); $iFlag = $fn.IndexOf('Set-VmInstalled')
    Assert-True ($iPost -ge 0) 'Install-VmOs checks POST-INSTALL DONE in /root/ks-post.log'
    Assert-True ($iPost -lt $iFlag) 'the check comes before Set-VmInstalled'
    Assert-True ([IO.File]::ReadAllText((Join-Path $Repo 'kickstart\base.ks.tmpl')) -match 'POST-INSTALL DONE ===') 'kickstart still prints the marker'
}
# Build attempt 8 (15.11): with DNS from gginfra working, "chronyc sources" prints "^* gginfra.gg.lab.test", so a grep
# for 192.168.58.10 never matched and prereq waited 60 s for a sync that was already there. -n = addresses, no names.
function Test-ChronycSourcesNumeric {
    $hits = foreach ($f in Get-ChildItem (Join-Path $Repo 'guest') -Recurse -File -Filter '*.sh') {
        $i = 0
        foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
            $i++
            if ($l -match 'chronyc\s+sources' -and $l -match 'INFRA_IP') { "$($f.Name):$i" }
        }
    }
    Assert-True (-not $hits) "chronyc sources compared with an IP without -n (prints the name): $($hits -join ', ')"
}

# ------------------------------------------------------------------------------
# Task 6
# ------------------------------------------------------------------------------
# Password placeholder built from parts: the literal never sits in this file as one token
$script:PassToken = '@@LAB' + '_PASS@@'
function Get-SqlText([string]$Name) {
    $p = Join-Path $Repo "sql\$Name"
    Assert-True (Test-Path $p) "missing sql\$Name"
    [IO.File]::ReadAllText($p)
}
function Test-SqlHeaders {
    foreach ($f in '01_src_prep_cdb.sql', '03_tgt_prep_cdb.sql', '05_demo_schema.sql', '06_loadgen.sql', '99_reset_demo.sql') {
        $t = Get-SqlText $f
        $head = ($t -split "`n" | Select-Object -First 30) -join "`n"
        foreach ($w in "Tytul:        $f", 'Description [EN]:', 'Wymagania [PL]:', 'Requirements [EN]:', 'Uzycie [PL]:', 'Usage [EN]:', 'Konwencje:    <repo>/SETTINGS.md') {
            Assert-True ($head.Contains($w)) "$f header lacks '$w'"
        }
        Assert-True ($t -match '(?m)^WHENEVER SQLERROR EXIT') "$f must stop on the first SQL error"
        Assert-True ($t -notmatch '(?i)IDENTIFIED BY') "$f must not create password users (Task 8 does, from stdin)"
        Assert-True (-not $t.Contains($script:PassToken)) "$f must not carry the password placeholder"
    }
}
function Test-NoGrantAdminPrivilege {
    $files = @(Get-ChildItem (Join-Path $Repo 'sql') -File -Filter '*.sql') +
             @(Get-ChildItem (Join-Path $Repo 'guest') -Recurse -File -Filter '*.sh' | Where-Object FullName -notmatch '\\out\\')
    Assert-True ($files.Count -ge 5) 'sql files present'
    foreach ($f in $files) {
        $t = [IO.File]::ReadAllText($f.FullName)
        foreach ($bad in 'GRANT_ADMIN_PRIVILEGE', 'c##ggadmin', 'GRANT\s+DBA\b', 'CONTAINER\s*=\s*ALL') {
            Assert-True ($t -notmatch "(?i)$bad") "$($f.Name) contains $bad (per-PDB model: OGG_CAPTURE/OGG_APPLY only)"
        }
    }
}
function Test-SrcPrepBlock1 {
    $t = Get-SqlText '01_src_prep_cdb.sql'
    foreach ($w in "enable_goldengate_replication=TRUE SCOPE=BOTH SID=''*''", "streams_pool_size=' || &1 || 'M SCOPE=BOTH SID=''*''",
                   'ALTER DATABASE FORCE LOGGING', 'ALTER DATABASE ADD SUPPLEMENTAL LOG DATA', 'ALTER SYSTEM ARCHIVE LOG CURRENT',
                   'FROM v$thread', 'gv$parameter') {
        Assert-True ($t.Contains($w)) "01_src_prep_cdb.sql lacks: $w"
    }
    Assert-True ($t -notmatch '(?m)^[^-\r\n]*SUBSET DATABASE REPLICATION') 'variant B stays a comment (LAB to confirm)'
    $g = Get-SqlText '03_tgt_prep_cdb.sql'
    foreach ($w in "enable_goldengate_replication=TRUE SCOPE=BOTH", 'ALTER DATABASE FORCE LOGGING', 'SAVE STATE') {
        Assert-True ($g.Contains($w)) "03_tgt_prep_cdb.sql lacks: $w"
    }
}
function Test-DemoSchemaTypes {
    $d = Get-SqlText '05_demo_schema.sql'
    foreach ($w in 'CREATE USER IF NOT EXISTS hr NO AUTHENTICATION', 'CREATE USER IF NOT EXISTS sales NO AUTHENTICATION', 'CREATE TABLE IF NOT EXISTS sales.types26',
                   'v VECTOR(3, FLOAT32)', 'b BOOLEAN', 'j JSON', 'CREATE TABLE IF NOT EXISTS sales.load_events', 'ALTER SESSION SET CONTAINER = &1') {
        Assert-True ($d.Contains($w)) "05_demo_schema.sql lacks: $w"
    }
    # Every replicated table needs a key (GoldenGate without a key logs all columns)
    $tables = [regex]::Matches($d, '(?i)CREATE TABLE IF NOT EXISTS (\w+\.\w+)') | ForEach-Object { $_.Groups[1].Value }
    Assert-True (@($tables).Count -ge 5) 'demo tables'
    $pk = [regex]::Matches($d, '(?i)PRIMARY KEY').Count
    Assert-True ($pk -ge @($tables).Count) "each demo table has a primary key ($pk keys, $(@($tables).Count) tables)"
    $l = Get-SqlText '06_loadgen.sql'
    foreach ($w in 'CREATE OR REPLACE PACKAGE sales.loadgen', 'PROCEDURE run(p_rows_per_sec IN PLS_INTEGER, p_seconds IN PLS_INTEGER)',
                   "SYS_CONTEXT('USERENV', 'INSTANCE')", 'sales.load_seq.NEXTVAL', 'COMMIT') {
        Assert-True ($l.Contains($w)) "06_loadgen.sql lacks: $w"
    }
    $r = Get-SqlText '99_reset_demo.sql'
    Assert-True ($r -match '(?s)KROK 1.*KROK 2.*KROK 3') '99_reset_demo.sql: preview -> change -> verify'
}
function Test-DbRspRendered {
    $old = $env:LAB_PASS
    try {
        $env:LAB_PASS = 'Static_Test_Pass_42'
        $ri = Get-TestGuestFile 'ggrac1' 'db_install.rsp'
        foreach ($kv in 'oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v23.0.0',
                        'installOption=INSTALL_DB_SWONLY', 'ORACLE_HOME=/u01/app/oracle/product/23.26/dbhome_1',
                        'ORACLE_BASE=/u01/app/oracle', 'clusterNodes=ggrac1,ggrac2', 'installEdition=EE', 'OSRACDBA=racdba') {
            Assert-True ($ri -match "(?m)^$([regex]::Escape($kv))$") "db_install.rsp (ggrac1) lacks $kv"
        }
        # 26ai (23.26) key names: the oracle.install.* names of earlier releases are not in the 23.26 sample
        $legacy = @([regex]::Matches($ri, '(?m)^oracle\.install\.(?!responseFileVersion)[^=]+=') | ForEach-Object Value)
        Assert-True ($legacy.Count -eq 0) "db_install.rsp has pre-26ai keys: $($legacy -join ' ')"
        $ti = Get-TestGuestFile 'ggtgt' 'db_install.rsp'
        Assert-True ($ti -match '(?m)^clusterNodes=$') 'db_install.rsp (ggtgt): single instance, no cluster nodes'
        $s = Get-TestGuestFile 'ggrac1' 'dbca_src.rsp'
        foreach ($kv in 'gdbName=ggcdb', 'sid=ggcdb', 'databaseConfigType=RAC', 'nodelist=ggrac1,ggrac2', 'createAsContainerDatabase=true',
                        'pdbName=SRCPDB', 'storageType=ASM', 'datafileDestination=+DATA/{DB_UNIQUE_NAME}/', 'recoveryAreaDestination=+FRA',
                        'characterSet=AL32UTF8', 'automaticMemoryManagement=false') {
            Assert-True ($s -match "(?m)^$([regex]::Escape($kv))$") "dbca_src.rsp lacks $kv"
        }
        Assert-True ($s -match '(?m)^initParams=.*sga_target=4096M') 'dbca_src.rsp SGA from Oracle.SrcSgaMb'
        $t = Get-TestGuestFile 'ggtgt' 'dbca_tgt.rsp'
        foreach ($kv in 'gdbName=tgtcdb', 'sid=tgtcdb', 'databaseConfigType=SI', 'pdbName=TGTPDB', 'storageType=FS') {
            Assert-True ($t -match "(?m)^$([regex]::Escape($kv))$") "dbca_tgt.rsp lacks $kv"
        }
        Assert-True ($t -match '(?m)^initParams=.*sga_target=2560M') 'dbca_tgt.rsp SGA from Oracle.TgtSgaMb'
        foreach ($x in @($ri, $ti, $s, $t)) {
            Assert-True ($x -notmatch 'Static_Test_Pass_42') 'rsp must not carry the password'
            Assert-True ($x -notmatch "`r") 'LF only'
        }
        foreach ($k in 'sysPassword', 'systemPassword', 'pdbAdminPassword') {
            Assert-True ($s -match "(?m)^$k=$([regex]::Escape($script:PassToken))$") "dbca_src.rsp $k placeholder (filled on the VM)"
            Assert-True ($t -match "(?m)^$k=$([regex]::Escape($script:PassToken))$") "dbca_tgt.rsp $k placeholder (filled on the VM)"
        }
    } finally { $env:LAB_PASS = $old }
}
function Test-DbStepsDryRun {
    $order = [ordered]@{
        grid     = @('[ggrac1] bash /root/lab/rac/40_install_grid.sh config', '[ggrac1] bash /root/lab/rac/40_install_grid.sh fra',
                     '[ggrac1] bash /root/lab/rac/90_validate.sh grid')
        db       = @('[ggrac1] bash /root/lab/rac/50_install_db.sh stage', '[ggrac1] bash /root/lab/rac/50_install_db.sh install',
                     '[ggrac1] bash /root/lab/rac/50_install_db.sh root', '[ggrac2] bash /root/lab/rac/50_install_db.sh root')
        dbca     = @('[ggrac1] bash /root/lab/rac/60_create_db.sh')
        services = @('[ggrac1] bash /root/lab/rac/65_services.sh', '[ggrac1] bash /root/lab/rac/90_validate.sh db')
        tgt      = @('[ggtgt] bash /root/lab/tgt/10_os_prereq.sh', '[ggtgt] bash /root/lab/tgt/50_install_db.sh stage',
                     '[ggtgt] bash /root/lab/tgt/50_install_db.sh install', '[ggtgt] bash /root/lab/tgt/50_install_db.sh root',
                     '[ggtgt] bash /root/lab/tgt/60_create_db.sh', '[ggtgt] bash /root/lab/tgt/90_validate.sh db')
    }
    foreach ($verb in $order.Keys) {
        $out = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') $verb -DryRun 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE "lab.ps1 $verb -DryRun exit: $out"
        $pos = -1
        foreach ($line in $order[$verb]) {
            $i = $out.IndexOf("DRYRUN $line")
            Assert-True ($i -gt $pos) "$verb -DryRun: '$line' missing or out of order"
            $pos = $i
        }
    }
    $db = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') db -DryRun 2>&1 | Out-String
    Assert-True ($db -match "DRYRUN \[ggrac1\] scp 'V1054592-01") 'db copies the DB ZIP to the first RAC node'
}
function Test-DbValidateSections {
    $v = Get-Content -Raw (Join-Path $Repo 'guest\rac\90_validate.sh')
    # SQL inside bash double quotes: the views are written v\$name
    foreach ($w in 'validate_db', 'srvctl status database -db $SRC_DB', 'v\$thread', 'ARCHIVELOG', 'force_logging',
                   'enable_goldengate_replication', 'streams_pool_size', 'STREAMS_POOL_MB', 'gv\$pdbs', 'Preferred instances: ${SRC_DB}1',
                   'Available instances: ${SRC_DB}2', '$GG_SERVICE', 'srv_load', 'types26') {
        Assert-True ($v.Contains($w)) "rac 90_validate.sh (db) lacks $w"
    }
    $t = Get-Content -Raw (Join-Path $Repo 'guest\tgt\90_validate.sh')
    foreach ($w in 'validate_db', 'v\$database', 'OPEN', 'READ WRITE', '$TGT_PDB', 'force_logging', 'enable_goldengate_replication',
                   'lsnrctl status', 'types26', 'finish_checks') {
        Assert-True ($t.Contains($w)) "tgt 90_validate.sh lacks $w"
    }
}
function Test-DbScriptsSafe {
    $lib = Get-Content -Raw (Join-Path $Repo 'guest\lib.sh')
    foreach ($w in 'sysdba_query()', 'sysdba_file()') { Assert-True ($lib.Contains($w)) "lib.sh lacks $w" }
    foreach ($w in 'rac', 'tgt') {
        $t = Get-Content -Raw (Join-Path $Repo "guest\$w\50_install_db.sh")
        Assert-True ($t -match '(?m)^exec bash /root/lab/shared/install_db\.sh "\$@"$') "$w/50_install_db.sh runs the shared installer"
    }
    foreach ($f in 'shared\install_db.sh', 'rac\60_create_db.sh', 'rac\65_services.sh', 'tgt\60_create_db.sh') {
        $t = Get-Content -Raw (Join-Path $Repo "guest\$f")
        Assert-True ($t -match 'source /root/lab/lib\.sh') "$f sources lib.sh"
        # dbca and runInstaller read passwords from the 600 rsp only, never from argv
        Assert-True ($t -notmatch '(?i)-(sys|system|pdbAdmin)Password\s') "$f passes a password in argv"
        Assert-True ($t -notmatch '\$LAB_PASS') "$f must not expand LAB_PASS (render_secret does it)"
    }
    $c = Get-Content -Raw (Join-Path $Repo 'guest\rac\60_create_db.sh')
    Assert-True ($c.Contains('srvctl config database -db $SRC_DB')) '60_create_db.sh skips an existing database'
    Assert-True ($c.Contains('rm -f "$RSP"')) '60_create_db.sh removes the rendered rsp'
    $s = Get-Content -Raw (Join-Path $Repo 'guest\rac\65_services.sh')
    Assert-True ($s.Contains('-preferred ${SRC_DB}1 -available ${SRC_DB}2')) 'gg service is a singleton with an available instance'
    $g = Get-Content -Raw (Join-Path $Repo 'guest\rac\40_install_grid.sh')
    Assert-True ($g -match 'asmca -silent -createDiskGroup -diskGroupName FRA') 'grid step creates +FRA (grid validate expects it)'
}

# ------------------------------------------------------------------------------
# Task 7
# ------------------------------------------------------------------------------
function Get-TestGuestVars([string]$Node, [string]$ConfigPath) {
    Import-LabModules
    Import-Module (Join-Path $Repo 'host\Guest.psm1') -Force -DisableNameChecking
    if (-not $ConfigPath) { $ConfigPath = Join-Path $Repo 'lab.config.psd1' }
    Get-GuestVars (Get-GgConfig -Path $ConfigPath) $Node @()
}
function Test-AgctlMaCommand {
    $v = Get-TestGuestVars 'ggrac1'
    $a = " $($v.OGG_AGCTL_ARGS) "
    foreach ($w in '--gg_home /u01/app/ogg/ogg26ai_ma', '--config_home /u01/oggdeploy/ggsm01/etc/conf', '--var_home /u01/oggdeploy/ggsm01/var',
                   '--port 9100', '--oracle_home /u01/app/ogg/ogg26ai_ma/lib/instantclient', '--adminuser oggadmin', '--user oracle', '--group oinstall',
                   '--vip_name oggvip', '--filesystems ora.data.oggvol.acfs', '--db_services ora.ggcdb.gg_srcpdb.svc', '--use_local_services',
                   '--nodes ggrac1,ggrac2') {
        Assert-True ($a.Contains(" $w ")) "agctl args lack '$w': $a"
    }
    Assert-True ($a -notmatch '--instance_type') 'agctl MA registration has no --instance_type (Classic only)'
    Assert-True ($a -notmatch '--service_manager') 'the script adds --service_manager (form yes or bare flag)'
    $s = Get-Content -Raw (Join-Path $Repo 'guest\rac\87_xag_register.sh')
    Assert-True ($s.Contains('"$AGCTL" add goldengate "$OGG_SRC_DEPLOY" --service_manager $form $OGG_AGCTL_ARGS')) '87 builds the agctl add line from OGG_AGCTL_ARGS (XAG_HOME agctl)'
    Assert-True ($s -match "for form in '' yes") '87 tries the bare --service_manager flag (XAG Microservices template), then "yes"'
    Assert-True ($s -notmatch '--instance_type') '87 has no --instance_type'
}
function Test-OggRspRendered {
    $old = $env:LAB_PASS
    try {
        $env:LAB_PASS = 'Static_Test_Pass_42'
        $c = Get-TestGuestFile 'ggrac1' 'oggcore.rsp'
        foreach ($kv in 'oracle.install.responseFileVersion=/oracle/install/rspfmt_ogginstall_response_schema_v23_1_0',
                        'SOFTWARE_LOCATION=/u01/app/ogg/ogg26ai_ma', 'INVENTORY_LOCATION=/u01/app/oraInventory', 'UNIX_GROUP_NAME=oinstall') {
            Assert-True ($c -match "(?m)^$([regex]::Escape($kv))$") "oggcore.rsp lacks $kv"
        }
        $s = Get-TestGuestFile 'ggrac1' 'oggca_source.rsp'
        foreach ($kv in 'oracle.install.responseFileVersion=/oracle/install/rspfmt_oggca_response_schema_v23_1_0', 'CONFIGURATION_OPTION=ADD',
                        'DEPLOYMENT_NAME=oggsource', 'ADMINISTRATOR_USER=oggadmin', 'SERVICEMANAGER_DEPLOYMENT_HOME=/u01/oggdeploy/ggsm01',
                        'HOST_SERVICEMANAGER=oggvip.gg.lab.test', 'PORT_SERVICEMANAGER=9100', 'CREATE_NEW_SERVICEMANAGER=true',
                        'REGISTER_SERVICEMANAGER_AS_A_SERVICE=false', 'INTEGRATE_SERVICEMANAGER_WITH_XAG=true',
                        'OGG_SOFTWARE_HOME=/u01/app/ogg/ogg26ai_ma', 'OGG_DEPLOYMENT_HOME=/u01/oggdeploy/oggsource',
                        'ENV_TNS_ADMIN=/u01/oggdeploy/oggsource/etc', 'PORT_ADMINSRVR=9101', 'PORT_DISTSRVR=9102', 'PORT_RCVRSRVR=9103',
                        'SECURITY_ENABLED=false', 'OGG_SCHEMA=ggadmin') {
            Assert-True ($s -match "(?m)^$([regex]::Escape($kv))$") "oggca_source.rsp lacks $kv"
        }
        $t = Get-TestGuestFile 'ggtgt' 'oggca_target.rsp'
        foreach ($kv in 'DEPLOYMENT_NAME=oggtarget', 'HOST_SERVICEMANAGER=ggtgt.gg.lab.test', 'REGISTER_SERVICEMANAGER_AS_A_SERVICE=true',
                        'INTEGRATE_SERVICEMANAGER_WITH_XAG=false', 'OGG_DEPLOYMENT_HOME=/u01/oggdeploy/oggtarget', 'PORT_RCVRSRVR=9103') {
            Assert-True ($t -match "(?m)^$([regex]::Escape($kv))$") "oggca_target.rsp lacks $kv"
        }
        foreach ($x in @($s, $t)) {
            Assert-True ($x -match "(?m)^ADMINISTRATOR_PASSWORD=$([regex]::Escape('@@OGG_ADMIN' + '_PASS@@'))$") 'GoldenGate admin password placeholder (ogg_admin_pass, filled on the VM)'
            Assert-True ($x -notmatch 'Static_Test_Pass_42') 'oggca rsp must not carry the password'
        }
    } finally { $env:LAB_PASS = $old }
}
function Test-OggStepsDryRun {
    $order = [ordered]@{
        acfs = @('[ggrac1] bash /root/lab/rac/70_acfs.sh prep', '[ggrac2] bash /root/lab/rac/70_acfs.sh prep',
                 '[ggrac1] bash /root/lab/rac/70_acfs.sh create', '[ggrac1] bash /root/lab/rac/90_validate.sh acfs')
        ogg  = @('[ggrac1] bash /root/lab/rac/80_install_ogg.sh', '[ggrac2] bash /root/lab/rac/80_install_ogg.sh',
                 '[ggtgt] bash /root/lab/tgt/80_install_ogg.sh', '[ggtgt] bash /root/lab/tgt/86_oggca_target.sh',
                 '[ggtgt] bash /root/lab/tgt/90_validate.sh ogg')
        xag  = @('[ggrac1] bash /root/lab/rac/85_install_xag.sh', '[ggrac1] bash /root/lab/rac/87_xag_register.sh vip',
                 '[ggrac1] bash /root/lab/rac/86_oggca_source.sh', '[ggrac1] bash /root/lab/rac/87_xag_register.sh add',
                 '[ggrac1] bash /root/lab/rac/90_validate.sh ogg')
    }
    foreach ($verb in $order.Keys) {
        $out = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') $verb -DryRun 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE "lab.ps1 $verb -DryRun exit: $out"
        $pos = -1
        foreach ($line in $order[$verb]) {
            $i = $out.IndexOf("DRYRUN $line")
            Assert-True ($i -gt $pos) "$verb -DryRun: '$line' missing or out of order"
            $pos = $i
        }
    }
}
function Test-OggValidateSections {
    $v = Get-Content -Raw (Join-Path $Repo 'guest\rac\90_validate.sh')
    foreach ($w in 'validate_acfs', 'acfsdriverstate supported', '$OGG_ACFS_RES', 'ONLINE', 'validate_ogg', 'command -v agctl', '$XAG_HOME/bin/agctl',
                   'agctl status goldengate $OGG_SRC_DEPLOY', '$OGG_SM_PORT', '$OGG_VIP_NAME') {
        Assert-True ($v.Contains($w)) "rac 90_validate.sh lacks $w"
    }
    $t = Get-Content -Raw (Join-Path $Repo 'guest\tgt\90_validate.sh')
    foreach ($w in 'validate_ogg', '$OGG_SM_PORT', 'OracleGoldenGate') { Assert-True ($t.Contains($w)) "tgt 90_validate.sh lacks $w" }
}
function Test-OggScriptsSafe {
    foreach ($f in 'shared\install_ogg.sh', 'rac\70_acfs.sh', 'rac\85_install_xag.sh', 'rac\86_oggca_source.sh', 'rac\87_xag_register.sh', 'tgt\86_oggca_target.sh') {
        $t = Get-Content -Raw (Join-Path $Repo "guest\$f")
        Assert-True ($t -match 'source /root/lab/lib\.sh') "$f sources lib.sh"
        Assert-True ($t -notmatch '(?i)--?password[ =]') "$f passes a password in argv"
    }
    foreach ($w in 'rac', 'tgt') {
        $t = Get-Content -Raw (Join-Path $Repo "guest\$w\80_install_ogg.sh")
        Assert-True ($t -match '(?m)^exec bash /root/lab/shared/install_ogg\.sh "\$@"$') "$w/80_install_ogg.sh runs the shared installer"
    }
    $a = Get-Content -Raw (Join-Path $Repo 'guest\rac\70_acfs.sh')
    # Docs check 15.11: libblkid has no ACFS prober; asmcmd volinfo reports the volume usage instead
    Assert-True ($a -match 'volinfo[^\r\n]*Usage: \*ACFS' -and $a -notmatch 'blkid -o') '70_acfs.sh checks the volume before mkfs (never formats an ACFS volume twice)'
    Assert-True ($a -notmatch 'mkfs[^\r\n]*-f\b') '70_acfs.sh never forces mkfs'
    $x = Get-Content -Raw (Join-Path $Repo 'guest\rac\87_xag_register.sh')
    Assert-True ($x -match 'printf .%s\\n. "\$\(ogg_admin_pass\)" \|') '87 feeds the oggadmin password to agctl on stdin'
    Assert-True ($x -match 'appvipcfg create') '87 vip creates the application VIP before oggca binds to it'
    $o = Get-Content -Raw (Join-Path $Repo 'guest\rac\86_oggca_source.sh')
    foreach ($w in 'OGGSOURCE_PDB', 'PROTOCOL = IPC', 'KEY = LISTENER', 'SERVICE_NAME = ${GG_SERVICE}') { Assert-True ($o.Contains($w)) "86 tnsnames lacks $w" }
}

# ------------------------------------------------------------------------------
# Task 8
# ------------------------------------------------------------------------------
function Get-OggText([string]$Name) {
    $p = Join-Path $Repo "ogg\$Name"
    Assert-True (Test-Path $p) "missing ogg\$Name"
    [IO.File]::ReadAllText($p)
}
function Test-PrmNoPassword {
    $prm = @(Get-ChildItem (Join-Path $Repo 'ogg') -Filter '*.prm')
    Assert-Equal 2 $prm.Count 'ext1.prm and rep1.prm'
    foreach ($f in $prm) {
        $t = [IO.File]::ReadAllText($f.FullName)
        Assert-True ($t -notmatch '(?im)^\s*[^-\r\n]*\bPASSWORD\b') "$($f.Name) contains PASSWORD"
        Assert-True ($t -notmatch '(?im)^\s*USERID\s') "$($f.Name) uses USERID instead of USERIDALIAS"
        Assert-True ($t -match '(?im)^USERIDALIAS \w+ DOMAIN OracleGoldenGate') "$($f.Name) lacks USERIDALIAS ... DOMAIN OracleGoldenGate"
    }
    $e = Get-OggText 'ext1.prm'
    foreach ($w in 'EXTRACT ext1', 'USERIDALIAS ggsource', 'EXTTRAIL et', 'TABLE HR.*;', 'TABLE SALES.*;') { Assert-True ($e.Contains($w)) "ext1.prm lacks $w" }
    $r = Get-OggText 'rep1.prm'
    foreach ($w in 'REPLICAT rep1', 'USERIDALIAS ggtarget', 'MAP HR.*, TARGET HR.*;', 'MAP SALES.*, TARGET SALES.*;') { Assert-True ($r.Contains($w)) "rep1.prm lacks $w" }
    # No secret in any obey file either (passwords travel through the adminclient pipe only)
    foreach ($f in Get-ChildItem (Join-Path $Repo 'ogg') -Filter '*.oby') {
        Assert-True ([IO.File]::ReadAllText($f.FullName) -notmatch '(?i)\bPASSWORD\b') "$($f.Name) contains PASSWORD"
    }
}
function Test-ReplicatHasCheckpoint {
    $t = Get-OggText 'setup_target.oby'
    Assert-True ($t -match '(?m)^ADD CHECKPOINTTABLE ggadmin\.ggs_checkpoint$') 'checkpoint table created before the Replicat'
    Assert-True ($t -match '(?m)^ADD REPLICAT rep1, PARALLEL, EXTTRAIL et, CHECKPOINTTABLE ggadmin\.ggs_checkpoint$') 'Parallel Replicat with the checkpoint table (no option = classic Replicat)'
    Assert-True ($t.IndexOf('ADD CHECKPOINTTABLE') -lt $t.IndexOf('ADD REPLICAT')) 'checkpoint table first'
    Assert-True ($t -match '(?m)^DBLOGIN USERIDALIAS ggtarget DOMAIN OracleGoldenGate$') 'DBLOGIN by alias'
    Assert-True ($t -match '(?m)^START REPLICAT rep1$') 'Replicat started'
}
function Test-RegisterNoContainer {
    foreach ($f in Get-ChildItem (Join-Path $Repo 'ogg') -Filter '*.oby') {
        Assert-True ([IO.File]::ReadAllText($f.FullName) -notmatch '(?im)^[^-\r\n]*\bCONTAINER\b') "$($f.Name): per-PDB Extract registers without CONTAINER"
    }
    $s = Get-OggText 'setup_source.oby'
    foreach ($re in '^DBLOGIN USERIDALIAS ggsource DOMAIN OracleGoldenGate$', '^ADD SCHEMATRANDATA HR$', '^ADD SCHEMATRANDATA SALES$',
                    '^ADD HEARTBEATTABLE, FREQUENCY 5$', '^REGISTER EXTRACT ext1 DATABASE$', '^ADD EXTRACT ext1, INTEGRATED TRANLOG, BEGIN NOW$',
                    '^ADD EXTTRAIL et, EXTRACT ext1$', '^START EXTRACT ext1$') {
        Assert-True ($s -match "(?m)$re") "setup_source.oby lacks $re"
    }
    $p = Get-OggText 'setup_path.oby'
    Assert-True ($p -match '(?m)^ADD DISTPATH dp1 SOURCE trail://localhost:\{\{OGG_PORT_DIST\}\}/services/v2/sources\?trail=et TARGET \{\{OGG_PATH_PROTO\}\}://\{\{TGT_NAME\}\}\.\{\{LAB_DOMAIN\}\}:\{\{OGG_PORT_RECV\}\}/services/v2/targets\?trail=et AUTHENTICATION USERIDALIAS ggtgt_dp DOMAIN OracleGoldenGate$') 'ADD DISTPATH from localhost (any RAC node) to the target Receiver'
    Assert-True ($p -match '(?m)^START DISTPATH dp1$') 'path started'
}
function Test-UsersSql {
    foreach ($f in '02_src_users_pdb.sql', '04_tgt_users_pdb.sql') {
        $t = Get-SqlText $f
        Assert-True ($t.Contains("IDENTIFIED BY `"$($script:PassToken)`"")) "${f}: password placeholder, filled on the VM by render_secret"
        Assert-True ($t -match '(?m)^SET ECHO OFF') "$f must not echo the password into the log"
        Assert-True ($t -match 'CREATE USER IF NOT EXISTS ggadmin') "$f creates a local ggadmin"
    }
    Assert-True ((Get-SqlText '02_src_users_pdb.sql') -match 'GRANT OGG_CAPTURE TO ggadmin') 'source: OGG_CAPTURE'
    Assert-True ((Get-SqlText '04_tgt_users_pdb.sql') -match 'GRANT CONNECT, RESOURCE, OGG_APPLY TO ggadmin') 'target: OGG_APPLY'
    $c = Get-SqlText '10_compare.sql'
    foreach ($w in 'COMPARE', 'ORA_HASH', 'hr.departments', 'hr.employees', 'sales.customers', 'sales.orders', 'sales.load_events', 'sales.types26') {
        Assert-True ($c.Contains($w)) "10_compare.sql lacks $w"
    }
}
function Test-OggconfDryRun {
    $order = [ordered]@{
        oggconf  = @('[ggrac1] bash /root/lab/rac/88_oggconf_source.sh', '[ggtgt] bash /root/lab/tgt/88_oggconf_target.sh')
        validate = @('[ggrac1] bash /root/lab/rac/90_validate.sh grid db acfs ogg repl', '[ggtgt] bash /root/lab/tgt/90_validate.sh db ogg repl',
                     '[ggrac1] bash /root/lab/shared/loadgen.sh 10 60', '[ggrac1] bash /root/lab/shared/compare.sh', '[ggtgt] bash /root/lab/shared/compare.sh')
    }
    foreach ($verb in $order.Keys) {
        $out = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') $verb -DryRun 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE "lab.ps1 $verb -DryRun exit: $out"
        $pos = -1
        foreach ($line in $order[$verb]) {
            $i = $out.IndexOf("DRYRUN $line")
            Assert-True ($i -gt $pos) "$verb -DryRun: '$line' missing or out of order"
            $pos = $i
        }
    }
    $s = Get-Content -Raw (Join-Path $Repo 'guest\lib.sh')
    Assert-True ($s.Contains('adminclient_run()')) 'lib.sh adminclient_run'
    Assert-True ($s -match "printf 'CONNECT %s DEPLOYMENT %s AS %s PASSWORD %s\\n'") 'CONNECT password goes into the adminclient pipe (printf builtin)'
}
function Test-AllDryRun {
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') all -DryRun 2>&1 | Out-String
    Assert-Equal 0 $LASTEXITCODE "lab.ps1 all -DryRun exit: $out"
    # build: a new VM shows 'DRYRUN New-LabVm', an existing one 'SKIP VM exists' (test runs on a built host too)
    Assert-True ($out -match 'DRYRUN New-LabVm gginfra|SKIP VM exists: gginfra') 'all -DryRun: build handles gginfra'
    $pos = -1
    foreach ($line in '[gginfra] bash /root/lab/infra/10_dnsmasq.sh', '[ggrac1] bash /root/lab/rac/40_install_grid.sh install',
                      '[ggrac1] bash /root/lab/rac/60_create_db.sh', '[ggtgt] bash /root/lab/tgt/60_create_db.sh', '[ggrac1] bash /root/lab/rac/70_acfs.sh create',
                      '[ggrac1] bash /root/lab/rac/87_xag_register.sh add', '[ggtgt] bash /root/lab/tgt/88_oggconf_target.sh', '[ggtgt] bash /root/lab/shared/compare.sh') {
        $i = $out.IndexOf("DRYRUN $line")
        Assert-True ($i -gt $pos) "all -DryRun: '$line' missing or out of order"
        $pos = $i
    }
    Assert-True ($out -notmatch '== VALID') 'a dry run never reports VALID'
}
function Test-CompareParse {
    Import-Module (Join-Path $Repo 'host\Guest.psm1') -Force -DisableNameChecking
    $src = @('noise', 'COMPARE HR.EMPLOYEES 20 123', 'COMPARE SALES.LOAD_EVENTS 600 999')
    $tgt = @('COMPARE HR.EMPLOYEES 20 123', 'COMPARE SALES.LOAD_EVENTS 598 777')
    $r = @(Compare-CompareLines -Source $src -Target $tgt)
    Assert-Equal 2 $r.Count 'two tables'
    Assert-True (($r | Where-Object Table -eq 'HR.EMPLOYEES').Match) 'equal table matches'
    $l = $r | Where-Object Table -eq 'SALES.LOAD_EVENTS'
    Assert-True (-not $l.Match) 'different count/hash does not match'
    Assert-Equal 2 $l.Missing 'rows missing on the target'
    Assert-Equal '999' $l.SourceHash 'the source checksum goes to compare.json'
    Assert-Equal '777' $l.TargetHash 'the target checksum goes to compare.json'
    $h = @(Compare-CompareLines -Source @('COMPARE X 5 1') -Target @('COMPARE X 5 2'))[0]
    Assert-True (-not $h.Match) 'same row count, different checksum: no match'
}

# ------------------------------------------------------------------------------
# Task 9 (part without KB101098: the A/B switch)
# ------------------------------------------------------------------------------
function Test-MaaVariantSwitch {
    $a = Get-TestGuestVars 'ggrac1'
    $b = Get-TestGuestVars 'ggrac1' (New-TempConfig @{ "HaStage      = 'A'" = "HaStage      = 'B'" })
    Assert-Equal 'B' $b.OGG_HA_STAGE 'temp config switched to stage B'
    Assert-True ($a.OGG_AGCTL_ARGS -match '--filesystems ora\.data\.oggvol\.acfs ') 'stage A: ACFS only'
    Assert-True ($b.OGG_AGCTL_ARGS -match '--filesystems ora\.data\.oggvol\.acfs,nginx ') 'stage B: XAG also waits for the nginx resource'
    Assert-Equal 'oggvip.gg.lab.test' $a.OGG_SM_HOST 'stage A: Service Manager on the VIP name'
    Assert-Equal '127.0.0.1' $b.OGG_SM_HOST 'stage B (MAA): Service Manager on 127.0.0.1 behind NGINX'
    Assert-Equal 'ws' $a.OGG_PATH_PROTO 'stage A path ws://'
    Assert-Equal 'wss' $b.OGG_PATH_PROTO 'stage B path wss://'
    Assert-Equal 'https://oggvip.gg.lab.test:443' $b.OGG_SRC_URL 'stage B adminclient through NGINX'
}

# ------------------------------------------------------------------------------
# Task 10
# ------------------------------------------------------------------------------
# One block per test: "### T<n> — title"; fields "- **<label>:**" in a fixed order.
function Get-TestSpecBlocks([string]$File) {
    $t = [IO.File]::ReadAllText((Join-Path $Repo $File))
    $h = [ordered]@{}
    foreach ($m in [regex]::Matches($t, '(?ms)^### (T\d+)\b(.*?)(?=^### T\d+\b|^## |\z)')) { $h[$m.Groups[1].Value] = $m.Value }
    $h
}
function Test-TestsSpecComplete {
    $fields = @{
        'TESTS.md'    = @('Start', 'Fault', 'By hand', 'Measured', 'Pass', 'Back to base', 'Risks', 'Run it')
        'TESTS_PL.md' = @('Start', 'Awaria', 'Ręcznie', 'Mierzymy', 'Zaliczenie', 'Powrót do bazy', 'Ryzyka', 'Uruchomienie')
    }
    $ids = @{}
    foreach ($f in $fields.Keys) {
        $b = Get-TestSpecBlocks $f
        Assert-Equal 'T1 T2 T3 T4 T5 T6 T7 T8 T9 T10' (@($b.Keys) -join ' ') "$f test ids"
        foreach ($id in $b.Keys) {
            $pos = -1
            # T8-T10 inject no fault: only start, pass and how to run are required
            $labels = if ($id -in 'T8', 'T9', 'T10') { @($fields[$f][0], $fields[$f][-4], $fields[$f][-1]) } else { $fields[$f] }
            foreach ($label in $labels) {
                $i = $b[$id].IndexOf("- **${label}")
                Assert-True ($i -gt $pos) "${f} ${id}: field '$label' missing or out of order"
                $pos = $i
            }
        }
        foreach ($id in 'T6', 'T7') {
            Assert-True ($b[$id] -match '^### T\d+[^\r\n]*⚠️') "${f} ${id}: header marks the test as destructive"
        }
        $ids[$f] = @($b.Keys) -join ' '
    }
    $en = [IO.File]::ReadAllText((Join-Path $Repo 'TESTS.md'))
    foreach ($m in 't_fault', 't_crs_detect', 't_service_online', 't_acfs_online', 't_vip_online', 't_sm_running', 't_ext_running', 't_dp_running', 't_rep_running', 't_lag_ok') {
        Assert-True ($en.Contains($m)) "TESTS.md lacks marker $m"
    }
    Assert-True ($en.Contains('setlinkstate3')) 'T7 cuts NIC3 (intnet ggrac-ic)'
}
function Test-ReadmeThreePaths {
    foreach ($f in 'README.md', 'README_PL.md', 'DESIGN.md') { Assert-True (Test-Path (Join-Path $Repo $f)) "missing $f" }
    $en = [IO.File]::ReadAllText((Join-Path $Repo 'README.md'))
    $pl = [IO.File]::ReadAllText((Join-Path $Repo 'README_PL.md'))
    foreach ($w in 'lab.cmd all', 'Automatic', 'Step by step', 'Manual', 'docs/INSTALL_AUTO.md', 'docs/INSTALL_STEPWISE.md', 'docs/MANUAL.md', 'TESTS.md', 'README_PL.md') { Assert-True ($en.Contains($w)) "README.md lacks $w" }
    foreach ($w in 'lab.cmd all', 'Automatyczna', 'Krok po kroku', 'Ręczna', 'docs/INSTALL_AUTO_PL.md', 'docs/INSTALL_STEPWISE_PL.md', 'docs/MANUAL_PL.md', 'TESTS_PL.md', 'README.md') { Assert-True ($pl.Contains($w)) "README_PL.md lacks $w" }
    # The step-by-step guide lists every guest script in run order with its node
    $sen = [IO.File]::ReadAllText((Join-Path $Repo 'docs/INSTALL_STEPWISE.md'))
    $spl = [IO.File]::ReadAllText((Join-Path $Repo 'docs/INSTALL_STEPWISE_PL.md'))
    foreach ($s in 'infra/10_dnsmasq.sh', 'rac/40_install_grid.sh', 'rac/60_create_db.sh', 'tgt/60_create_db.sh', 'rac/70_acfs.sh', 'rac/87_xag_register.sh', 'tgt/88_oggconf_target.sh') {
        Assert-True ($sen.Contains($s) -and $spl.Contains($s)) "INSTALL_STEPWISE lacks $s"
    }
    foreach ($x in @($en, $pl)) { Assert-True ($x -notmatch '(?i)C:\\Users\\') 'no local user paths in the public README' }
}

# ------------------------------------------------------------------------------
# Task 11
# ------------------------------------------------------------------------------
function Import-HarnessModules {
    Import-LabModules
    foreach ($m in 'Guest', 'Evidence', 'Tests') { Import-Module (Join-Path $Repo "host\$m.psm1") -Force -DisableNameChecking }
}
function Test-SummaryFromEvents {
    Import-HarnessModules
    $dir = Join-Path $Repo 'results\sample\T2-sample'
    $ev = @(Import-Csv (Join-Path $dir 'events.csv'))
    $lag = @(Import-Csv (Join-Path $dir 'lag.csv'))
    $m = Get-Markers -Events $ev -Lag $lag -LagOkSec 30
    Assert-Equal 0 $m.t_fault 't_fault = 0 (relative)'
    Assert-Equal 31.5 $m.t_crs_detect 't_crs_detect = node left the cluster'
    foreach ($kv in @{ t_service_online = 40.25; t_acfs_online = 46; t_vip_online = 48.5; t_sm_running = 65; t_ext_running = 80; t_dp_running = 84; t_rep_running = 90; t_lag_ok = 105 }.GetEnumerator()) {
        Assert-Equal $kv.Value $m[$kv.Key] $kv.Key
    }
    $s = Get-RunSummary -Markers $m -TestId 'T2' -RunNo 1 -Lag $lag -LagOkSec 30
    Assert-Equal 90 $s.rto_s 'RTO = t_rep_running - t_fault'
    Assert-Equal 'rep_running' $s.rto_basis 'REP1 had an outage, so RTO is measured to its restart'
    Assert-Equal 88 $s.lag_max_s 'max lag'
    Assert-Equal 16.5 ($s.segments | Where-Object name -eq 'vip_to_sm').seconds 'segment VIP -> Service Manager'
    Assert-Equal 9 @($s.segments).Count 'nine segments from fault to lag OK'
    $j = Get-Content -Raw (Join-Path $dir 'summary.json') | ConvertFrom-Json
    Assert-True ($j.synthetic -eq $true) 'sample summary is marked synthetic'
    Assert-Equal 90 $j.rto_s 'committed sample summary matches the computation'
}
function Test-StateChangesOnly {
    Import-HarnessModules
    $t0 = [datetime]::Parse('2026-11-20T10:00:00Z').ToUniversalTime()
    $samples = @(
        [pscustomobject]@{ Ts = $t0;                 Resource = 'svc'; Node = 'ggrac1'; State = 'ONLINE'; Source = 'crsctl'; Raw = 'a' }
        [pscustomobject]@{ Ts = $t0.AddSeconds(1);   Resource = 'svc'; Node = 'ggrac1'; State = 'ONLINE'; Source = 'crsctl'; Raw = 'b' }
        [pscustomobject]@{ Ts = $t0.AddSeconds(2);   Resource = 'svc'; Node = 'ggrac2'; State = 'ONLINE'; Source = 'crsctl'; Raw = 'c' }
        [pscustomobject]@{ Ts = $t0.AddSeconds(3);   Resource = 'svc'; Node = 'ggrac2'; State = 'ONLINE'; Source = 'crsctl'; Raw = 'd' }
    )
    $e = @(Get-StateChanges -Samples $samples -FaultUtc $t0.AddSeconds(1) -TestId 'T1' -RunNo 1)
    Assert-Equal 2 $e.Count 'first state + one change (node moved), repeats dropped'
    Assert-Equal 'ggrac2' $e[1].node 'change recorded on the new node'
    Assert-Equal '1.000' $e[1].t_rel_s 't_rel_s relative to the fault, 3 decimals'
    Assert-Equal '2026-11-20T10:00:02.000Z' $e[1].ts_utc 'UTC ISO 8601 with milliseconds'
    $st = Get-SampleIntervalStats -Times @($t0, $t0.AddSeconds(1), $t0.AddSeconds(2.5))
    Assert-Equal 1.25 $st.median_s 'measured interval median'
    Assert-Equal 1.5 $st.max_s 'measured interval max'
}
function Test-AssertBaselineRejects {
    Import-HarnessModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $good = @{ GgNode = 'ggrac1'; ServiceNode = 'ggrac1'; AcfsNode = 'ggrac1'; VipNode = 'ggrac1'; Nodes = @{ ggrac1 = 'Active'; ggrac2 = 'Active' }
               Processes = @{ EXT1 = 'RUNNING'; DP1 = 'RUNNING'; REP1 = 'RUNNING' }; LagSec = 4; Instances = @{ ggcdb1 = 'ONLINE'; ggcdb2 = 'ONLINE' } }
    Assert-Equal 0 @(Test-BaselineState -State $good -Config $c).Count 'base state accepted'
    $bad = $good.Clone(); $bad.GgNode = 'ggrac2'; $bad.Processes = @{ EXT1 = 'ABENDED'; DP1 = 'RUNNING'; REP1 = 'RUNNING' }; $bad.LagSec = 95
    $dev = @(Test-BaselineState -State $bad -Config $c)
    Assert-True (($dev -join ' ') -match 'ggrac2') 'deviation names the node GoldenGate runs on'
    Assert-True (($dev -join ' ') -match 'EXT1.*ABENDED') 'deviation names the abended process'
    Assert-True (($dev -join ' ') -match 'lag') 'deviation names the lag'
    $threw = $false
    try { Assert-Baseline -State $bad -Config $c } catch { $threw = $_.Exception.Message -match 'not in the base state' }
    Assert-True $threw 'Assert-Baseline throws with the reasons'
}
function Test-FaultCommandsRender {
    Import-HarnessModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $t2 = Get-FaultCommand -Kind poweroff -Target ggrac1 -Config $c
    Assert-Equal 'host' $t2.Where 'power-off runs on the host'
    Assert-Equal 'VBoxManage controlvm ggrac1 poweroff' $t2.Display 'T2 command'
    $t7 = Get-FaultCommand -Kind link-down -Target ggrac2 -Config $c
    Assert-Equal 'VBoxManage controlvm ggrac2 setlinkstate3 off' $t7.Display 'T7 cuts NIC3 (intnet ggrac-ic)'
    $t4 = Get-FaultCommand -Kind abort -Target ggcdb1 -Config $c
    Assert-Equal 'ggrac1' $t4.Node 'instance abort runs on a RAC node'
    # 16.11: srvctl stop -stopoption abort refused (CRS-2974, service gg_srcpdb needs -force); Kris: a real crash, kill -9 of PMON
    Assert-True ($t4.Command -match "pgrep -f '\[o\]ra_pmon_ggcdb1'" -and $t4.Command -match '\[ -n "\$p" \]' -and $t4.Command -match 'kill -9 \$p') "T4 kills PMON of ggcdb1 (got: $($t4.Command))"
    Assert-True ($t4.Command -notmatch 'srvctl') 'T4 is no planned srvctl stop'
    $t1 = Get-FaultCommand -Kind relocate -Target ggrac2 -Config $c
    Assert-True ($t1.Display -match '^/u01/app/xag/bin/agctl relocate goldengate oggsource --node ggrac2$') 'T1 command'
    $t5 = Get-FaultCommand -Kind kill-sm -Target ggrac1 -Config $c
    Assert-True ($t5.Display -match 'kill -9') 'T5 kills the Service Manager'
    foreach ($k in 'poweroff', 'link-down') { Assert-True (Get-FaultCommand -Kind $k -Target ggrac1 -Config $c).NeedsApproval "$k needs approval (A1)" }
}
function Test-MaskTranscript {
    Import-HarnessModules
    $m = Protect-Text -Text 'pw=Secret_99 at C:\Users\someone\lab and /home/oracle' -Secrets @('Secret_99')
    Assert-True ($m -notmatch 'Secret_99') 'password masked'
    Assert-True ($m -notmatch 'C:\\Users\\someone') 'user path masked'
    Assert-True ($m -match '/home/oracle') 'lab paths stay'
}
function Test-SummaryAllStats {
    Import-HarnessModules
    $runs = @(
        [pscustomobject]@{ test_id = 'T2'; run_no = 1; rto_s = 90; lag_max_s = 88; pass = $true }
        [pscustomobject]@{ test_id = 'T2'; run_no = 2; rto_s = 70; lag_max_s = 60; pass = $true }
        [pscustomobject]@{ test_id = 'T2'; run_no = 3; rto_s = 110; lag_max_s = 95; pass = $false }
    )
    $a = @(Get-SummaryAll -Runs $runs)
    Assert-Equal 1 $a.Count 'one row per test'
    Assert-Equal 90 $a[0].rto_median_s 'median'
    Assert-Equal 70 $a[0].rto_min_s 'min'
    Assert-Equal 110 $a[0].rto_max_s 'max'
    Assert-Equal 3 $a[0].runs 'failed runs count too (D4)'
    Assert-Equal 2 $a[0].passed 'passed runs'
}
# Video requirements (16.11): A4 expectation written before the fault + expected_match, A5 session name per run,
# A6 agent_notes.md per run, lab.cmd baseline after every run with its duration, journal for Kris after every run.
function Test-FilmRequirements {
    Import-HarnessModules
    foreach ($f in @(Get-ChildItem (Join-Path $Repo 'tests\cases') -Filter 'T*.ps1')) {
        $d = & $f.FullName
        Assert-True ($d.ContainsKey('Expected')) "$($f.Name) lacks Expected (A4)"
        foreach ($k in 'Hypothesis', 'Source', 'FinalNode', 'Recovers', 'RtoS', 'DataLoss') { Assert-True ($d.Expected.ContainsKey($k)) "$($f.Name) Expected lacks $k" }
    }
    $e = @{ FinalNode = 'ggrac2'; Recovers = $true; RtoS = 'nie wiemy'; DataLoss = 0 }
    $m = Get-ExpectedMatch -Expected $e -Actual @{ FinalNode = 'ggrac2'; Recovered = $true; DataOk = $true; RtoS = 75 }
    Assert-True ($m.match -eq $true) 'expected node, recovery and no loss: match'
    $m = Get-ExpectedMatch -Expected $e -Actual @{ FinalNode = 'ggrac1'; Recovered = $true; DataOk = $true; RtoS = 75 }
    Assert-True ($m.match -eq $false) 'other final node: no match'
    Assert-True (@($m.checks | Where-Object { $_.field -eq 'final_node' -and -not $_.match }).Count -eq 1) 'the mismatching field is named'
    $m = Get-ExpectedMatch -Expected @{ FinalNode = 'nie wiemy'; Recovers = 'nie wiemy'; RtoS = 'nie wiemy'; DataLoss = 'nie wiemy' } -Actual @{ FinalNode = 'ggrac1'; Recovered = $false; DataOk = $true; RtoS = $null }
    Assert-True ($null -eq $m.match) '"nie wiemy" everywhere: nothing to compare, match is null'
    $tmp = New-TestDir
    [IO.File]::WriteAllText((Join-Path $tmp 'agent_notes.md'), "## Interwencje ręczne`n- ✋ srvctl start instance ggcdb1 · instancja nie wstała`n- ✋ restart OBS`n")
    Assert-Equal 2 (Get-InterventionCount -Path (Join-Path $tmp 'agent_notes.md')) 'two interventions'
    Assert-Equal 0 (Get-InterventionCount -Path (Join-Path $tmp 'missing.md')) 'no notes file: 0'
    $run = Join-Path $tmp 'T2-20261117-080000'; New-Item -ItemType Directory -Path $run | Out-Null
    [IO.File]::WriteAllText((Join-Path $run 'summary.json'), (@{ test_id = 'T2'; run_no = 1; pass = $true; refused = $false; rto_s = 81.5; expected_match = $true
        final_node = 'ggrac2'; data_ok = $true; back_to_base_s = 410; session = 'test-session'; notes = @() } | ConvertTo-Json))
    Copy-Item (Join-Path $tmp 'agent_notes.md') $run
    Write-TestJournal -Root $tmp
    $j = [IO.File]::ReadAllText((Join-Path $tmp 'DZIENNIK_TESTOW.md'))
    Assert-True ($j -match '\| T2 \| 1 \| ✅') 'journal row: test, run, passed'
    Assert-True ($j.Contains('81.5') -and $j.Contains('ggrac2') -and $j.Contains('410')) 'journal row: RTO, final node, back to base'
    Assert-True ($j -match '\| 2 \|') 'journal row: interventions from agent_notes.md'
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'tests\run_test.ps1') -Test T2 -DryRun -ApprovedBy Kris -Session test-session 2>&1 | Out-String
    foreach ($w in 'DRYRUN expected (A4)', 'DRYRUN agent_notes.md (A6)', 'session=test-session', 'DRYRUN after the run: lab.cmd baseline', 'DZIENNIK_TESTOW.md') {
        Assert-True ($out.Contains($w)) "run_test -DryRun lacks '$w'"
    }
    $rt = [IO.File]::ReadAllText((Join-Path $Repo 'tests\run_test.ps1'))
    $iExp = $rt.IndexOf("'expected.json'"); $iFault = $rt.IndexOf('# Fault: t_fault')
    Assert-True ($iExp -gt 0 -and $iExp -lt $iFault) 'expected.json is written before the fault (A4)'
    Assert-True ($rt.Contains('Write-TestJournal')) 'run_test refreshes the journal after every run'
}
# First live run 16.11 (found by the test session): Sh ended with ", $out", so @(Sh ...) + @(Sh ...) gave 2 arrays
# instead of the lines; Assert-Baseline saw nothing and refused T8 in the base state. Real functions, stubbed ssh.
function Test-ShReturnsLines {
    $file = Join-Path $Repo 'tests\run_test.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    $defs = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Sh', 'Get-LiveRac', 'Get-ProbeOnce' }, $true) |
              ForEach-Object { $_.Extent.Text }) -join "`n"
    # The real Invoke-LabSsh (Tests.psm1); only the ssh client is replaced (a global function wins over ssh.exe)
    Import-HarnessModules
    $sb = [scriptblock]::Create(@'
param($defs)
function global:ssh { $global:LASTEXITCODE = 0; if ($args[-1] -eq 'true') { return }; 'TICK x'; "RES sm ggrac1 ONLINE"; "PROC EXT1 ggrac1 RUNNING" }
$script:CmdLog = [System.Collections.Generic.List[object]]::new()
$rac = @([pscustomobject]@{ Name = 'ggrac1'; PublicIp = '1' }); $tgt = [pscustomobject]@{ Name = 'ggtgt'; PublicIp = '2' }; $key = 'k'
. ([scriptblock]::Create($defs))
$p = @(Get-ProbeOnce)
"count=$($p.Count)"
"first=$($p[0].Line)"
'@)
    try { $out = @(& $sb $defs) } finally { Remove-Item Function:\global:ssh -ErrorAction Ignore }
    Assert-Equal 'count=6' ($out -match '^count=')[0] 'Get-ProbeOnce: one row per probe line from both nodes (not one per ssh call)'
    Assert-Equal 'first=TICK x' ($out -match '^first=')[0] 'each row carries one line'
}
function Test-RawLinesWhileSamplerWrites {
    # T8 run 2 (16.11): the wait loop read raw_crs.txt while tests/sampler.ps1 still held it open -> "being used by another process"
    Import-HarnessModules
    $f = Join-Path ([IO.Path]::GetTempPath()) "raw_$([guid]::NewGuid().ToString('N')).txt"
    $w = [IO.StreamWriter]::new($f, $true, [Text.UTF8Encoding]::new($false))   # the same open as tests/sampler.ps1
    try {
        $w.Write("2026-11-16T10:00:00.000Z`tggrac1`tRES sm ggrac1 ONLINE`n2026-11-16T10:00:01.000Z`tggrac1`tRES sm ggr"); $w.Flush()
        $r = @(Read-RawLines @($f))
        Assert-Equal 1 $r.Count 'Read-RawLines reads a file the sampler holds open; the unfinished last line is skipped'
        Assert-Equal 'RES sm ggrac1 ONLINE' $r[0].Line 'the complete line is read'
    } finally { $w.Dispose(); Remove-Item $f -ErrorAction Ignore }
}
function Test-MarkersNoIndexErrors {
    # T8 run 2: under StrictMode @(...)[0] on an empty array wrote 9 "Index was outside the bounds" errors in Get-Markers
    Import-HarnessModules
    $ev = @([pscustomobject]@{ t_rel_s = '0.000'; resource = 'fault'; node = '-'; state_from = ''; state_to = 'injected' })
    $errs = $null
    $m = Get-Markers -Events $ev -Lag @() -ErrorVariable errs
    $errs = @($errs | Where-Object { $_ })
    Assert-Equal 0 $errs.Count "Get-Markers with only the fault event: no errors ($($errs -join '; '))"
    Assert-Equal 0.0 $m.t_fault 't_fault is read'
    Assert-True ($null -eq $m.t_crs_detect) 'no detection without events'
}
function Test-ExpectedMatchWithoutCompare {
    # T8 run 2: compare.json was never written, yet data_loss said 'rows differ' and expected_match was false
    Import-HarnessModules
    $exp = [ordered]@{ FinalNode = 'ggrac1'; Recovers = 'nie dotyczy'; DataLoss = 0; RtoS = 'nie dotyczy' }
    $em = Get-ExpectedMatch -Expected $exp -Actual @{ FinalNode = 'ggrac1'; Recovered = $false; DataOk = $null; RtoS = $null }
    $d = @($em.checks | Where-Object field -eq 'data_loss')[0]
    Assert-Equal 'compare not run' $d.actual 'data_loss without a compare: "compare not run"'
    Assert-True ($null -eq $d.match) 'data_loss without a compare is not compared'
    Assert-Equal $true $em.match 'final_node matches, data not compared -> expected_match true'
    $em = Get-ExpectedMatch -Expected ([ordered]@{ FinalNode = 'nie wiemy'; Recovers = 'nie wiemy'; DataLoss = 0; RtoS = 'nie wiemy' }) -Actual @{ FinalNode = 'x'; Recovered = $false; DataOk = $null; RtoS = $null }
    Assert-True ($null -eq $em.match) 'only an uncompared check -> expected_match null'
    $rt = Get-Content -Raw (Join-Path $Repo 'tests\run_test.ps1')
    Assert-True ($rt -match 'data_checked') 'run_test.ps1 records data_checked in summary.json'
    $ev = Get-Content -Raw (Join-Path $Repo 'host\Evidence.psm1')
    Assert-True ($ev -match "nie sprawdzone") 'the journal shows "nie sprawdzone" when the data were not compared'
}
function Test-NoDeprecatedNoTypeInformation {
    # PS 7.7 warns that -NoTypeInformation is obsolete (noise in a recorded window); PS 7 omits the type line anyway
    foreach ($f in 'lab.ps1', 'host\Evidence.psm1', 'tests\run_test.ps1') {
        Assert-True (-not ((Get-Content -Raw (Join-Path $Repo $f)) -match 'NoTypeInformation')) "$f still uses -NoTypeInformation"
    }
}
function Test-LagFreshestPath {
    # T1 (16.11): after the relocate gg_lag keeps a row per path (DP host in its name); max() took the stale path,
    # its age grew without end (730 s) while the data matched; validate used max(incoming_lag) -> 4 s vs probe 93 s
    $want = 'keep (dense_rank first order by incoming_heartbeat_age nulls last)'
    foreach ($f in 'guest\shared\probe.sh', 'guest\tgt\90_validate.sh') {
        $t = [IO.File]::ReadAllText((Join-Path $Repo $f))
        Assert-True ($t.Contains("incoming_lag + nvl(incoming_heartbeat_age, 0)) $want")) "${f}: lag = lag + age of the freshest path"
        Assert-True (-not ($t -match 'max\(incoming_lag')) "${f}: no max() over every path"
    }
}
function Test-AcfsOnVipNode {
    # T1: ACFS stays ONLINE on the old node after the relocate; the probe showed the first ONLINE entry (ggrac1) -> no event
    $calls = @'
d=$(mktemp -d); G=$d; SVC_RES=svc; OGG_ACFS_RES=acfs; OGG_VIP_NAME=vip; XAG_RES=xag; DB_RES=db; RAC_NODES='ggrac1 ggrac2'; SRC_DB=ggcdb
sysdba_query() { cat > /dev/null; }
printf '#!/bin/bash\necho NAME=svc; echo STATE=ONLINE on ggrac2; echo NAME=acfs; echo "STATE=ONLINE on ggrac1, ONLINE on ggrac2"; echo NAME=vip; echo STATE=ONLINE on ggrac2\n' > $d/crsctl
printf '#!/bin/bash\n' > $d/olsnodes; chmod +x $d/crsctl $d/olsnodes
probe_crs | grep '^RES acfs'
printf '#!/bin/bash\necho NAME=acfs; echo "STATE=ONLINE on ggrac1, OFFLINE"; echo NAME=vip; echo STATE=OFFLINE\n' > $d/crsctl
probe_crs | grep '^RES acfs'
rm -rf $d
'@
    $out = @(Invoke-BashFunction 'guest\shared\probe.sh' @('state_of', 'acfs_state', 'probe_crs') $calls | Where-Object { $_ -like 'RES acfs*' })
    Assert-Equal 'RES acfs ggrac2 ONLINE|RES acfs ggrac1 ONLINE' ($out -join '|') 'ACFS on the VIP node wins; without the VIP the first ONLINE entry'
}
function Test-MarkersNodeChange {
    # T1: the service moved ONLINE -> ONLINE to another node; that is the marker too
    Import-HarnessModules
    $e = { param($rel, $res, $node, $from, $to) [pscustomobject]@{ t_rel_s = $rel; resource = $res; node = $node; state_from = $from; state_to = $to } }
    $ev = @((& $e '-5.000' 'svc' 'ggrac1' '' 'ONLINE'), (& $e '-5.000' 'acfs' 'ggrac1' '' 'ONLINE'), (& $e '0.000' 'fault' 'ggrac2' '' 'injected'),
            (& $e '1.768' 'svc' 'ggrac2' 'ONLINE' 'ONLINE'), (& $e '30.000' 'acfs' 'ggrac2' 'ONLINE' 'ONLINE'), (& $e '40.000' 'acfs' 'ggrac2' 'ONLINE' 'ONLINE'))
    $m = Get-Markers -Events $ev -Lag @()
    Assert-Equal 1.768 $m.t_service_online 'svc ONLINE -> ONLINE on a new node = t_service_online'
    Assert-Equal 30.0 $m.t_acfs_online 'acfs on a new node = t_acfs_online'
}
function Test-SegmentsOutOfOrder {
    # T1: DP1 RUNNING (32.5 s) before EXT1 RUNNING (43.4 s) gave segment ext_to_dp = -10.9 s
    Import-HarnessModules
    $mk = [ordered]@{ t_fault = 0.0; t_crs_detect = 12.4; t_service_online = $null; t_acfs_online = $null; t_vip_online = 26.6; t_sm_running = 35.9
                      t_ext_running = 43.4; t_dp_running = 32.5; t_rep_running = $null; t_lag_ok = $null }
    $s = Get-RunSummary -Markers $mk -TestId T1 -RunNo 1 -Lag @()
    Assert-True (-not @($s.segments | Where-Object { $_.seconds -lt 0 }).Count) 'no negative segment'
    Assert-Equal 'ext_to_dp' (@($s.segments_out_of_order) -join ',') 'the reversed pair is named in segments_out_of_order'
}
function Test-SegmentsMeasured {
    # 16.11: segments in the measured marker order, next to the fixed chain segments
    Import-HarnessModules
    $mk = [ordered]@{ t_fault = 0.0; t_crs_detect = 12.4; t_service_online = 1.8; t_acfs_online = 26.61; t_vip_online = 26.6; t_sm_running = 35.9
                      t_ext_running = 43.4; t_dp_running = 32.5; t_rep_running = $null; t_lag_ok = 54.3 }
    $s = Get-RunSummary -Markers $mk -TestId T1 -RunNo 1 -Lag @()
    $m = @($s.segments_measured)
    Assert-Equal 'fault_to_service_online,service_online_to_crs_detect,crs_detect_to_vip_online,vip_online_to_acfs_online,acfs_online_to_dp_running,dp_running_to_sm_running,sm_running_to_ext_running,ext_running_to_lag_ok' `
        (($m | ForEach-Object name) -join ',') 'measured order, null marker skipped'
    Assert-Equal 't_service_online' $m[1].from 'from marker'
    Assert-Equal 't_crs_detect' $m[1].to 'to marker'
    Assert-Equal 1.8 $m[1].from_t_rel_s 'from t_rel_s'
    Assert-Equal 12.4 $m[1].to_t_rel_s 'to t_rel_s'
    Assert-Equal 10.6 $m[1].seconds 'seconds'
    Assert-True (-not @($m | Where-Object { $_.seconds -lt 0 }).Count) 'no negative measured segment'
    Assert-Equal 'ext_to_dp' ((@($s.segments_out_of_order) | Where-Object { $_ -eq 'ext_to_dp' }) -join ',') 'segments_out_of_order kept'
}
function Test-T4bIntervention {
    # 16.11: T4 after the PMON kill leaves GoldenGate down (CRS-0222); T4b = same fault + agctl relocate after 120 s
    Import-HarnessModules
    $d = & (Join-Path $Repo 'tests\cases\T04b_instance_abort_relocate.ps1')
    Assert-Equal 'T4b' $d.Id 'T4b id'
    Assert-Equal 'abort' $d.Kind 'same fault as T4'
    Assert-Equal 'manual-relocate' $d.Variant 'variant name for the film'
    Assert-Equal 120 $d.Intervention.AfterSec 'intervention after 120 s'
    Assert-Equal 'ggrac2' $d.Intervention.Target 'relocate to ggrac2'
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'tests\run_test.ps1') -Test T4b -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 2 -and $out -match 'ApprovedBy') "a test with a manual intervention needs -ApprovedBy (got $LASTEXITCODE)"
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'tests\run_test.ps1') -Test T4b -DryRun -ApprovedBy Kris 2>&1 | Out-String
    Assert-Equal 0 $LASTEXITCODE "run_test T4b -DryRun exit: $out"
    Assert-True ($out.Contains('DRYRUN intervention at 120 s after the fault: agctl relocate|start goldengate oggsource --node ggrac2')) "dry run names the intervention: $out"
    # Kris 16.11 (recorded with OBS): the move waits for a live approval, file approve_intervention in the run directory
    Assert-True ($d.Intervention.LiveApproval -eq $true) 'T4b waits for a live approval'
    Assert-Equal 600 $d.Intervention.ApprovalTimeoutSec 'approval wait limit'
    Assert-True ($out.Contains('waits up to 600 s for <run dir>\approve_intervention')) "dry run names the approval file: $out"
    $tmp = New-TestDir
    try {
        Assert-True ($null -eq (Read-InterventionApproval -Path (Join-Path $tmp 'approve_intervention'))) 'no file: not approved'
        [IO.File]::WriteAllText((Join-Path $tmp 'approve_intervention'), "approved_by=Kris`n")
        Assert-Equal 'Kris' (Read-InterventionApproval -Path (Join-Path $tmp 'approve_intervention')) 'approved_by from the file'
        [IO.File]::WriteAllText((Join-Path $tmp 'approve_intervention'), '')
        Assert-Equal 'unknown' (Read-InterventionApproval -Path (Join-Path $tmp 'approve_intervention')) 'empty file still approves, approver unknown'
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
    # GoldenGate is down at 120 s: relocate only when running, else start; a refused start moves oggvip with -f first
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $g = Get-FaultCommand -Kind gg-move -Target ggrac2 -Config $c
    Assert-Equal 'ggrac2' $g.Node 'gg-move runs on the target node'
    Assert-True $g.NeedsApproval 'gg-move needs approval'
    foreach ($w in "/u01/app/xag/bin/agctl status goldengate oggsource | grep -q 'is running on'", 'agctl relocate goldengate oggsource --node ggrac2',
                   '/u01/app/xag/bin/agctl start goldengate oggsource --node ggrac2 && exit 0', '/u01/app/23.26/grid/bin/crsctl relocate resource oggvip -n ggrac2 -f') {
        Assert-True ($g.Command.Contains($w)) "gg-move command lacks '$w': $($g.Command)"
    }
    Assert-True ($out.Contains('[o]ra_pmon_ggcdb1')) 'dry run: fault is the PMON kill'
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'tests\run_test.ps1') -Test T4 -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and -not $out.Contains('DRYRUN intervention')) 'T4 itself has no intervention'
    # t_intervention takes part in segments_measured only; the fixed chain segments stay as they were
    $mk = [ordered]@{ t_fault = 0.0; t_crs_detect = 5.2; t_service_online = 5.2; t_acfs_online = 150.0; t_vip_online = 149.0; t_sm_running = 160.0
                      t_ext_running = 200.0; t_dp_running = 170.0; t_rep_running = $null; t_lag_ok = 260.0; t_intervention = 120.0 }
    $s = Get-RunSummary -Markers $mk -TestId T4b -RunNo 1 -Lag @()
    Assert-True (@($s.segments_measured | Where-Object name -eq 'intervention_to_vip_online').Count -eq 1) 'intervention_to_vip_online in segments_measured'
    Assert-True (-not @($s.segments | Where-Object name -like '*intervention*').Count) 'no intervention in the fixed segments'
    Assert-Equal 'Jak T4, a po 120 s ręcznie: GoldenGate przeniesiony na ggrac2 (agctl relocate albo start).' (ConvertTo-PolishNote $d.Notes) 'T4b note in Polish'
    $rt = Get-Content -Raw (Join-Path $Repo 'tests\run_test.ps1')
    foreach ($f in 'config_rev', 'harness_commit', 'observe_s', 'test_variant', 't_intervention', 't_intervention_ready', 'approval_wait_s',
                   'intervention_approved_by', 'INTERVENTION READY', 'intervention not approved',
                   # T4 16.11: ggcdb1 not restarted, compare.sh on ggrac1 failed and counted as "rows differ"
                   'foreach ($n in $rac) {', "if (@(`$o | Where-Object { `$_ -like 'COMPARE *' }).Count)", 'data: compare not run') { Assert-True ($rt -match [regex]::Escape($f)) "run_test writes $f" }
}
function Test-LagOkFirstStableReturn {
    # T3 16.11: lag 40 s at the detection, back below 30 s at 40.3 s, one late sample 34 s at 343.5 s;
    # the old rule (after the LAST high sample) gave t_lag_ok 344.6 and rto_s 344.6
    Import-HarnessModules
    $ev = @([pscustomobject]@{ t_rel_s = '0.000'; resource = 'fault'; node = 'ggrac2'; state_from = ''; state_to = 'injected' })
    $row = { param($t, $l) [pscustomobject]@{ t_rel_s = "$t"; lag_s = "$l" } }
    $lag = @((& $row 1 13), (& $row 31 40), (& $row 40.3 17), (& $row 100 20), (& $row 343.5 34), (& $row 344.6 25))
    $m = Get-Markers -Events $ev -Lag $lag -LagOkSec 30
    Assert-Equal 40.3 $m.t_lag_ok 't_lag_ok = first stable return below the threshold'
    $s = Get-RunSummary -Markers $m -TestId T3 -RunNo 1 -Lag $lag -LagOkSec 30
    Assert-Equal 1 $s.lag_relapses 'the late sample is a relapse, not the recovery'
    Assert-Equal 343.5 $s.lag_relapse_first_s 'first relapse time'
    # a dip inside the outage (T1-like) is no return: high again within LagStableSec
    $lag = @((& $row 10 35), (& $row 12 25), (& $row 14 40), (& $row 50 20), (& $row 60 15))
    $m = Get-Markers -Events $ev -Lag $lag -LagOkSec 30
    Assert-Equal 50 $m.t_lag_ok 'a short dip is no return'
    Assert-Equal 0 (Get-RunSummary -Markers $m -TestId T1 -RunNo 1 -Lag $lag -LagOkSec 30).lag_relapses 'no relapse'
}
function Test-JournalT4bAndAborted {
    # 16.11: T4b rows missing in DZIENNIK_TESTOW.md (filter '^T\d+'); an aborted run showed "niezaliczony · różnice"
    Import-HarnessModules
    $tmp = New-TestDir
    try {
        New-Item -ItemType Directory (Join-Path $tmp 'T4b-20261116-152230'), (Join-Path $tmp 'T4-20261116-135751') | Out-Null
        Write-LabJson (Join-Path $tmp 'T4b-20261116-152230\summary.json') ([ordered]@{ test_id = 'T4b'; run_no = 1; pass = $true; data_ok = $true; rto_s = 296.2; final_node = 'ggrac2' })
        Write-LabJson (Join-Path $tmp 'T4-20261116-135751\summary.json') ([ordered]@{ test_id = 'T4'; run_no = 2; phase = 'expected_before_fault' })
        Push-Location $tmp
        try { Write-TestJournal -Root '.' } finally { Pop-Location }
        $j = [IO.File]::ReadAllText((Join-Path $tmp 'DZIENNIK_TESTOW.md'))
        Assert-True ($j -match '\| T4b \| 1 \| ✅ zaliczony') "T4b row in the journal: $j"
        Assert-True ($j -match '\| T4 \| 2 \| ⛔ przerwany \|[^\n]*\| nie sprawdzone \|') "aborted run: przerwany, nie sprawdzone: $j"
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $g = (Get-FaultCommand -Kind gg-move -Target ggrac2 -Config $c).Command
    foreach ($b in 'relocate', 'start', 'vip+start') { Assert-True ($g.Contains("echo 'branch: $b'")) "gg-move tells its branch '$b'" }
}
function Test-JournalPolishNotes {
    # Kris 16.11: the column "Uwagi" in DZIENNIK_TESTOW.md in Polish
    Import-HarnessModules
    Assert-Equal 'brak powrotu w ciągu 600 s' (ConvertTo-PolishNote 'no recovery within 600 s') 'no recovery'
    Assert-Equal 'Obciążenie bazowe, 10 minut.' (ConvertTo-PolishNote 'Baseline under load, 10 minutes.') 'case note T8'
    Assert-Equal 'dane: różne tabele: SALES.ORDERS' (ConvertTo-PolishNote 'data: tables differ: SALES.ORDERS') 'data note'
    Assert-Equal 'błąd automatu: x' (ConvertTo-PolishNote 'run error: x') 'run error'
    Assert-Equal "błąd automatu: lab nie jest w stanie bazowym, test nie startuje: GgNode = '', w stanie bazowym ggrac1; brak EXT1; DP1 w stanie STOPPED; lag 93 s (próg 30 s)" `
        (ConvertTo-PolishNote "run error: lab is not in the base state, the test does not start: GgNode is '', base state is ggrac1; EXT1 is missing; DP1 is STOPPED; lag is 93 s (threshold 30 s)") 'base state deviations'
    foreach ($f in Get-ChildItem (Join-Path $Repo 'tests\cases') -Filter 'T*.ps1') {
        $n = (& $f.FullName).Notes
        Assert-True ((ConvertTo-PolishNote $n) -ne $n) "$($f.Name): case note has a Polish text for the journal"
    }
    Assert-True ((Get-Content -Raw (Join-Path $Repo 'host\Evidence.psm1')) -match 'ConvertTo-PolishNote \$_') 'Write-TestJournal uses ConvertTo-PolishNote'
}
function Test-CasesAndRunner {
    $cases = @(Get-ChildItem (Join-Path $Repo 'tests\cases') -Filter 'T*.ps1')
    Assert-Equal 11 $cases.Count 'eleven test cases (T1-T10 + T4b)'
    foreach ($f in $cases) {
        $d = & $f.FullName
        foreach ($k in 'Id', 'Title', 'Kind', 'Target', 'Destructive', 'Back', 'PreSec', 'PostSec', 'TimeoutSec') {
            Assert-True ($d.ContainsKey($k)) "$($f.Name) lacks $k"
        }
    }
    $t7 = & (Join-Path $Repo 'tests\cases\T07_interconnect.ps1')
    Assert-True ($t7.Destructive) 'T7 destructive'
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'tests\run_test.ps1') -Test T2 -DryRun 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -ne 0 -and $out -match 'ApprovedBy') 'a power-off test refuses to run without -ApprovedBy (A1)'
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'tests\run_test.ps1') -Test T2 -DryRun -ApprovedBy Kris 2>&1 | Out-String
    Assert-Equal 0 $LASTEXITCODE "run_test -DryRun exit: $out"
    foreach ($w in 'DRYRUN fault host: VBoxManage controlvm ggrac1 poweroff', 'DRYRUN baseline', 'DRYRUN compare', 'DRYRUN results/T2-') {
        Assert-True ($out.Contains($w)) "run_test -DryRun lacks '$w'"
    }
}

# ------------------------------------------------------------------------------
# Final review fixes (15.11)
# ------------------------------------------------------------------------------
# Cuts one bash function out of a guest script and runs it in Git Bash with the given calls
function Invoke-BashFunction([string]$File, [string[]]$Functions, [string]$Calls) {
    $lines = [IO.File]::ReadAllLines((Join-Path $Repo $File))
    $defs = foreach ($fn in $Functions) {
        $i = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match "^$([regex]::Escape($fn))\(\)\s+\{" })
        Assert-True ($i -ge 0) "$File has no function $fn"
        if ($lines[$i] -match '\}\s*$') { $lines[$i] }
        else { $j = $i; while ($lines[$j] -ne '}') { $j++ }; $lines[$i..$j] -join "`n" }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gglab-fn-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sh')
    [IO.File]::WriteAllText($tmp, (($defs -join "`n") + "`n" + $Calls + "`n").Replace("`r", ''))
    try { @(& (Get-BashExe) $tmp 2>&1 | ForEach-Object { "$_" }) } finally { Remove-Item $tmp -Force }
}
# Critical 1: a filesystem resource has one STATE entry per node ("ONLINE on ggrac1, OFFLINE")
function Test-ProbeStateMultiEntry {
    $cases = [ordered]@{
        'ONLINE on ggrac1, OFFLINE' = 'ggrac1 ONLINE'; 'OFFLINE, ONLINE on ggrac2' = 'ggrac2 ONLINE'; 'ONLINE on ggrac1' = 'ggrac1 ONLINE'
        'INTERMEDIATE on ggrac2' = 'ggrac2 INTERMEDIATE'; 'OFFLINE, OFFLINE' = '- OFFLINE'; 'OFFLINE' = '- OFFLINE'; '' = '- UNKNOWN'
    }
    $calls = ($cases.Keys | ForEach-Object { "state_of '$_'" }) -join "`n"
    $out = Invoke-BashFunction 'guest\shared\probe.sh' @('state_of') $calls
    $i = 0
    foreach ($k in $cases.Keys) { Assert-Equal $cases[$k] $out[$i] "state_of '$k'"; $i++ }
}
# Important 5 (film E5): GG processes carry the node XAG runs the deployment on, not the sampler's node
function Test-ProbeGgNodeFromXag {
    $calls = @'
G=$(mktemp -d); XAG_RES=xag.oggsource.goldengate; NODE_NAME=ggrac1; OGG_PATH=DP1
adminclient_run() { printf 'Program  Status  Group\nExtract  RUNNING  EXT1  00:00:00\nPath Name DP1 Status Running\n'; }
printf '#!/bin/bash\necho NAME=xag.oggsource.goldengate\necho "STATE=$STATE"\n' > "$G/crsctl"; chmod +x "$G/crsctl"
export STATE='ONLINE on ggrac2'; probe_gg src
export STATE='OFFLINE'; probe_gg src
'@
    $out = @(Invoke-BashFunction 'guest\shared\probe.sh' @('state_of', 'xag_node', 'probe_gg') $calls)
    Assert-Equal 'PROC EXT1 ggrac2 RUNNING' $out[0] 'EXT1 on the node XAG runs it on (sampler is on ggrac1)'
    Assert-Equal 'PROC DP1 ggrac2 RUNNING' $out[1] 'DP1 on the XAG node'
    Assert-Equal 'PROC EXT1 - RUNNING' $out[2] 'XAG not ONLINE anywhere: node unknown, never the sampler node'
}
# New in the final pass: every command run_test.ps1 calls resolves after its own imports
# (Invoke-VBox lives in VmBuilder.psm1: without it T2/T3/T7 never inject the fault)
function Test-RunTestCommandsResolve {
    $file = Join-Path $Repo 'tests\run_test.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    $local = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
    $used = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } |
              Where-Object { $_ -and $_ -match '^[A-Z][a-z]+-[A-Za-z]+$' -and $_ -notin $local } | Sort-Object -Unique)
    $imports = @([IO.File]::ReadAllLines($file) | Where-Object { $_ -match 'Import-Module' })
    $probe = @("`$Repo = '$Repo'") + $imports + @("foreach (`$c in '$($used -join "','")') { if (-not (Get-Command `$c -ErrorAction SilentlyContinue)) { 'MISSING ' + `$c } }")
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gglab-rt-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    [IO.File]::WriteAllText($tmp, ($probe -join "`n"))
    try { $miss = @(& pwsh -NoProfile -File $tmp 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -like 'MISSING *' }) } finally { Remove-Item $tmp -Force }
    Assert-True (-not $miss) "run_test.ps1 calls commands its imports do not provide: $($miss -join ', ')"
}
# Critical 3: nothing from run N leaks into run N+1; a refused run injects no fault; exit code reports failures
function Test-RunTestRepeatIsolation {
    $file = Join-Path $Repo 'tests\run_test.ps1'
    $text = [IO.File]::ReadAllText($file)
    $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    $loop = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.ForStatementAst] }, $false) |
              Where-Object { $_.Body.Find({ $args[0] -is [Management.Automation.Language.TryStatementAst] }, $false) })[0]
    Assert-True ($null -ne $loop) 'run loop with try'
    $try = $loop.Body.Find({ $args[0] -is [Management.Automation.Language.TryStatementAst] }, $false)
    $before = @($loop.Body.Statements | Where-Object { $_.Extent.EndOffset -le $try.Extent.StartOffset })
    $vars = @($before | ForEach-Object { $_.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] }, $true) } |
              ForEach-Object { $_.Left.Extent.Text.TrimStart('$') })
    foreach ($v in 'tFault', 'recovered', 'dataOk', 'marks', 'offsets', 'refused', 'cmp', 'base') {
        Assert-True ($v -in $vars) "run loop must reset `$$v before try (got: $($vars -join ', '))"
    }
    foreach ($c in $try.CatchClauses) { Assert-True ($c.Extent.Text -notmatch 'Get-Variable') 'catch must not reuse values from an earlier run' }
    Assert-True ($text -match '\$faultEv = @\(if \(-not \$refused\)') 'a refused run writes no fault event'
    Assert-True ($text -match 'refused = \$refused') 'summary records refused'
    # 16.11: lab.cmd baseline after every run replaces the -Back sub-run between repeats (also T3/T4, powered-off VMs, cut link)
    Assert-True ($text -match "lab\.ps1'\) baseline" -and $text -match 'STOP: lab\.cmd baseline failed') 'between repeats the lab goes back to the base state (lab.cmd baseline), a failed return stops the series'
    $last = $ast.EndBlock.Statements[-1]
    Assert-True ($last -is [Management.Automation.Language.ExitStatementAst] -and $last.Pipeline.Extent.Text -match 'failed') 'run_test exits non-zero when a run failed'
}
# Important 6: recovery needs a real disturbance first, the whole chain on one node, and the expected GG node
function Test-RecoveryNeedsChange {
    Import-HarnessModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $mk = { param($n, $svc) @{ GgNode = $n; ServiceNode = $(if ($svc) { $svc } else { $n }); AcfsNode = $n; VipNode = $n; Nodes = @{ ggrac1 = 'Active'; ggrac2 = 'Active' }
            Processes = @{ EXT1 = 'RUNNING'; DP1 = 'RUNNING'; REP1 = 'RUNNING' }; LagSec = 3; Instances = @{ ggcdb1 = 'ONLINE'; ggcdb2 = 'ONLINE' } } }
    $base = & $mk 'ggrac1'
    Assert-True (-not (Test-Recovered -State (& $mk 'ggrac1') -Disturbed $false -LagOkSec 30)) 'no disturbance seen yet: not recovered'
    Assert-True (Test-Recovered -State (& $mk 'ggrac1') -Disturbed $true -LagOkSec 30) 'disturbed, chain together, lag OK: recovered'
    Assert-True (-not (Test-Recovered -State (& $mk 'ggrac1' 'ggrac2') -Disturbed $true -LagOkSec 30)) 'service on ggrac2, GG on ggrac1: chain split'
    $noAcfs = & $mk 'ggrac1'; $noAcfs.AcfsNode = '-'
    Assert-True (-not (Test-Recovered -State $noAcfs -Disturbed $true -LagOkSec 30)) 'ACFS not ONLINE: not recovered'
    Assert-True (-not (Test-Recovered -State (& $mk 'ggrac1') -Disturbed $true -ExpectGgNode 'ggrac2' -LagOkSec 30)) 'GG expected on ggrac2'
    Assert-True (Test-Recovered -State (& $mk 'ggrac2') -Disturbed $true -ExpectGgNode 'ggrac2' -LagOkSec 30) 'GG moved as expected'
    Assert-Equal 'ggrac2' (Get-ExpectedGgNode -Kind relocate -Target ggrac2 -Base $base -Config $c) 'T1: GG goes to the target'
    Assert-Equal 'ggrac2' (Get-ExpectedGgNode -Kind poweroff -Target ggrac1 -Base $base -Config $c) 'T2: GG leaves the dead node'
    Assert-Equal $null (Get-ExpectedGgNode -Kind poweroff -Target ggrac2 -Base $base -Config $c) 'T3: no expectation'
    $t0 = [datetime]::UtcNow
    $same = @([pscustomobject]@{ Ts = $t0; Resource = 'sm'; Node = 'ggrac1'; State = 'ONLINE' }, [pscustomobject]@{ Ts = $t0; Resource = 'EXT1'; Node = 'ggrac1'; State = 'RUNNING' })
    Assert-True (-not (Test-Disturbed -Samples $same -Base $base)) 'samples equal to the base state: no disturbance'
    foreach ($s in @(@{ Resource = 'sm'; Node = 'ggrac1'; State = 'OFFLINE' }, @{ Resource = 'inst:ggcdb2'; Node = 'ggrac2'; State = 'OFFLINE' },
                      @{ Resource = 'EXT1'; Node = 'ggrac1'; State = 'ABENDED' }, @{ Resource = 'svc'; Node = 'ggrac2'; State = 'ONLINE' }, @{ Resource = 'node:ggrac2'; Node = 'ggrac2'; State = 'Inactive' })) {
        Assert-True (Test-Disturbed -Samples @($same + [pscustomobject]($s + @{ Ts = $t0 })) -Base $base) "disturbance: $($s.Resource) $($s.State)"
    }
}
# Important 7: -Back brings powered-off nodes and cut links back, then relocates GG and the service (measured)
function Test-BackPlan {
    Import-HarnessModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $moved = @{ GgNode = 'ggrac2'; ServiceNode = 'ggrac2'; AcfsNode = 'ggrac2'; VipNode = 'ggrac2' }
    $p = Get-BackPlan -State $moved -Config $c -VmStates @{ ggrac1 = 'poweroff'; ggrac2 = 'running' }
    $prep = @($p.Prep | ForEach-Object Display); $meas = @($p.Measured | ForEach-Object Display)
    Assert-True ('VBoxManage startvm ggrac1 --type headless' -in $prep) "powered-off node is started (got: $($prep -join ' | '))"
    Assert-True ('VBoxManage controlvm ggrac2 setlinkstate3 on' -in $prep) 'interconnect link back on for running nodes (after T7)'
    Assert-True (-not ($prep -match 'controlvm ggrac1 setlinkstate3')) 'no link change on a VM that is off'
    Assert-True (@($p.Prep | Where-Object Where -eq 'wait').Count -eq 1) 'one wait step: nodes Active, instances ONLINE'
    # Docs check 15.11: admin-managed service = -oldinst/-newinst (relocate), -instance (start); -currentnode/-targetnode
    # and -node are policy-managed only (desupported in 26ai). --use_local_services: GG must run where the service runs,
    # so the service goes first, then GG (LAB: both orders on the live lab)
    Assert-Equal 2 $meas.Count "measured: service then GG (got: $($meas -join ' | '))"
    Assert-True ($meas[0] -match 'srvctl relocate service -db ggcdb -service gg_srcpdb -oldinst ggcdb2 -newinst ggcdb1$') 'service back first (-failback NO)'
    Assert-True ($meas[1] -match 'agctl relocate goldengate oggsource --node ggrac1$') 'then GG to the service node'
    $down = Get-BackPlan -State @{ GgNode = '-'; ServiceNode = '-'; AcfsNode = '-'; VipNode = '-' } -Config $c -VmStates @{}
    $dm = @($down.Measured | ForEach-Object Display)
    Assert-True ($dm[0] -match 'srvctl start service -db ggcdb -service gg_srcpdb -instance ggcdb1$') "service down: start on the instance (got: $($dm -join ' | '))"
    Assert-True ($dm[1] -match 'agctl start goldengate oggsource --node ggrac1$') 'GG down: start on the first node'
    $atHome = @{ GgNode = 'ggrac1'; ServiceNode = 'ggrac1'; AcfsNode = 'ggrac1'; VipNode = 'ggrac1' }
    $p2 = Get-BackPlan -State $atHome -Config $c -VmStates @{ ggrac1 = 'running'; ggrac2 = 'running' }
    Assert-Equal 0 @($p2.Measured).Count 'already in the base state: nothing to relocate'
}
# Critical 2 + loadgen false pass: the load stops on the database side; a session that never ran fails
function Test-LoadgenStopAndCheck {
    $calls = @'
LAB_PASS=x; SCAN_NAME=scan; LAB_DOMAIN=d; rate=1; secs=1
runuser() { cat > /dev/null; echo "$FAKE"; }
FAKE='ORA-01017: invalid username/password; logon denied'; one_session srv_load1 > /dev/null; echo "rc=$?"
FAKE='SP2-0640: Not connected'; one_session srv_load1 > /dev/null; echo "rc=$?"
FAKE='loadgen: 600 rows, instance 1, service srv_load1'; one_session srv_load1 > /dev/null; echo "rc=$?"
FAKE='ORA-00028: your session has been killed'; one_session srv_load1 > /dev/null; echo "rc=$?"
STOP_MARK=$(mktemp -u); FAKE='ORA-03114: not connected to ORACLE'; one_session srv_load1 > /dev/null; echo "rc=$?"
touch "$STOP_MARK"; one_session srv_load1 | grep -c 'stopped (loadgen.sh stop)' | sed 's/^/stopped=/'; one_session srv_load1 > /dev/null; echo "rc=$?"; rm -f "$STOP_MARK"
'@
    $out = @(Invoke-BashFunction 'guest\shared\loadgen.sh' @('system_sql', 'one_session') $calls | Where-Object { $_ -like 'rc=*' -or $_ -like 'stopped=*' })
    # T8 run 3 (16.11): kill session immediate sometimes leaves the client with ORA-03114 instead of ORA-00028; only after
    # "loadgen.sh stop" is that a planned stop, during a fault (T2-T4) it stays a session failure
    Assert-Equal 'rc=1 rc=1 rc=0 rc=0 rc=1 stopped=1 rc=0' ($out -join ' ') 'logon failure and not connected fail; finished or stopped (ORA-00028) pass; ORA-03114 passes only after stop'
    $lg = [IO.File]::ReadAllText((Join-Path $Repo 'guest\shared\loadgen.sh'))
    Assert-True ($lg -match 'touch "\$STOP_MARK"' -and $lg -match 'rm -f "\$STOP_MARK"') 'stop leaves the mark, a new load clears it'
    $lg = [IO.File]::ReadAllText((Join-Path $Repo 'guest\shared\loadgen.sh'))
    Assert-True ($lg -match "(?i)module = 'LOADGEN'" -and $lg -match '(?i)alter system kill session') 'loadgen.sh stop kills the LOADGEN sessions in the database'
    Assert-True ([IO.File]::ReadAllText((Join-Path $Repo 'sql\06_loadgen.sql')) -match "(?i)set_module\('LOADGEN'") 'LOADGEN sets its module'
    $rt = [IO.File]::ReadAllText((Join-Path $Repo 'tests\run_test.ps1'))
    Assert-True ($rt -match '(?s)function Stop-Load\b[^\r\n]*\{[^}]*loadgen\.sh stop.*?WaitForExit') 'Stop-Load stops the sessions on the guest and waits for the client'
    Assert-True ($rt -match '(?s)Start-Sleep -Seconds [^\r\n]*\$case\.PostSec[^\r\n]*\r?\n(\s*\$tObserveEnd[^\r\n]*\r?\n)?\s*Stop-Load\b.*?\$cmp = Get-Compare') 'run_test stops the load before comparing'
}
# Important 11 (film S1): every command with ts_utc, t_rel_s to the fault and its output, masked
function Test-CommandLog {
    Import-HarnessModules
    $t0 = [datetime]::Parse('2026-11-20T10:00:00Z').ToUniversalTime()
    $e = @([pscustomobject]@{ Ts = $t0.AddSeconds(-2.5); Node = 'ggtgt'; Command = 'bash /root/lab/shared/probe.sh lag 1 --once'; Output = @('TICK lag', 'LAG 3') }
           [pscustomobject]@{ Ts = $t0.AddSeconds(1); Node = 'host'; Command = 'VBoxManage controlvm ggrac1 poweroff'; Output = @() })
    $l = @(Format-CommandLog -Entries $e -FaultUtc $t0)
    Assert-Equal '2026-11-20T09:59:57.500Z t_rel_s=-2.500 [ggtgt] $ bash /root/lab/shared/probe.sh lag 1 --once' $l[0] 'command line with both times'
    Assert-Equal '    LAG 3' $l[2] 'output indented under its command'
    Assert-True ($l[3] -match 't_rel_s=1\.000 \[host\] \$ VBoxManage') 'host commands are logged too'
    $rt = [IO.File]::ReadAllText((Join-Path $Repo 'tests\run_test.ps1'))
    Assert-True ($rt -match "Protect-Text \(\(Format-CommandLog[^\r\n]*commands\.txt|commands\.txt'\) \(Protect-Text \(\(Format-CommandLog") 'run_test writes commands.txt masked'
}
# Film D1: missing and duplicate SEQ per instance; data_ok needs real load rows
function Test-SeqCheckCounts {
    Import-HarnessModules
    $s = @(Get-SeqCheck -Source @('SEQ 1 300 300 1 600', 'SEQ 2 301 300 2 599') -Target @('SEQ 1 300 300 1 600', 'SEQ 2 297 297 2 590'))
    $i2 = $s | Where-Object inst -eq '2'
    Assert-Equal 3 $i2.missing 'instance 2: 3 SEQ missing on the target'
    Assert-Equal 1 $i2.duplicates_source 'instance 2: one duplicate SEQ on the source'
    Assert-Equal 0 ($s | Where-Object inst -eq '1').missing 'instance 1 complete'
    $ok = @([pscustomobject]@{ Table = 'SALES.LOAD_EVENTS'; SourceRows = 600; TargetRows = 600; Match = $true })
    $okSeq = @(Get-SeqCheck -Source @('SEQ 1 300 300 1 600') -Target @('SEQ 1 300 300 1 600'))
    Assert-True (Get-DataVerdict -Tables $ok -SeqCheck $okSeq).Ok 'equal data with load rows'
    $empty = @([pscustomobject]@{ Table = 'SALES.LOAD_EVENTS'; SourceRows = 0; TargetRows = 0; Match = $true })
    $v = Get-DataVerdict -Tables $empty -SeqCheck @()
    Assert-True (-not $v.Ok -and $v.Reason -match 'no load') 'no load rows: never data_ok'
    Assert-True (-not (Get-DataVerdict -Tables $ok -SeqCheck $s).Ok) 'missing SEQ: not data_ok'
}
# Important 8: a dead SSH session must not kill a long step (tee SIGPIPE -> dbca/runInstaller), and a re-run
# while the step still runs attaches to it instead of starting a second installer (Git Bash has no flock/setsid)
function Test-GuestStepDetached {
    $w = Join-Path $Repo 'guest\run_step.sh'
    Assert-True (Test-Path $w) 'guest/run_step.sh exists'
    $t = [IO.File]::ReadAllText($w)
    foreach ($p in 'setsid flock -o "\$lock"', 'flock -n "\$lock" true', '> "\$RS_OUT" 2>&1 < /dev/null', 'still running', 'tail -n \+1 -f "\$out"') {
        Assert-True ($t -match $p) "run_step.sh lacks: $p"
    }
    $lab = [IO.File]::ReadAllText((Join-Path $Repo 'lab.ps1'))
    Assert-True ($lab -match 'Invoke-Ssh -Node \$Node -Command "bash /root/lab/run_step\.sh \$Dir/\$Script \$Arguments"') 'Invoke-Guest runs every step through run_step.sh'
    Assert-True ($lab -match "Join-Path \`$RepoRoot 'guest\\run_step\.sh'") 'Sync-Guest copies run_step.sh'
}
# Important 10: SQL*Plus echoes the failing line (IDENTIFIED BY "<pw>") even with ECHO OFF: mask before tee;
# the rendered users file goes away on every exit
function Test-SecretMasked {
    $calls = @'
LAB_PASS='Secr3t_pw'
printf 'ORA-00922: missing option\nCREATE USER ggadmin IDENTIFIED BY "Secr3t_pw"\nno newline Secr3t_pw' | mask_secret
LAB_PASS=''
printf 'plain' | mask_secret
'@
    $out = @(Invoke-BashFunction 'guest\lib.sh' @('mask_secret') $calls)
    Assert-Equal 'CREATE USER ggadmin IDENTIFIED BY "********"' $out[1] 'password masked'
    Assert-Equal 'no newline ********' $out[2] 'last line without a newline is kept and masked'
    Assert-Equal 'plain' $out[3] 'no LAB_PASS: text unchanged'
    $lib = [IO.File]::ReadAllText((Join-Path $Repo 'guest\lib.sh'))
    Assert-True ($lib -match '(?s)sysdba_file\(\) \{.*?\| mask_secret \| tee -a') 'sysdba_file masks before the log'
    Assert-True ($lib -match '(?s)adminclient_run\(\) \{.*?\|\s*mask_secret \| tee -a') 'adminclient_run uses the same mask'
    foreach ($f in 'guest\rac\88_oggconf_source.sh', 'guest\tgt\88_oggconf_target.sh') {
        $t = [IO.File]::ReadAllText((Join-Path $Repo $f))
        $iTrap = $t.IndexOf("trap 'rm -f `"`$USERS_SQL`"' EXIT"); $iRender = $t.IndexOf('render_secret')
        Assert-True ($iTrap -gt 0 -and $iTrap -lt $iRender) "$f removes the users file on every exit (trap before render_secret)"
    }
}
# Important 13: an interrupted unzip must not count as done (one file inside appears early in the extract)
function Test-UnzipOnce {
    $calls = @'
DONE_DIR=$(mktemp -d); DRY_RUN=0; NODE_NAME=t
as_user() { echo "AS $1: $2"; return ${UNZ_RC:-0}; }
unzip_once grid /stage/gi.zip /u01/grid
unzip_once grid /stage/gi.zip /u01/grid
( UNZ_RC=1; unzip_once grid /stage/ru.zip /stage/ru_gi ) 2>/dev/null; echo "rc=$?"
ls "$DONE_DIR" | grep -c 'ru.zip' || true
'@
    $out = @(Invoke-BashFunction 'guest\lib.sh' @('log', 'ok', 'die', 'step_done', 'mark_done', 'unzip_once') $calls)
    Assert-True ($out[1] -match '^AS grid: mkdir -p /u01/grid && cd /u01/grid && unzip -q -o /stage/gi\.zip$') "first call unzips (got: $($out -join ' | '))"
    Assert-True ($out[2] -match 'OK .*gi\.zip already unzipped') 'second call skips on the marker'
    Assert-True (-not ($out -match '^AS grid: .*gi\.zip' | Select-Object -Skip 1)) 'no second unzip of the same ZIP'
    Assert-Equal 'rc=1' ($out -match '^rc=')[0] 'a failed unzip stops the step'
    Assert-Equal '0' $out[-1] 'a failed unzip leaves no marker'
    $left = foreach ($f in Get-ChildItem (Join-Path $Repo 'guest') -Recurse -Filter '*.sh' | Where-Object Name -ne 'lib.sh') {
        foreach ($l in [IO.File]::ReadAllLines($f.FullName)) { if ($l -match 'unzip -q' -and $l -notmatch 'rm -rf OPatch') { "$($f.Name): $($l.Trim())" } }
    }
    Assert-True (-not $left) "unzip outside unzip_once: $($left -join '; ')"
}
# Important 9: a re-run never formats again (libblkid may not know ACFS); registered = formatted; never mkfs -f
function Test-AcfsNoRemkfs {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\70_acfs.sh'))
    $iCfg = $t.IndexOf('config filesystem'); $iMkfs = $t.IndexOf('mkfs -t acfs "$dev"')
    Assert-True ($iCfg -gt 0 -and $iCfg -lt $iMkfs) 'srvctl config filesystem is checked before mkfs'
    $code = @($t -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Assert-True ($code -notmatch 'mkfs -t acfs -f|mkfs[^\r\n]*\s-f\s') 'never mkfs -f'
}
# Important 12: a database registered in the cluster but without an open PDB (dbca failed late) stops with what to do
function Test-PdbReady {
    $calls = @'
F=$(mktemp -u)
sysdba_query() { case "$1" in *alter*) : > "$F" ;; *) if [ -f "$F" ]; then echo "$AFTER"; else echo "$BEFORE"; fi ;; esac; }
BEFORE='READ WRITE'; rm -f "$F"; pdb_ready SRCPDB; echo "rc=$?"
BEFORE=''; rm -f "$F"; pdb_ready SRCPDB; echo "rc=$?"
BEFORE='MOUNTED'; AFTER='READ WRITE'; rm -f "$F"; pdb_ready SRCPDB; echo "rc=$?"
BEFORE='MOUNTED'; AFTER='MOUNTED'; rm -f "$F"; pdb_ready SRCPDB; echo "rc=$?"
'@
    $out = @(Invoke-BashFunction 'guest\lib.sh' @('pdb_ready') $calls | Where-Object { $_ -like 'rc=*' })
    Assert-Equal 'rc=0 rc=1 rc=0 rc=1' ($out -join ' ') 'open: ok; missing: fail; mounted: opened; still mounted: fail'
    foreach ($kv in @{ 'guest\rac\60_create_db.sh' = 'SRC_PDB'; 'guest\tgt\60_create_db.sh' = 'TGT_PDB' }.GetEnumerator()) {
        $t = [IO.File]::ReadAllText((Join-Path $Repo $kv.Key))
        Assert-True ($t -match "(?s)pdb_ready `"\`$$($kv.Value)`" \|\|.*?deleteDatabase") "$($kv.Key): no open PDB -> stop with the cleanup command"
    }
}
# Minor raised: EXIT SQL.SQLCODE returns SQLCODE mod 256 (ORA-01536 -> rc 0); a fault that did not happen fails the run
function Test-SqlExitAndFaultChecks {
    $bad = @(Get-ChildItem (Join-Path $Repo 'sql') -Filter '*.sql' | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '(?i)EXIT\s+SQL\.SQLCODE' } | ForEach-Object Name)
    Assert-True (-not $bad) "WHENEVER SQLERROR EXIT SQL.SQLCODE (rc mod 256 may be 0): $($bad -join ', ')"
    Import-HarnessModules
    $c = Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')
    $sm = (Get-FaultCommand -Kind kill-sm -Target ggrac1 -Config $c).Command
    $ex = (Get-FaultCommand -Kind kill-ext -Target ggrac1 -Config $c).Command
    Assert-True ($sm -match '/bin/\[S\]erviceManager' -and $sm -match '\[ -n "\$p" \]') "kill-sm: pgrep cannot match its own shell, an empty PID list fails (got: $sm)"
    Assert-True ($ex -match '\[e\]xtract' -and $ex -match '\[ -n "\$p" \]') "kill-ext: same guard (got: $ex)"
    Assert-True ([IO.File]::ReadAllText((Join-Path $Repo 'tests\run_test.ps1')) -match 'fault command failed') 'run_test stops when the fault command fails'
}
# Deferred minor: gg_node under set -euo pipefail (service down -> sed 0p failed and aborted validate);
# srvctl prints "running on instance(s) ggcdb2" with or without a colon
function Test-ValidateGgNode {
    $calls = @'
set -euo pipefail
SRC_DB=ggcdb; GG_SERVICE=gg_srcpdb; RAC_NODES='ggrac1 ggrac2'
runuser() { echo "$SVC_OUT"; }
SVC_OUT='Service gg_srcpdb is running on instance(s) ggcdb2'; echo "a=[$(gg_node)]"
SVC_OUT='Service gg_srcpdb is running on instance(s): ggcdb1'; echo "b=[$(gg_node)]"
SVC_OUT='Service gg_srcpdb is not running.'; echo "c=[$(gg_node)]"
SVC_OUT='Service gg_srcpdb is running on nodes: ggrac2'; echo "d=[$(gg_node)]"
SVC_OUT='Service gg_srcpdb is running on instances ggcdb1'; echo "e=[$(gg_node)]"
echo survived
'@
    $out = @(Invoke-BashFunction 'guest\rac\90_validate.sh' @('gg_node') $calls)
    Assert-Equal 'a=[ggrac2] b=[ggrac1] c=[] d=[ggrac2] e=[ggrac1] survived' ($out -join ' ') 'node of the service: instance(s) with/without a colon, down, nodes: form (12.1 doc example), instances (26ai, lab 15.11)'
    # The service checks accept both forms too (docs check 15.11: 23ai/26ai do not document the output)
    $v = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\90_validate.sh'))
    Assert-True ($v -notmatch "running on instance\(s\): \$") 'no service check needs the colon'
    Assert-Equal 2 ([regex]::Matches($v, [regex]::Escape("grep -Eq 'running on (instance\(s\)|instances):? *"))).Count 'GG service and load services accept instance(s) and instances (26ai), optional colon'
    # gv$parameter holds non-numeric values (DISABLED): to_number must not see them (ORA-01722, lab 15.11)
    Assert-True ($v -match "to_number\(value default null on conversion error\)") 'streams_pool_size check survives non-numeric parameter values'
}
# Deferred minor: the gg probe keeps only the last adminclient call in its log (was +1 call every 2 s, unbounded)
function Test-ProbeAdminclientLogBounded {
    $calls = @'
G=$(mktemp -d); XAG_RES=x; NODE_NAME=ggrac1; OGG_PATH=DP1; OGG_SRC_DEPLOY=oggsource
adminclient_run() { echo "call" >> "$LOG_DIR/adminclient_$2.log"; printf 'Extract RUNNING EXT1\n'; }
printf '#!/bin/bash\necho STATE=ONLINE on ggrac1\n' > "$G/crsctl"; chmod +x "$G/crsctl"
probe_gg src > /dev/null; probe_gg src > /dev/null; probe_gg src > /dev/null
wc -l < /tmp/probe_gg/adminclient_oggsource.log
'@
    $out = @(Invoke-BashFunction 'guest\shared\probe.sh' @('state_of', 'xag_node', 'probe_gg') $calls)
    Assert-Equal '1' "$($out[-1])".Trim() 'one adminclient call in the probe log, not one per sample'
}
# Deferred minor: verbs reserved for later tasks say where the work is, exit 2, no stack trace
function Test-ReservedVerbsPointTheWay {
    $exp = @{ test = 'tests\\run_test\.ps1'; snapshot = 'Task 12'; maa = 'KB101098' }
    foreach ($v in $exp.Keys) {
        $o = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') $v -DryRun 2>&1 | Out-String
        Assert-Equal 2 $LASTEXITCODE "lab.ps1 $v exit code"
        Assert-True ($o -match $exp[$v]) "lab.ps1 $v names where to go ($($exp[$v])): $o"
    }
}
# ISO jak w vbox-lab: brak = plan ostrzega, iso/all pobiera (curl -C -); zla suma zatrzymuje przed build
# ISO as in vbox-lab: missing = plan warns, iso/all downloads (curl -C -); a bad checksum stops before build
function Test-IsoStep {
    $empty = New-TestDir
    $p = New-TempConfig -Regex @{ "(?m)^(\s*IsoDir\s*=\s*)'[^']*'" = "`$1'$empty'" }
    $r = Invoke-PlanText @('-ConfigPath', $p)
    Assert-True ($r.Text -match 'WARN ISO .*not in .*lab\.cmd iso') "plan warns about a missing ISO: $($r.Text)"
    Assert-True ($r.Text -notmatch '-\s+.*ISO') 'missing ISO is not a NOT READY problem (all downloads it)'
    $o = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') iso -DryRun -ConfigPath $p 2>&1 | Out-String
    Assert-Equal 0 $LASTEXITCODE 'iso -DryRun exit code'
    Assert-True ($o -match 'DRY\s+curl\.exe .*yum\.oracle\.com/ISOS/.*boot\.iso') "iso -DryRun shows the download: $o"
    # Falszywe ISO o malej wielkosci: suma niezgodna, bez pobierania / small fake ISO: checksum mismatch, no download
    $bad = New-TestDir
    [IO.File]::WriteAllText((Join-Path $bad 'OracleLinux-R9-U8-x86_64-boot.iso'), 'not an iso')
    $p2 = New-TempConfig -Regex @{ "(?m)^(\s*IsoDir\s*=\s*)'[^']*'" = "`$1'$bad'" }
    # -DryRun: suma liczona i tak, a logs/steps.csv (dane filmu) zostaje nietkniety
    # -DryRun: the checksum is still computed, and logs/steps.csv (film data) stays untouched
    $log = Join-Path $Repo 'logs\steps.csv'
    $before = if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }
    $o = & pwsh -NoProfile -File (Join-Path $Repo 'lab.ps1') iso -DryRun -ConfigPath $p2 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -ne 0 -and $o -match 'ISO SHA-256 mismatch') "bad ISO must stop with a clear message: $o"
    $after = if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }
    Assert-Equal $before $after 'tests must not write logs/steps.csv'
}
# Film A2: all zapisuje wiersz steps.csv na kazdy krok (scena „lab buduje sie sam”), nie jeden wiersz „all”
# Film A2: all writes one steps.csv row per step (scene "the lab builds itself"), not a single "all" row
function Test-AllLogsEachStep {
    $text = [IO.File]::ReadAllText((Join-Path $Repo 'lab.ps1'))
    $body = [regex]::Match($text, '(?s)function Step-All \{(.*?)\n\}').Groups[1].Value
    Assert-True ([bool]$body) 'Step-All found'
    $bare = @([regex]::Matches($body, '\bStep-(?!Plan\b)\w+') | ForEach-Object Value)
    Assert-True ($bare.Count -eq 0) "steps in all must run through Invoke-LoggedStep: $($bare -join ', ')"
    $logged = @([regex]::Matches($body, 'Invoke-LoggedStep (\w+)') | ForEach-Object { $_.Groups[1].Value })
    foreach ($s in 'iso', 'build', 'grid', 'ogg', 'xag', 'validate') { Assert-True ($s -in $logged) "all logs step $s" }
    Assert-Equal 'iso' $logged[0] 'all starts with iso (download before the plan)'
}
# Pierwsza budowa 15.11: sprawdzanie serwera KS pyta o plik, ktorego nie bylo (404 -> "nie odpowiada")
# First build 15.11: the KS server probe asked for a file that was not there (404 -> "not responding")
function Test-KsHealthFileServed {
    $probe = [IO.File]::ReadAllText((Join-Path $Repo 'host\modules\KsServer.psm1'))
    $rel = [regex]::Match($probe, 'Port\}/([\w./-]+)"').Groups[1].Value
    Assert-True ([bool]$rel) 'health probe path found in KsServer.psm1'
    Assert-True (Test-Path (Join-Path $Repo $rel)) "file the health probe asks for must exist in the repo: $rel"
}
# Film: komunikaty serwera KS pokazuja sama nazwe logu, nie sciezke z katalogu uzytkownika (%TEMP%)
# Film: KS server messages show the log file name only, not the path in the user profile (%TEMP%)
function Test-KsLogNameOnly {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'host\modules\KsServer.psm1'))
    $msgs = @([regex]::Matches($t, '(?m)^\s*(Write-\w+|throw)\s.*$') | ForEach-Object Value | Where-Object { $_ -match '(?i)log' })
    Assert-True ($msgs.Count -ge 2) "KS log messages found: $($msgs.Count)"
    # Get-Content $logErr wypisuje tresc logu, nie sciezke / prints the log content, not the path
    $bad = @($msgs | Where-Object { $_ -match '(?<!Get-Content )\$log(Err|Out)\b' })
    Assert-True ($bad.Count -eq 0) "message prints the full log path: $($bad -join ' | ')"
}
# Regula zapory innego labu (pgio: 192.168.56.0/24) na tym samym porcie nie wpuszcza VM z 192.168.58.x
# Another lab's firewall rule (pgio: 192.168.56.0/24) on the same port does not let 192.168.58.x VMs in
function Test-FirewallRemoteCoversSubnet {
    Import-LabModules
    Assert-True (Test-RemoteAllowsSubnet @('Any') '192.168.58.0') 'Any allows'
    Assert-True (Test-RemoteAllowsSubnet @('192.168.58.0/255.255.255.0') '192.168.58.0') 'our subnet (mask form)'
    Assert-True (Test-RemoteAllowsSubnet @('192.168.58.0/24') '192.168.58.0') 'our subnet (prefix form)'
    Assert-True (Test-RemoteAllowsSubnet @('LocalSubnet') '192.168.58.0') 'LocalSubnet keyword'
    Assert-True (-not (Test-RemoteAllowsSubnet @('192.168.56.0/255.255.255.0') '192.168.58.0')) 'pgio rule must not count'
    Assert-True (-not (Test-RemoteAllowsSubnet @('10.0.0.5') '192.168.58.0')) 'single foreign address must not count'
    $lab = [IO.File]::ReadAllText((Join-Path $Repo 'lab.ps1'))
    $fn = [regex]::Match($lab, '(?s)function Test-KsFirewallRule \{(.*?)\n\}').Groups[1].Value
    Assert-True ($fn -match 'Test-RemoteAllowsSubnet') 'Test-KsFirewallRule checks the remote address, not only the port'
}
# Docs check round 2 (15.11): response keys get renamed between releases (26ai: installOption, UNIX_GROUP ...):
# a key missing from the shipped sample stops the step before the installer, with what to fix
function Test-RspKeysCheck {
    $calls = @'
DRY_RUN=0; NODE_NAME=t; d=$(mktemp -d)
printf 'a=1\nb.c=2\n' > "$d/ours"; printf 'a=\n#b.c=\n' > "$d/s1"; printf 'a=\n' > "$d/s2"
( rsp_keys_check "$d/ours" "$d/s1" demo.rsp ); echo "rc=$?"
( rsp_keys_check "$d/ours" "$d/s2" demo.rsp ) 2>&1 | grep -c 'b.c' ; ( rsp_keys_check "$d/ours" "$d/s2" demo.rsp ) 2>/dev/null; echo "rc=$?"
( rsp_keys_check "$d/ours" "$d/none" demo.rsp ); echo "rc=$?"
'@
    $out = @(Invoke-BashFunction 'guest\lib.sh' @('log', 'ok', 'warn', 'die', 'rsp_keys_check') $calls)
    Assert-Equal 'rc=0' ($out -match '^rc=')[0] 'keys in the sample (also commented): ok'
    Assert-True ($out -contains '1') 'the unknown key is named in the message'
    Assert-Equal 'rc=1' ($out -match '^rc=')[1] 'unknown key: the step stops'
    Assert-Equal 'rc=0' ($out -match '^rc=')[2] 'no sample: warning only'
    foreach ($f in 'guest\rac\40_install_grid.sh', 'guest\shared\install_db.sh', 'guest\shared\install_ogg.sh') {
        $t = [IO.File]::ReadAllText((Join-Path $Repo $f))
        Assert-True ($t -match 'rsp_keys_check ' -and $t -notmatch 'keys not in the sample') "$f uses rsp_keys_check"
    }
}
# Docs check round 2: the XAG Microservices template has --service_manager as a bare flag: try it first
function Test-AgctlServiceManagerBareFirst {
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'guest\rac\87_xag_register.sh'))
    Assert-True ($t -match "for form in '' yes; do") 'bare --service_manager first, "yes" only as the fallback'
    Assert-True ($t -match '\[ -z "\$form" \] && echo "\$out" \| grep') 'retry only after the bare form got a syntax complaint'
}
# Public repo: no local paths, user names or session links in any tracked file (this test file excluded)
function Test-NoLocalPathsInRepo {
    $pat = '(?i)' + (@('[A-Z]:\\__AI__', '[A-Z]:\\Users\\[A-Za-z0-9._-]', ('kr' + 'zys'), ('_tab' + 'lica_'),'claude\.ai/(code|artifact)') -join '|')
    $hits = foreach ($f in @(& git -C $Repo ls-files)) {
        if ($f -eq 'tests/static/Test-Static.ps1') { continue }
        $p = Join-Path $Repo $f
        if ((Get-Item $p).Length -gt 2MB) { continue }
        $i = 0
        foreach ($l in [IO.File]::ReadAllLines($p)) { $i++; if ($l -match $pat) { "${f}:$i" } }
    }
    Assert-True (-not $hits) "local paths or names in tracked files: $($hits -join ', ')"
}
# Important 4: heartbeat every few seconds; lag grows while heartbeats stop arriving
function Test-HeartbeatFrequency {
    foreach ($f in 'setup_source.oby', 'setup_target.oby') {
        Assert-True ([IO.File]::ReadAllText((Join-Path $Repo "ogg\$f")) -match '(?m)^ADD HEARTBEATTABLE, FREQUENCY [1-5]\s*$') "$f heartbeat FREQUENCY 1-5 s"
    }
    Assert-True ([IO.File]::ReadAllText((Join-Path $Repo 'guest\shared\probe.sh')) -match 'incoming_heartbeat_age') 'lag adds the age of the last heartbeat'
}
# Build attempt 4 (15.11): storagectl right after modifyvm hit "already locked for a session (or being unlocked)":
# VBoxSVC releases the session lock with a delay. The command changed nothing, so Invoke-VBox waits and repeats;
# any other error still stops at once, and a lock that never goes away stops after the last attempt.
function Test-VBoxLockRetry {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("gglab-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $fake = Join-Path $dir 'fakevbox.ps1'
    Set-Content -Path $fake -Encoding utf8NoBOM -Value @'
$n = [int](Get-Content "$PSScriptRoot\count.txt") + 1
Set-Content "$PSScriptRoot\count.txt" $n
$mode = Get-Content "$PSScriptRoot\mode.txt"
if ($mode -eq 'other') { "VBoxManage.exe: error: Could not find a registered machine named 'x'"; exit 1 }
if ($n -le [int]$mode) { "VBoxManage.exe: error: The machine 'x' is already locked for a session (or being unlocked)"; exit 1 }
exit 0
'@
    $path = Join-Path $Repo 'host\modules\VmBuilder.psm1'
    $mod = Import-Module $path -Force -DisableNameChecking -PassThru
    try {
        & $mod { param($f) $script:FakeVBox = $f; function script:Get-VBoxManagePath { $script:FakeVBox }
                 $script:LockRetryDelayMs = 10 } $fake
        $run = {
            param($mode)
            Set-Content (Join-Path $dir 'count.txt') 0; Set-Content (Join-Path $dir 'mode.txt') $mode
            $err = ''
            try { Invoke-VBox storagectl x --name SATA 6>$null } catch { $err = $_.Exception.Message }
            [pscustomobject]@{ Err = $err; Calls = [int](Get-Content (Join-Path $dir 'count.txt')) }
        }
        $r = & $run 2
        Assert-Equal '' $r.Err 'lock released after two attempts: the command succeeds'
        Assert-Equal 3 $r.Calls 'two locked attempts + the one that worked'
        $r = & $run 99
        Assert-True ($r.Err -match 'already locked for a session') 'a lock that stays stops the step with the VBoxManage message'
        Assert-Equal 6 $r.Calls 'first attempt + 5 repeats, then stop'
        $r = & $run 'other'
        Assert-True ($r.Err -match 'Could not find a registered machine') 'other errors keep the full message'
        Assert-Equal 1 $r.Calls 'other errors are not repeated'
    } finally {
        Import-Module $path -Force -DisableNameChecking
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

# ------------------------------------------------------------------------------
# lab.cmd shutdown (host/Shutdown.psm1)
# ------------------------------------------------------------------------------
function Get-TestShutdownSteps {
    Import-LabModules
    Import-Module (Join-Path $Repo 'host\Shutdown.psm1') -Force -DisableNameChecking
    @(Get-ShutdownSteps -Config (Get-GgConfig -Path (Join-Path $Repo 'lab.config.psd1')))
}
# GG source first (no failover), target before the RAC database, CRS node by node (no -all), the VMs last
function Test-ShutdownStepOrder {
    $s = Get-TestShutdownSteps
    $ids = ($s | ForEach-Object { if ($_.Node) { "$($_.Id)@$($_.Node)" } else { $_.Id } }) -join ' '
    Assert-Equal ('gg_src gg_src_procs@ggrac1 gg_src_procs@ggrac2 tgt_gg@ggtgt tgt_db@ggtgt rac_db rac_pmon@ggrac1 ' +
                  'rac_pmon@ggrac2 crs@ggrac1 crs@ggrac2 vms') $ids 'shutdown step order'
    $all = ($s | ForEach-Object Command) -join "`n"
    Assert-True ($all -notmatch 'stop cluster|stop crs -f|-all\b') 'no crsctl stop cluster -all, no forced stop'
    Assert-True ($all -match [regex]::Escape('/u01/app/xag/bin/agctl stop goldengate oggsource')) 'agctl path and deployment from the config'
    Assert-True ($all -match [regex]::Escape('/u01/app/23.26/grid/bin/crsctl stop crs')) 'crsctl from GridHome'
    Assert-True ($all -match 'srvctl stop database -d ggcdb') 'RAC database from SrcDb'
    foreach ($x in $s | Where-Object Scope -ne 'vms') {
        Assert-True ($x.TimeoutSec -gt 0 -and $x.Command -match "\bW $($x.TimeoutSec)\b") "$($x.Id): waits with its own time limit"
        Assert-True ($x.Command -match 'R (ok|timeout)') "$($x.Id): ends with a RESULT line"
    }
}
function Test-ShutdownCommandsBashSyntax {
    $bash = Get-BashExe
    $bad = foreach ($x in Get-TestShutdownSteps | Where-Object Command) {
        $f = New-TemporaryFile
        try {
            [IO.File]::WriteAllText($f, $x.Command + "`n", [Text.UTF8Encoding]::new($false))
            $err = & $bash -n $f.FullName 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { "$($x.Id): $err" }
        } finally { Remove-Item $f -Force }
    }
    Assert-True (-not $bad) "bash -n: $($bad -join '; ')"
}
# The pgrep patterns must not match the bash -c that carries them (bracket trick), but must match the real processes
function Test-ShutdownPgrepPatterns {
    $s = Get-TestShutdownSteps
    $p = [regex]::Match(($s | Where-Object Id -eq 'gg_src_procs' | Select-Object -First 1).Command, "P='([^']+)'").Groups[1].Value
    Assert-True ('/u01/app/ogg/ogg26ai_ma/bin/ServiceManager' -match $p) 'Service Manager matches'
    Assert-True ('/u01/app/ogg/ogg26ai_ma/bin/extract PARAMFILE x' -match $p) 'extract matches'
    Assert-True ("bash -c P='$p'; ok" -notmatch $p) 'the carrying bash -c does not match itself'
    Assert-True ('ora_pmon_ggcdb2' -match '^ora_pmon_ggcdb[0-9]+$') 'RAC pmon pattern'
}
function Test-ShutdownResultParse {
    Import-Module (Join-Path $Repo 'host\Shutdown.psm1') -Force -DisableNameChecking
    $r = ConvertFrom-ShutdownResult -Lines @('  [ggrac1] noise', 'RESULT timeout x still ONLINE', '  RESULT ok agctl rc=0')
    Assert-Equal 'ok' $r.Result 'last RESULT line wins'
    Assert-Equal 'agctl rc=0' $r.Detail 'detail'
    Assert-Equal 'error' (ConvertFrom-ShutdownResult -Lines @()).Result 'no output = error'
}
function Test-ShutdownVerb {
    $t = Get-Content -Raw (Join-Path $Repo 'lab.ps1')
    Assert-True ($t -match "'stop', 'shutdown', 'destroy'") 'shutdown in ValidateSet'
    Assert-True ($t -match "'shutdown' \{ Step-Shutdown \}") 'switch runs Step-Shutdown'
    Assert-True ($t -match "-notin 'plan', 'status', 'ssh', 'start', 'stop', 'shutdown', 'destroy'") 'logs\STOP does not block shutdown'
    Assert-True ($t -match '\[switch\]\$Force') '-Force parameter'
}

# ------------------------------------------------------------------------------
# T10 DDL steps in the test automation (16.11: the first T10 run passed with no DDL, the steps ran by hand)
# ------------------------------------------------------------------------------
$script:T10Row = "ROW=`"select id || ' ' || from_vector(v) || ' ' || case when b then 'TRUE' else 'FALSE' end || ' ' || json_serialize(j)`""
# Every action has SQL, one statement per line (26ai: ORA-03405 for "stmt; stmt;"), unknown action = no SQL
function Test-T10GuestSql {
    $acts = @('src ping', 'src insert101', 'src row101', 'src ddl_add', 'src insert102', 'src row102', 'src cleanup',
              'tgt ping', 'tgt has_row101', 'tgt row101', 'tgt has_note', 'tgt has_row102', 'tgt row102', 'tgt no_note', 'tgt no_rows')
    $calls = $script:T10Row + "`n" + (($acts | ForEach-Object { "echo '== $_'; t10_sql $_" }) -join "`n") + "`necho '== bad'; t10_sql tgt insert101; echo '== end'"
    $out = @(Invoke-BashFunction 'guest\shared\t10_ddl_steps.sh' @('t10_sql') $calls)
    foreach ($a in $acts) {
        $i = [array]::IndexOf($out, "== $a"); Assert-True ($i -ge 0 -and $out[$i + 1] -and $out[$i + 1] -notlike '== *') "t10_sql $a gives SQL"
    }
    foreach ($l in $out | Where-Object { $_ -notlike '== *' -and $_ }) {
        Assert-True (($l -split ';\s*').Where({ $_.Trim() }).Count -le 1) "one statement per line: $l"
    }
    $b = [array]::IndexOf($out, '== bad'); Assert-Equal '' "$($out[$b + 1])".Trim() 'insert on the target = unknown action'
    $sql = $out -join "`n"
    Assert-True ($sql -match '(?m)^alter table sales\.types26 add \(note varchar2\(30\)\);$') 'DDL add'
    Assert-True ($sql -match '(?m)^alter table sales\.types26 drop column note;$') 'DDL drop in the clean-up'
    Assert-True ($sql -match "to_vector\('\[1\.5,2\.5,3\.5\]', 3, FLOAT32\), TRUE, json\(") '26ai types VECTOR, BOOLEAN, JSON'
}
# main: one "T10 <action> <value>" line; dry run prints the SQL; an ORA- error = "error" and rc 1
function Test-T10GuestMain {
    $fns = @('t10_sql', 't10_value', 'main')
    $calls = @($script:T10Row, 'SRC_PDB=SRCPDB; TGT_PDB=TGTPDB',
        '(DRY_RUN=1; side=src; act=ddl_add; main); echo "rc=$?"',
        'sysdba_query() { printf "\n"; }; (DRY_RUN=0; side=src; act=insert101; main); echo "rc=$?"',
        'sysdba_query() { printf " 1 \n"; }; (DRY_RUN=0; side=tgt; act=has_note; main)',
        'sysdba_query() { printf "101 [1.5,2.5,3.5] TRUE {\"t\":\"T10\",\"n\":101}\n"; }; (DRY_RUN=0; side=tgt; act=row101; main)',
        'sysdba_query() { echo "ERROR at line 1:"; echo "ORA-00942: table or view does not exist"; return 1; }; (DRY_RUN=0; side=src; act=row101; main); echo "rc=$?"',
        '(DRY_RUN=0; side=xx; act=row101; main); echo "rc=$?"') -join "`n"
    $out = @(Invoke-BashFunction 'guest\shared\t10_ddl_steps.sh' $fns $calls)
    Assert-True ($out -contains '  DRY  [oracle] SRCPDB: alter table sales.types26 add (note varchar2(30));') 'dry run prints the SQL with the PDB'
    Assert-True ($out -contains 'T10 ddl_add dry') 'dry run result line'
    Assert-True ($out -contains 'T10 insert101 done') 'DML prints nothing: done'
    Assert-True ($out -contains 'T10 has_note 1') 'trimmed count'
    Assert-True ($out -contains 'T10 row101 101 [1.5,2.5,3.5] TRUE {"t":"T10","n":101}') 'row as one line'
    Assert-True ($out -contains 'T10 row101 error ORA-00942: table or view does not exist') 'ORA- error in the result line'
    Assert-Equal 'rc=0 rc=0 rc=1 rc=1' (@($out | Where-Object { $_ -like 'rc=*' }) -join ' ') 'dry run and DML exit 0, ORA- error and bad side exit 1'
    Assert-True ($out -contains 'T10 row101 error usage: t10_ddl_steps.sh src|tgt <action>') 'bad side: usage'
}
function Test-T10LineParse {
    Import-HarnessModules
    $r = ConvertFrom-T10Line -Lines @('noise', 'T10 has_row101 0', 'T10 has_row101 1') -Action 'has_row101'
    Assert-True ($r.Ok -and $r.Value -eq '1') 'last line of the action wins'
    $r = ConvertFrom-T10Line -Lines @('T10 row101 error ORA-00942: x') -Action 'row101'
    Assert-True (-not $r.Ok -and $r.Detail -like 'error ORA-00942*') 'error line is not ok'
    Assert-True (-not (ConvertFrom-T10Line -Lines @() -Action 'ping').Ok) 'no output (ssh failed) is not ok'
    Assert-True (-not (ConvertFrom-T10Line -Lines @('T10 row1010 x') -Action 'row101').Ok) 'another action does not match'
    Assert-Equal 'READ WRITE' (ConvertFrom-T10Line -Lines @('T10 ping READ WRITE') -Action 'ping').Value 'value with a space'
}
# Fake source and target: the target answers 1 after a number of polls; the row read gives a fixed value
function New-T10Fakes([hashtable]$SrcOut, [hashtable]$TgtOut) {
    $state = @{ Calls = [System.Collections.Generic.List[string]]::new() }
    $src = { param($a) $state.Calls.Add("src $a"); if ($SrcOut.ContainsKey($a)) { $SrcOut[$a] } elseif ($a -like 'row*') { "T10 $a 101 x" } else { "T10 $a done" } }.GetNewClosure()
    $tgt = { param($a) $state.Calls.Add("tgt $a"); if ($TgtOut.ContainsKey($a)) { $TgtOut[$a] } elseif ($a -like 'row*') { "T10 $a 101 x" } else { "T10 $a 1" } }.GetNewClosure()
    @{ Src = $src; Tgt = $tgt; State = $state }
}
function Test-T10StepsAndVerdict {
    Import-HarnessModules
    $plan = Get-T10StepPlan
    Assert-Equal 'insert101 row101 ddl_add insert102 row102 cleanup cleanup_rows' (($plan | ForEach-Object Name) -join ' ') 'step order'
    # 1. everything arrives and is equal -> pass
    $f = New-T10Fakes @{ row101 = 'T10 row101 101 x'; row102 = 'T10 row102 102 y note' } @{ row101 = 'T10 row101 101 x'; row102 = 'T10 row102 102 y note' }
    $r = Invoke-T10Steps -Plan $plan -Src $f.Src -Tgt $f.Tgt -PollSec 0 -WaitSec 5
    Assert-True ($r.Checked -and $r.ValuesMatch) 'all steps: checked, values match'
    Assert-Equal 7 @($r.Steps | Where-Object ok).Count 'seven steps ok'
    Assert-True ($null -ne @($r.Steps)[0].seconds_to_target) 'seconds to the target measured'
    $v = Get-T10Verdict -Result $r
    Assert-True ($v.Ok -and -not $v.MeasurementError) 'verdict ok'
    # 2. the first source command fails (ssh / ORA-) -> not checked -> measurement_error ddl_not_run, no further calls
    $f = New-T10Fakes @{ insert101 = 'T10 insert101 error ORA-01034: ORACLE not available' } @{}
    $r = Invoke-T10Steps -Plan $plan -Src $f.Src -Tgt $f.Tgt -PollSec 0 -WaitSec 5
    $v = Get-T10Verdict -Result $r
    Assert-True (-not $r.Checked) 'first source command failed: not checked'
    Assert-Equal 'ddl_not_run' $v.MeasurementError 'ddl_not_run'
    Assert-True (-not $v.Ok -and $v.Reason -match 'ORA-01034') 'reason carries the error'
    Assert-Equal 1 $f.State.Calls.Count 'nothing after the failed first command'
    Assert-Equal 'ddl_not_run' (Get-T10Verdict -Result $null).MeasurementError 'no result at all (steps never started)'
    Assert-Equal 'kroki DDL niewykonane: source: error ORA-01034: ORACLE not available' (ConvertTo-PolishNote $v.Reason) 'journal note in Polish'
    # 3. the DDL never reaches the target -> fail, later steps skipped, clean-up still runs
    $f = New-T10Fakes @{} @{ has_note = 'T10 has_note 0' }
    $r = Invoke-T10Steps -Plan $plan -Src $f.Src -Tgt $f.Tgt -PollSec 0 -WaitSec 1
    $v = Get-T10Verdict -Result $r
    Assert-True ($r.Checked -and -not $v.Ok -and -not $v.MeasurementError) 'steps ran, DDL missing: fail, not a measurement error'
    Assert-True ($v.Reason -match 'ddl_add \(target: has_note not seen') 'reason names the step'
    Assert-Equal 'skipped after a failed step' (@($r.Steps) | Where-Object name -eq 'insert102').detail 'later steps skipped'
    Assert-True ($f.State.Calls -contains 'src cleanup') 'clean-up still runs'
    # 4. values differ -> fail
    $f = New-T10Fakes @{ row101 = 'T10 row101 101 [1,2,3] TRUE' } @{ row101 = 'T10 row101 101 [1,2,3] FALSE' }
    $r = Invoke-T10Steps -Plan $plan -Src $f.Src -Tgt $f.Tgt -PollSec 0 -WaitSec 5
    $v = Get-T10Verdict -Result $r
    Assert-True (-not $r.ValuesMatch -and -not $v.Ok) 'values differ: not pass'
    Assert-True ($v.Reason -match "values differ: source '101 \[1,2,3\] TRUE', target '101 \[1,2,3\] FALSE'") 'reason shows both values'
}
function Test-T10Wired {
    $case = & (Join-Path $Repo 'tests\cases\T10_ddl_types.ps1')
    Assert-Equal 'ddl-types' $case.Steps 'T10 case asks for the DDL steps'
    $t = [IO.File]::ReadAllText((Join-Path $Repo 'tests\run_test.ps1'))
    foreach ($w in 'Get-T10Verdict -Result $ddl', 'ddl_checked =', 'ddl_steps =', 'ddl_values_match =', "'t10_steps.log'", 'MeasurementError') {
        Assert-True ($t.Contains($w)) "run_test.ps1 lacks $w"
    }
    $out = & pwsh -NoProfile -File (Join-Path $Repo 'tests\run_test.ps1') -Test T10 -DryRun 2>&1 | Out-String
    foreach ($w in 'DRYRUN T10 DDL steps', 'insert101:', 'ddl_add:', 'cleanup_rows:', 'measurement_error ddl_not_run') {
        Assert-True ($out.Contains($w)) "T10 dry run lacks '$w'"
    }
}

# ------------------------------------------------------------------------------
# Runner
# ------------------------------------------------------------------------------
$tests = Get-Command -CommandType Function -Name 'Test-*' |
    Where-Object { $_.ScriptBlock.File -eq $PSCommandPath -and (-not $Only -or $_.Name -eq $Only) }
foreach ($t in $tests) {
    try { & $t.Name; $script:Passed++; Write-Host "PASS $($t.Name)" }
    catch { $script:Failures.Add("$($t.Name): $($_.Exception.Message)"); Write-Host "FAIL $($t.Name): $($_.Exception.Message)" }
}
Write-Host "---- $script:Passed passed, $($script:Failures.Count) failed"
exit ([int]($script:Failures.Count -gt 0))
