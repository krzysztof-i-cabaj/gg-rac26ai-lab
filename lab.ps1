# ==============================================================================
# Tytul:        lab.ps1
# Opis:         Sterowanie labem gg-rac26ai: DNS/NTP (gginfra), 2-wezlowy RAC 26ai
#               (ggrac1/2), cel single-instance (ggtgt), GoldenGate 26ai Microservices
#               z HA przez XAG + ACFS, testy awarii T1-T10. Silnik: lab T-158 + vbox-lab.
# Description [EN]: Drives the gg-rac26ai lab: DNS/NTP, 2-node RAC 26ai, single-instance
#               target, GoldenGate 26ai Microservices HA via XAG + ACFS, failure tests T1-T10.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       0.20 (shutdown: uporzadkowane wylaczenie labu / orderly lab shutdown; 0.19: Export-Csv bez przestarzalej flagi typu; 0.18: baseline: powrot do stanu bazowego, start konczy sie nim / back to the base state, start ends with it)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, VirtualBox 7.x, OpenSSH z kluczem, $env:LAB_PASS,
#                      binaria Oracle w Binaries.Dir (lab.config.psd1)
# Requirements [EN]: - PowerShell 7, VirtualBox 7.x, OpenSSH with a key, $env:LAB_PASS,
#                      Oracle binaries in Binaries.Dir (lab.config.psd1)
#
# Uzycie [PL]:       .\lab.cmd plan                 # podglad bez zmian (zawsze najpierw)
#                    .\lab.cmd plan -Drive E        # maszyny na innym dysku niz LabDrive z configu
#                    .\lab.cmd plan -ConfigPath X   # inny plik konfiguracji (testy)
#                    .\lab.cmd build [-DryRun]      # VM, dyski, instalacja OL9 z kickstartem
#                    .\lab.cmd infra|prereq|shared|grid|db|dbca|services|tgt|acfs|ogg|xag|oggconf
#                                                   # kroki budowy po kolei (opis: README_PL.md)
#                    .\lab.cmd validate             # pelna kontrola + porownanie danych zrodlo = cel
#                    .\lab.cmd baseline             # powrot do stanu bazowego (serwisy, GG, ACFS), bez zmian danych
#                    .\lab.cmd all                  # plan, potem build ... validate (etap A), powtarzalne
#                    .\lab.cmd status|start|stop [vm] ; .\lab.cmd destroy <vm|all>
#                    .\lab.cmd shutdown [-DryRun] [-Force]  # GG, cel, baza RAC, CRS po kolei, potem maszyny
# Usage [EN]:        plan [-Drive E] [-ConfigPath X] (read-only preview, always first);
#                    build [-DryRun] (VMs, disks, OL9 kickstart install); infra; prereq, shared, grid;
#                    db, dbca, services (RAC databases); tgt (target); acfs, ogg, xag (GoldenGate HA,
#                    stage A); oggconf, validate; baseline (back to the base state, data untouched; start ends with it);
#                    all (plan, build ... validate); status, start, stop, destroy;
#                    shutdown [-DryRun] [-Force] (source GG, target, RAC database, CRS node by node, then the VMs)
# ==============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'net', 'iso', 'build', 'infra', 'prereq', 'shared', 'grid', 'db', 'dbca', 'tgt',
                 'services', 'acfs', 'ogg', 'xag', 'oggconf', 'maa', 'validate', 'baseline', 'snapshot', 'test',
                 'status', 'ssh', 'start', 'stop', 'shutdown', 'destroy', 'all')]
    [string]$Verb = 'plan',
    [Parameter(Position = 1)][string]$Target,
    [string]$ConfigPath,
    # Dowolny dysk na maszyny, nadpisuje LabDrive z configu / any drive for VMs, overrides LabDrive
    [ValidatePattern('^[A-Za-z]$')][string]$Drive,
    [switch]$DryRun,
    # shutdown: dalej mimo trwajacego testu albo nieudanego kroku / go on despite a running test or a failed step
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
# Kolejnosc odwrotna do zaleznosci, -Global: moduly vbox-lab importuja Common z -Force (jak w T-158)
# Reverse dependency order, -Global: vbox-lab modules re-import Common with -Force (as in T-158)
foreach ($m in 'BootKickstart', 'KsServer', 'Network', 'VmBuilder', 'Scancode', 'Common') {
    Import-Module (Join-Path $RepoRoot "host\modules\$m.psm1") -Force -DisableNameChecking -Global
}
foreach ($m in 'Config', 'Binaries', 'VmPlan', 'Kickstart', 'Guest', 'Shutdown') {
    Import-Module (Join-Path $RepoRoot "host\$m.psm1") -Force -DisableNameChecking -Global
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'lab.config.psd1' }
$cfg = Get-GgConfig -Path $ConfigPath
if ($Drive) { $cfg.LabDrive = $Drive.ToUpper() }
if (-not (Get-PSDrive -Name $cfg.LabDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR drive $($cfg.LabDrive): not found (LabDrive in lab.config.psd1 or -Drive)"
    exit 2
}

# ------------------------------------------------------------------------------
# plan: tylko odczyt, kod wyjscia 0 = wszystko gotowe / read-only, exit 0 = ready
# ------------------------------------------------------------------------------
function Step-Plan {
    $problems = [System.Collections.Generic.List[string]]::new()
    Write-Host "== Lab $($cfg.LabName): $($cfg.Nodes.Count) VM, HA stage $($cfg.Ogg.HaStage), OS $($cfg.Os.Profile)/$($cfg.Os.Kernel)"
    Write-Host "== Binaries in $($cfg.Binaries.Dir)"
    $bins = @(Get-BinaryStatus -Config $cfg)
    $bins | Format-Table Kind, Present, Version, Sha256Ok,
        @{ N = 'File'; E = { if (-not $_.File -and $_.Optional) { '(optional, not set)' } else { $_.File } } } -AutoSize |
        Out-String -Width 220 | Write-Host
    foreach ($b in $bins) {
        if (-not $b.Present) {
            # Opcjonalna paczka bez nazwy to nie brak / an optional package left empty is not missing
            if ($b.Optional -and -not $b.File) { continue }
            $problems.Add("missing $($b.Kind): $(if ($b.File) { $b.File } else { '(not set in lab.config.psd1)' })")
        }
        elseif ($b.Sha256Ok -eq $false) { $problems.Add("SHA-256 mismatch: $($b.File)") }
        elseif ($b.Problem) { $problems.Add($b.Problem) }
    }
    # Brak ISO nie blokuje: lab.cmd iso / all je pobiera (suma SHA-256 tam) / missing ISO does not block
    $os = Get-OsProfile
    if (Test-Path -LiteralPath (Join-Path $cfg.IsoDir $os.IsoFile)) { Write-Host "== ISO $($os.IsoFile) present (SHA-256 checked by lab.cmd iso / all)" }
    else { Write-Host "== WARN ISO $($os.IsoFile) not in $($cfg.IsoDir): lab.cmd iso downloads it (lab.cmd all does it first)" }
    Write-Host "== VMs (shared disks in $(Get-SharedDir))"
    $plan = @(Get-VmPlan -Config $cfg -SharedDir (Get-SharedDir))
    $plan | ForEach-Object {
        [pscustomobject]@{
            VM = $_.Name; Role = $_.Role; vCPU = $_.Cpu; RamMb = $_.Ram; OsDiskGb = $_.OsDiskMb / 1024
            NICs = ($_.Nics | ForEach-Object { "$($_.Type)$(if ($_.Target) { ":$($_.Target)" })" }) -join ' '
            Shared = ($_.SharedDisks | ForEach-Object { "$($_.Name)/$($_.SizeMb / 1024)G@p$($_.Port)" }) -join ' '
            State = Get-VmState -Name $_.Name
        }
    } | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    # Masked kickstarts only (no password): the real render happens in build
    foreach ($n in $cfg.Nodes) { Invoke-RenderKickstart -Config $cfg -Node $n.Name -RepoRoot $RepoRoot -Masked | Out-Null }
    Write-Host "== Kickstarts rendered without password: kickstart\out\"
    if (-not (Test-KsFirewallRule)) { Write-Host "== WARN no inbound firewall rule for TCP $($cfg.KsServer.Port) (kickstart server); build adds it (UAC)" }
    $t = Get-PlanTotals -Config $cfg
    $free = [math]::Floor((Get-PSDrive -Name $cfg.LabDrive).Free / 1GB)
    # Dyski OS rosna wg potrzeb (VDI dynamiczny); wspoldzielone RAC sa stale, bo VirtualBox daje typ
    # shareable tylko dyskom fixed: te zajmuja miejsce od razu.
    # OS disks grow as needed (dynamic VDI); RAC shared disks are fixed because VirtualBox allows the
    # shareable type only on fixed disks: those take their space at once.
    Write-Host ("== RAM {0} GB; disk: fixed now {1} GB (RAC shared), OS dynamic up to {2} GB, max {3} GB; free on {4}: {5} GB (min {6})" -f
        ($t.RamMb / 1024), $t.SharedGb, ($t.DiskGb - $t.SharedGb), $t.DiskGb, $cfg.LabDrive, $free, $cfg.MinFreeGb)
    if ($free -lt $cfg.MinFreeGb) {
        $msg = "free space on $($cfg.LabDrive): $free GB < $($cfg.MinFreeGb) GB"
        # SpaceCheck 'warn' (domyslnie): tylko ostrzezenie; 'error': blokuje / default warn only; 'error' blocks
        if ($cfg.SpaceCheck -eq 'error') { $problems.Add($msg) } else { Write-Host "== WARN $msg (SpaceCheck = warn)" }
    }
    $others = @(Get-OtherVmsOnLabNet)
    if ($others) { $problems.Add("running VMs of other labs on the lab network: $($others -join ', ')") }
    if ($problems.Count) {
        Write-Host "== NOT READY ($($problems.Count)):"
        $problems | ForEach-Object { Write-Host "   - $_" }
        return 1
    }
    Write-Host '== READY'
    0
}

function Get-SharedDir {
    $base = Join-Path "$($cfg.LabDrive):\" 'VMs'
    $mf = Get-VBoxMachineFolder
    if ($mf -and $mf.StartsWith("$($cfg.LabDrive):", 'OrdinalIgnoreCase')) { $base = $mf }
    Join-Path $base "$($cfg.LabName)-shared"
}
function Get-VmFolder { Split-Path -Parent (Get-SharedDir) }

# Wlaczone VM spoza labu z karta na adapterze 192.168.58.1 / running non-lab VMs on the lab adapter
function Get-OtherVmsOnLabNet {
    $adapter = Get-LabHostonlyAdapter -HostIp $cfg.Network.HostIp
    if (-not $adapter) { return @() }
    $vbox = Get-VBoxManagePath
    $ours = @($cfg.Nodes | ForEach-Object Name)
    foreach ($line in & $vbox list runningvms) {
        $name = ([regex]::Match($line, '^"(.+?)"')).Groups[1].Value
        if ($name -and $name -notin $ours) {
            $info = (& $vbox showvminfo $name --machinereadable) -join "`n"
            if ($info -match [regex]::Escape("hostonlyadapter1=`"$adapter`"")) { $name }
        }
    }
}

function Invoke-OrShow([string[]]$VBoxArgs) {
    if ($DryRun) { Write-Host "DRYRUN VBoxManage $($VBoxArgs -join ' ')"; return }
    Invoke-VBox @VBoxArgs
}

function Step-Net {
    if ($DryRun) { Write-Host "DRYRUN host-only adapter $($cfg.Network.HostIp)/$($cfg.Network.Netmask)"; return }
    $a = Initialize-LabNetwork -HostIp $cfg.Network.HostIp -Netmask $cfg.Network.Netmask
    Write-Ok "host-only: $a"
}

# Dyski wspoldzielone: fixed + shareable, tworzone raz / shared disks: fixed + shareable, created once
function New-SharedDisks([object[]]$Plan) {
    $dir = Get-SharedDir
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $disks = $Plan | Where-Object Role -eq 'rac' | Select-Object -First 1 -ExpandProperty SharedDisks
    foreach ($d in $disks) {
        if (Test-Path -LiteralPath $d.Path) { Write-Skip "shared disk exists: $($d.Path)"; continue }
        Invoke-OrShow @('createmedium', 'disk', '--filename', $d.Path, '--size', "$($d.SizeMb)", '--format', 'VDI', '--variant', 'Fixed')
        Invoke-OrShow @('modifymedium', 'disk', $d.Path, '--type', 'shareable')
    }
}

# Dodatki RAC do VM z New-LabVm: NIC3 intnet i dyski wspoldzielone / RAC extras for a VM from New-LabVm
function Add-VmExtras($Vm) {
    if ($Vm.Role -ne 'rac') { return }
    $nic3 = $Vm.Nics | Where-Object Index -eq 3
    Invoke-OrShow @('modifyvm', $Vm.Name, '--nic3', 'intnet', '--intnet3', $nic3.Target, '--nictype3', 'virtio')
    Invoke-OrShow @('storagectl', $Vm.Name, '--name', 'SATA', '--portcount', "$(2 + @($Vm.SharedDisks).Count)")
    foreach ($d in $Vm.SharedDisks) {
        Invoke-OrShow @('storageattach', $Vm.Name, '--storagectl', 'SATA', '--port', "$($d.Port)", '--device', '0',
            '--type', 'hdd', '--medium', $d.Path, '--mtype', 'shareable')
    }
}

# Regula musi wpuszczac port I podsiec labu; regula innego labu na tym porcie sie nie liczy
# The rule must allow the port AND the lab subnet; another lab's rule on this port does not count
function Test-KsFirewallRule {
    $port = "$($cfg.KsServer.Port)"
    $subnet = $cfg.Network.HostIp -replace '\.\d+$', '.0'
    [bool](Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue |
        Where-Object {
            ($_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -contains $port -and
            (Test-RemoteAllowsSubnet @(($_ | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress) $subnet)
        })
}
function Add-KsFirewallRule {
    if (Test-KsFirewallRule) { return }
    $subnet = ($cfg.Network.HostIp -replace '\.\d+$', '.0') + '/24'
    $cmd = "New-NetFirewallRule -DisplayName 'vbox-lab-ks-$($cfg.KsServer.Port)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($cfg.KsServer.Port) -RemoteAddress $subnet"
    if ($DryRun) { Write-Host "DRYRUN $cmd"; return }
    if (Test-Elevated) { Invoke-Expression $cmd | Out-Null }
    else { Start-Process pwsh -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', $cmd }
    if (-not (Test-KsFirewallRule)) { throw 'Firewall rule for the kickstart server was not created (UAC declined?)' }
}

# OS install of new VMs: real kickstart render, host KS server, boot line typed into the console.
# Rendered kickstarts (with the password) are deleted when the install ends, also on failure.
function Install-VmOs([object[]]$Vms) {
    $ksDir = Join-Path $RepoRoot 'kickstart\out'
    $port = $cfg.KsServer.Port
    if ($DryRun) {
        foreach ($vm in $Vms) { Write-Host "DRYRUN boot $($vm.Name) inst.ks=http://$($cfg.Network.HostIp):$port/kickstart/out/$($vm.Name).ks" }
        return
    }
    Get-LabPass | Out-Null
    Add-KsFirewallRule
    foreach ($vm in $Vms) { Invoke-RenderKickstart -Config $cfg -Node $vm.Name -RepoRoot $RepoRoot | Out-Null }
    Start-KsServer -RepoRoot $RepoRoot -LabName $cfg.LabName -BindIp $cfg.Network.HostIp -Port $port
    try {
        foreach ($vm in $Vms) {
            $n = $cfg.Nodes | Where-Object Name -eq $vm.Name
            Start-VmWithKickstart -VmName $vm.Name -KsUrl "http://$($cfg.Network.HostIp):$port/kickstart/out/$($vm.Name).ks" `
                -VmIp $n.PublicIp -VmHostname "$($n.Name).$($cfg.Network.Domain)" -Netmask $cfg.Network.Netmask -WindowType headless
        }
        foreach ($vm in $Vms) {
            $ip = ($cfg.Nodes | Where-Object Name -eq $vm.Name).PublicIp
            Wait-Ssh -IpAddress $ip -TimeoutMinutes 60
            # %post runs under set -e: a failed command leaves a VM that boots but lacks users, limits, tuning
            $node = $cfg.Nodes | Where-Object Name -eq $vm.Name
            if ((Invoke-Ssh -Node $node -Command "grep -q 'POST-INSTALL DONE' /root/ks-post.log" -AllowFail) -ne 0) {
                throw "[$($vm.Name)] kickstart %post did not finish (see /root/ks-post.log). Rebuild it: lab.cmd destroy $($vm.Name), then lab.cmd build"
            }
            Set-VmInstalled -Name $vm.Name
            Dismount-LabVmIso -Name $vm.Name
        }
    } finally {
        Stop-KsServer -LabName $cfg.LabName
        Remove-RenderedKickstart $ksDir
    }
}

# build: VMs, disks, NICs, then OS install for VMs created now. A VM that exists but never
# finished its install is not touched: the message says how to rebuild it.
function Step-Build {
    $plan = @(Get-VmPlan -Config $cfg -SharedDir (Get-SharedDir))
    $profiles = Import-PowerShellDataFile (Join-Path $RepoRoot 'host\os-profiles.psd1')
    $os = $profiles[$cfg.Os.Profile]
    $iso = Join-Path $cfg.IsoDir $os.IsoFile
    $adapter = if ($DryRun) { '<lab adapter>' } else { Initialize-LabNetwork -HostIp $cfg.Network.HostIp -Netmask $cfg.Network.Netmask }
    New-SharedDisks $plan
    $new = [System.Collections.Generic.List[object]]::new()
    foreach ($vm in $plan) {
        if (Test-VmExists -Name $vm.Name) {
            if (-not (Test-VmOwnedByLab -Name $vm.Name -LabName $cfg.LabName)) { throw "VM '$($vm.Name)' exists and is not tagged $($vm.Tag)" }
            if (-not (Test-VmInstalled -Name $vm.Name)) {
                throw "VM '$($vm.Name)' exists but its OS install never finished. Rebuild it: lab.cmd destroy $($vm.Name), then lab.cmd build"
            }
            Write-Skip "VM exists: $($vm.Name)"; continue
        }
        if ($DryRun) { Write-Host "DRYRUN New-LabVm $($vm.Name) ram=$($vm.Ram) cpu=$($vm.Cpu) disk=$($vm.OsDiskMb) iso=$iso" }
        else {
            New-LabVm -Name $vm.Name -LabName $cfg.LabName -Ram $vm.Ram -Cpu $vm.Cpu -DiskMb $vm.OsDiskMb `
                -HostonlyAdapter $adapter -IsoPath $iso -OsType $os.OsType -Folder (Get-VmFolder)
        }
        Add-VmExtras $vm
        $new.Add($vm)
    }
    if ($new.Count) { Install-VmOs $new.ToArray() }
}

function Step-Status {
    foreach ($n in $cfg.Nodes) { '{0,-8} {1,-15} {2}' -f $n.Name, $n.PublicIp, (Get-VmState -Name $n.Name) }
}
function Get-TargetNodes { @($cfg.Nodes | Where-Object { -not $Target -or $Target -eq 'all' -or $_.Name -eq $Target }) }
# ssh <vm>: interactive root shell on one lab VM (same key and options as the steps)
function Step-Ssh {
    $names = @($cfg.Nodes | ForEach-Object Name)
    if (-not $Target -or $Target -notin $names) { throw "lab.cmd ssh <vm>: one of $($names -join ', ')" }
    $n = $cfg.Nodes | Where-Object Name -eq $Target
    & ssh @sshOpts -o BatchMode=no "root@$($n.PublicIp)"
}
# start: powered-off VMs in config order (gginfra first: DNS and time); the whole lab then goes back to the base state
function Step-Start {
    foreach ($n in Get-TargetNodes) {
        if ((Get-VmState -Name $n.Name) -ne 'running') {
            if ($DryRun) { Write-Host "DRYRUN startvm $($n.Name) --type headless" } else { Start-LabVm -Name $n.Name }
        }
    }
    if (-not $Target -or $Target -eq 'all') { Invoke-LoggedStep baseline }
}
function Step-Stop {
    # Kolejnosc: cel, RAC, na koncu DNS / order: target, RAC, DNS last
    foreach ($n in (Get-TargetNodes | Sort-Object { @{ tgt = 0; rac = 1; infra = 2 }[$_.Role] })) {
        if ((Get-VmState -Name $n.Name) -eq 'running') { Invoke-OrShow @('controlvm', $n.Name, 'acpipowerbutton'); if (-not $DryRun) { Wait-VmPoweroff -Name $n.Name } }
    }
}
# shutdown: the whole lab down in order, every step waits for its state (host/Shutdown.psm1). Source GoldenGate goes
# first through agctl, otherwise CRS moves it to the other node (16.11: crsctl stop cluster -all moved GG, VIP and
# ACFS to ggrac2 and ggrac2 got no stop, CRS-4404). A failed step stops the sequence before the VMs (-Force: go on).
function Step-Shutdown {
    $runStart = Get-Date
    $rows = [System.Collections.Generic.List[object]]::new()
    $busy = @(Get-RunningTestProcesses)
    if ($busy.Count) {
        $msg = "test automation is running ($(@($busy | ForEach-Object { "$($_.Script) pid $($_.Pid)" }) -join ', '))"
        if (-not $Force) { throw "shutdown refused: $msg. Wait for the test to end, or lab.cmd shutdown -Force" }
        Write-Host "WARN ${msg}: going on (-Force)"
    }
    $state = @{}; $reach = @{}
    foreach ($n in $cfg.Nodes) {
        $state[$n.Name] = Get-VmState -Name $n.Name
        $reach[$n.Name] = $false
        if ($state[$n.Name] -ne 'running') { Write-Host "WARN $($n.Name): VM $($state[$n.Name]), its steps are skipped"; continue }
        if ($DryRun) { $reach[$n.Name] = $true; continue }
        if ((Invoke-Ssh -Node $n -Command 'true' -AllowFail) -eq 0) { $reach[$n.Name] = $true }
        else { Write-Host "WARN $($n.Name): VM running but no SSH, its steps are skipped" }
    }
    $failed = $null
    $rac = @(Get-RacNodes)
    foreach ($s in Get-ShutdownSteps -Config $cfg) {
        $t0 = Get-Date
        if ($s.Scope -eq 'vms') {
            if ($failed -and -not $Force) {
                $rows.Add([pscustomobject]@{ step = $s.Id; node = '-'; seconds = 0; result = 'skip'; detail = "not run: $($failed.step) failed" }); continue
            }
            Step-Stop
            $rows.Add([pscustomobject]@{ step = $s.Id; node = '-'; seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
                                         result = $(if ($DryRun) { 'dryrun' } else { 'ok' }); detail = $s.Title })
            continue
        }
        $node = if ($s.Scope -eq 'rac-first') { @(@($rac | Where-Object { $reach[$_.Name] }) + $rac)[0] }
                else { $cfg.Nodes | Where-Object Name -eq $s.Node }
        $why = $null
        if (-not $reach[$node.Name]) { $why = if ($state[$node.Name] -ne 'running') { "VM $($state[$node.Name])" } else { 'no SSH' } }
        if ($failed -and -not $Force) { $why = "not run: $($failed.step) failed" }
        if ($DryRun) {
            Write-Host "DRYRUN [$($node.Name)] $($s.Id): $($s.Title)$(if ($why) { "  ($why, would be skipped)" })"
            Write-Host "       $($s.Command)"
            $rows.Add([pscustomobject]@{ step = $s.Id; node = $node.Name; seconds = 0; result = $(if ($why) { 'skip' } else { 'dryrun' })
                                         detail = $(if ($why) { $why } else { $s.Title }) })
            continue
        }
        if ($why) {
            Write-Host "WARN [$($node.Name)] $($s.Id) skipped: $why"
            $rows.Add([pscustomobject]@{ step = $s.Id; node = $node.Name; seconds = 0; result = 'skip'; detail = $why }); continue
        }
        Write-Step "[$($node.Name)] $($s.Id): $($s.Title) (limit $($s.TimeoutSec) s)"
        $r = ConvertFrom-ShutdownResult -Lines @(Invoke-Ssh -Node $node -Command $s.Command -AllowFail -Capture)
        $row = [pscustomobject]@{ step = $s.Id; node = $node.Name; seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
                                  result = $r.Result; detail = $r.Detail }
        $rows.Add($row)
        if ($r.Result -notin 'ok', 'skip' -and -not $failed) {
            $failed = $row
            Write-Host "WARN [$($node.Name)] $($s.Id): $($r.Result) $($r.Detail)$(if ($Force) { ' (-Force: going on)' })"
        }
    }
    $total = [int]((Get-Date) - $runStart).TotalSeconds
    $text = ($rows | Format-Table step, node, seconds, result, detail -AutoSize -Wrap | Out-String -Width 200).TrimEnd()
    Write-Host $text
    if (-not $DryRun) {
        $dir = Join-Path $RepoRoot 'logs'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $f = Join-Path $dir ('shutdown_{0}.txt' -f $runStart.ToString('yyyyMMdd-HHmmss'))
        $head = "lab.cmd shutdown$(if ($Force) { ' -Force' }) $($runStart.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")), $total s"
        [IO.File]::WriteAllText($f, "$head`n$text`n", [Text.UTF8Encoding]::new($false))
        Write-Host "== report: $f"
    }
    if ($failed -and -not $Force) {
        throw "shutdown stopped at $($failed.step) on $($failed.node): $($failed.result) $($failed.detail). VMs left running: fix it, then lab.cmd shutdown (or -Force)"
    }
    Write-Host $(if ($DryRun) { '== DRYRUN shutdown: nothing was changed' } else { "== SHUTDOWN: lab powered off after $total s" })
}
function Step-Destroy {
    if (-not $Target) { throw "destroy needs a target: <vm name> or all" }
    $vbox = Get-VBoxManagePath
    $vms = foreach ($n in Get-TargetNodes) {
        if (Test-VmExists -Name $n.Name) {
            $info = (& $vbox showvminfo $n.Name --machinereadable) -join "`n"
            [pscustomobject]@{ Name = $n.Name; Description = ([regex]::Match($info, '(?m)^description="([^"]*)"')).Groups[1].Value }
        }
    }
    foreach ($name in Get-DestroyList -Vms @($vms) -LabName $cfg.LabName) {
        if ($DryRun) { Write-Host "DRYRUN remove $name"; continue }
        Remove-LabVm -Name $name -LabName $cfg.LabName
    }
}

# ------------------------------------------------------------------------------
# Guest scripts over SSH (key auth, host keys not kept: VMs are rebuilt often)
# ------------------------------------------------------------------------------
$sshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes',
             '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=20',
             '-o', 'LogLevel=ERROR', '-i', ($cfg.Ssh.KeyPath -replace '^~', $HOME))
$script:Synced = @{}
$script:BinStatus = $null

# Returns the exit code, or with -Capture the output lines (also echoed to the console).
function Invoke-Ssh {
    param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)][string]$Command, [switch]$AllowFail, [switch]$Capture)
    if ($Capture) {
        $out = @(& ssh @sshOpts "root@$($Node.PublicIp)" $Command 2>&1)
        $rc = $LASTEXITCODE
        $out | ForEach-Object { Write-Host "  [$($Node.Name)] $_" }
    } else {
        & ssh @sshOpts "root@$($Node.PublicIp)" $Command | Out-Host
        $rc = $LASTEXITCODE
    }
    if ($rc -ne 0 -and -not $AllowFail) { throw "[$($Node.Name)] exit $rc : $Command" }
    if ($Capture) { return , $out }
    $rc
}

# Copies lib.sh, the role scripts, sql/, ogg/ and the node's lab.env/hosts.env to /root/lab.
function Sync-Guest($Node) {
    if ($script:Synced[$Node.Name]) { return }
    if (-not $script:BinStatus) { $script:BinStatus = @(Get-BinaryStatus -Config $cfg) }
    $outDir = Write-GuestFiles -Config $cfg -Node $Node.Name -OutDir (Join-Path $RepoRoot 'guest\out') -RepoRoot $RepoRoot -Binaries $script:BinStatus
    $items = @((Join-Path $RepoRoot 'guest\lib.sh'), (Join-Path $RepoRoot 'guest\run_step.sh'), (Join-Path $RepoRoot "guest\$($Node.Role)")) +
             @(if ($Node.Role -ne 'infra') { Join-Path $RepoRoot 'guest\shared' }) +
             @(Get-ChildItem $outDir -File | ForEach-Object FullName) +
             @('sql', 'ogg' | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { Test-Path $_ })
    if ($DryRun) { Write-Host "DRYRUN [$($Node.Name)] scp $($items.Count) items -> /root/lab/"; $script:Synced[$Node.Name] = $true; return }
    Invoke-Ssh -Node $Node -Command 'mkdir -p /root/lab' | Out-Null
    & scp @sshOpts -q -r $items "root@$($Node.PublicIp):/root/lab/"
    if ($LASTEXITCODE -ne 0) { throw "scp guest -> $($Node.Name) failed" }
    # Safety net against CRLF from a non-LF checkout; .gitattributes keeps them LF already
    Invoke-Ssh -Node $Node -Command "find /root/lab -type f \( -name '*.sh' -o -name '*.env' -o -name '*.sql' -o -name '*.tmpl' -o -name '*.prm' -o -name '*.oby' \) -exec sed -i 's/\r$//' {} + && chmod 700 /root/lab/*.sh /root/lab/*/*.sh" | Out-Null
    $script:Synced[$Node.Name] = $true
}

# Runs /root/lab/<role>/<script> as root; -DryRun only prints (the VM may not exist yet).
function Invoke-Guest {
    param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)][string]$Script, [string]$Arguments = '', [switch]$AllowFail, [switch]$Capture,
          [string]$Dir)
    Sync-Guest $Node
    if (-not $Dir) { $Dir = $Node.Role }
    $cmd = "bash /root/lab/$Dir/$Script $Arguments".TrimEnd()
    if ($DryRun) { Write-Host "DRYRUN [$($Node.Name)] $cmd"; if ($Capture) { return , @() }; return 0 }
    Write-Step "[$($Node.Name)] $Script $Arguments"
    # run_step.sh detaches the step from this SSH session (setsid, output to a file) and follows it
    Invoke-Ssh -Node $Node -Command "bash /root/lab/run_step.sh $Dir/$Script $Arguments".TrimEnd() -AllowFail:$AllowFail -Capture:$Capture
}

# Oracle ZIPs to the first RAC node's stage dir; skipped when the size on the VM already matches.
function Copy-Binaries([object]$Node, [string[]]$Names, [string]$Owner) {
    $b = $cfg.Binaries
    foreach ($name in $Names) {
        if (-not $b[$name]) { Write-Skip "$name not set in lab.config.psd1"; continue }
        $local = Join-Path $b.Dir $b[$name]
        $remote = "$($cfg.Oracle.StageDir)/$(Get-StageName $b[$name])"
        if ($DryRun) { Write-Host "DRYRUN [$($Node.Name)] scp '$($b[$name])' -> $remote"; continue }
        if (-not (Test-Path -LiteralPath $local)) { throw "Missing file: $local (Binaries.Dir in lab.config.psd1)" }
        $size = (Get-Item -LiteralPath $local).Length
        $rsize = (& ssh @sshOpts "root@$($Node.PublicIp)" "stat -c %s '$remote' 2>/dev/null || echo 0") | Select-Object -Last 1
        if ("$rsize".Trim() -eq "$size") { Write-Skip "$($b[$name]) already on $($Node.Name)"; continue }
        Write-Step "scp $($b[$name]) ($([math]::Round($size / 1MB)) MB) -> $($Node.Name)"
        & scp @sshOpts -q $local "root@$($Node.PublicIp):$remote"
        if ($LASTEXITCODE -ne 0) { throw "scp $local failed" }
        Invoke-Ssh -Node $Node -Command "chown ${Owner}:oinstall '$remote' && chmod 664 '$remote'" | Out-Null
    }
}

function Get-RacNodes { @(Get-Nodes -Config $cfg -Role rac) }

function Step-Prereq { foreach ($n in Get-RacNodes) { Invoke-Guest $n '10_os_prereq.sh' | Out-Null } }

# udev on both nodes, then SSH equivalence for grid and oracle: keys from both nodes to both nodes.
function Step-Shared {
    $rac = Get-RacNodes
    foreach ($n in $rac) { Invoke-Guest $n '20_asm_udev.sh' | Out-Null }
    foreach ($user in 'grid', 'oracle') {
        $keys = foreach ($n in $rac) {
            Invoke-Guest $n '30_ssh_equivalence.sh' "keygen $user" -Capture | Where-Object { "$_" -like 'PUBKEY *' } | ForEach-Object { "$_".Substring(7) }
        }
        $remoteKeys = "/root/lab/keys_$user.txt"
        if (-not $DryRun) {
            $tmp = New-TemporaryFile
            [IO.File]::WriteAllText($tmp, (($keys -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
            foreach ($n in $rac) {
                & scp @sshOpts -q $tmp.FullName "root@$($n.PublicIp):$remoteKeys"
                if ($LASTEXITCODE -ne 0) { throw "scp keys -> $($n.Name) failed" }
            }
            Remove-Item $tmp -Force
        }
        foreach ($n in $rac) { Invoke-Guest $n '30_ssh_equivalence.sh' "authorize $user $remoteKeys" | Out-Null }
        foreach ($n in $rac) { Invoke-Guest $n '30_ssh_equivalence.sh' "verify $user" | Out-Null }
    }
}

function Step-Grid {
    $rac = Get-RacNodes
    $first = $rac[0]
    Copy-Binaries $first @('GridZip', 'GridRu', 'OPatch') 'grid'
    Invoke-Guest $first '40_install_grid.sh' 'stage' | Out-Null
    foreach ($n in $rac | Select-Object -Skip 1) { Invoke-Guest $n '40_install_grid.sh' 'cvuqdisk' | Out-Null }
    Invoke-Guest $first '40_install_grid.sh' 'install' | Out-Null
    foreach ($n in $rac) { Invoke-Guest $n '40_install_grid.sh' 'root' | Out-Null }
    # AHF/TFA arrives with root.sh: off right away, before config tools, db install and dbca
    foreach ($n in $rac) { Invoke-Guest $n '40_install_grid.sh' 'ahf' | Out-Null }
    Invoke-Guest $first '40_install_grid.sh' 'config' | Out-Null
    Invoke-Guest $first '40_install_grid.sh' 'fra' | Out-Null
    if ((Invoke-Guest $first '90_validate.sh' 'grid' -AllowFail) -ne 0) { throw 'grid validation failed (CHECK FAIL lines above)' }
}

# DB software from the first RAC node to both (runInstaller over SSH), root.sh on each node.
function Step-Db {
    $rac = Get-RacNodes
    $first = $rac[0]
    Copy-Binaries $first @('DbZip', 'DbRu', 'OPatch') 'oracle'
    Invoke-Guest $first '50_install_db.sh' 'stage' | Out-Null
    Invoke-Guest $first '50_install_db.sh' 'install' | Out-Null
    foreach ($n in $rac) { Invoke-Guest $n '50_install_db.sh' 'root' | Out-Null }
}
function Step-Dbca { Invoke-Guest (Get-RacNodes)[0] '60_create_db.sh' | Out-Null }
function Step-Services {
    $first = (Get-RacNodes)[0]
    Invoke-Guest $first '65_services.sh' | Out-Null
    if ((Invoke-Guest $first '90_validate.sh' 'db' -AllowFail) -ne 0) { throw 'db validation failed (CHECK FAIL lines above)' }
}
# Target: system, DB software, CDB tgtcdb with the demo schema, validation.
function Step-Tgt {
    $n = @(Get-Nodes -Config $cfg -Role tgt)[0]
    Invoke-Guest $n '10_os_prereq.sh' | Out-Null
    Copy-Binaries $n @('DbZip', 'DbRu', 'OPatch') 'oracle'
    foreach ($ph in 'stage', 'install', 'root') { Invoke-Guest $n '50_install_db.sh' $ph | Out-Null }
    Invoke-Guest $n '60_create_db.sh' | Out-Null
    if ((Invoke-Guest $n '90_validate.sh' 'db' -AllowFail) -ne 0) { throw 'ggtgt db validation failed (CHECK FAIL lines above)' }
}

# ACFS for the deployments: drivers and mount point on each node, volume + resource from the first.
function Step-Acfs {
    $rac = Get-RacNodes
    foreach ($n in $rac) { Invoke-Guest $n '70_acfs.sh' 'prep' | Out-Null }
    Invoke-Guest $rac[0] '70_acfs.sh' 'create' | Out-Null
    if ((Invoke-Guest $rac[0] '90_validate.sh' 'acfs' -AllowFail) -ne 0) { throw 'acfs validation failed (CHECK FAIL lines above)' }
}
# GoldenGate software local on every RAC node and on ggtgt; the target deployment is complete here.
function Step-Ogg {
    foreach ($n in Get-RacNodes) {
        Copy-Binaries $n @('OggZip', 'OggBundle') 'oracle'
        Invoke-Guest $n '80_install_ogg.sh' | Out-Null
    }
    $t = @(Get-Nodes -Config $cfg -Role tgt)[0]
    Copy-Binaries $t @('OggZip', 'OggBundle') 'oracle'
    Invoke-Guest $t '80_install_ogg.sh' | Out-Null
    Invoke-Guest $t '86_oggca_target.sh' | Out-Null
    if ((Invoke-Guest $t '90_validate.sh' 'ogg' -AllowFail) -ne 0) { throw 'ggtgt ogg validation failed (CHECK FAIL lines above)' }
}
# XAG, then the VIP (oggca binds the Service Manager to it), the source deployment, the XAG resource.
function Step-Xag {
    $first = (Get-RacNodes)[0]
    Copy-Binaries $first @('XagZip') 'grid'
    Invoke-Guest $first '85_install_xag.sh' | Out-Null
    Invoke-Guest $first '87_xag_register.sh' 'vip' | Out-Null
    Invoke-Guest $first '86_oggca_source.sh' | Out-Null
    Invoke-Guest $first '87_xag_register.sh' 'add' | Out-Null
    if ((Invoke-Guest $first '90_validate.sh' 'ogg' -AllowFail) -ne 0) { throw 'ogg validation failed (CHECK FAIL lines above)' }
}

# Replication: source side on the node that runs GoldenGate (first RAC node in the base state), then the target.
function Step-Oggconf {
    Invoke-Guest (Get-RacNodes)[0] '88_oggconf_source.sh' | Out-Null
    Invoke-Guest @(Get-Nodes -Config $cfg -Role tgt)[0] '88_oggconf_target.sh' | Out-Null
}

# Data fingerprints of both sides (shared/compare.sh) compared table by table.
function Get-DataCompare($Src, $Tgt) {
    $s = Invoke-Guest $Src 'compare.sh' -Dir shared -Capture
    $d = Invoke-Guest $Tgt 'compare.sh' -Dir shared -Capture
    @(Compare-CompareLines -Source $s -Target $d)
}
# Replication is asynchronous: repeat the comparison until all tables match or the time is up.
function Wait-DataMatch($Src, $Tgt, [int]$TimeoutSec = 180) {
    if ($DryRun) { Get-DataCompare $Src $Tgt | Out-Null; return @() }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $r = Get-DataCompare $Src $Tgt
        if ($r.Count -and -not @($r | Where-Object { -not $_.Match }).Count) { return $r }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    $r
}

# Full check: every validate section on both sides, then 60 s of load and a source = target comparison.
# baseline: back to the base state (stage A) after a restart or a failure test, data untouched. Target first (DP1
# needs its Receiver), then the source side (95_baseline.sh: services, XAG, ACFS, processes), then the validate
# checks without load. Phase durations -> logs/baseline_steps.csv (video: durations only, no dates on screen).
function Wait-SshUp([object]$Node, [int]$TimeoutSec) {
    $until = (Get-Date).AddSeconds($TimeoutSec)
    while ((Invoke-Ssh -Node $Node -Command 'true' -AllowFail) -ne 0) {
        if ((Get-Date) -gt $until) { throw "$($Node.Name) does not answer SSH within $TimeoutSec s" }
        Start-Sleep -Seconds 10
    }
}
function Write-BaselineLog([datetime]$RunStart, [object[]]$Rows) {
    if ($DryRun -or -not @($Rows).Count) { return }
    $dir = Join-Path $RepoRoot 'logs'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Join-Path $dir 'baseline_steps.csv'
    $run = $RunStart.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    @($Rows) | Select-Object @{ n = 'run_utc'; e = { $run } }, node, phase, seconds, action, detail |
        Export-Csv -Path $f -Append -Encoding utf8NoBOM
}
function Step-Baseline {
    $first = (Get-RacNodes)[0]
    $tgt = @(Get-Nodes -Config $cfg -Role tgt)[0]
    $runStart = Get-Date
    # After a failure test: a powered-off VM starts (T2, T3), the interconnect NIC of a RAC node goes up again (T7)
    foreach ($n in $cfg.Nodes) {
        if ((Get-VmState -Name $n.Name) -ne 'running') {
            if ($DryRun) { Write-Host "DRYRUN startvm $($n.Name) --type headless" } else { Start-LabVm -Name $n.Name }
        }
    }
    foreach ($n in Get-RacNodes) { Invoke-OrShow @('controlvm', $n.Name, 'setlinkstate3', 'on') }
    if (-not $DryRun) { foreach ($n in $cfg.Nodes) { Wait-SshUp $n 600 } }
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($n in $tgt, $first) {
            foreach ($r in @(ConvertFrom-BaselineLines -Node $n.Name -Lines @(Invoke-Guest $n '95_baseline.sh' -Capture))) { $rows.Add($r) }
        }
    } finally { Write-BaselineLog $runStart $rows.ToArray() }
    $failed = [System.Collections.Generic.List[string]]::new()
    if ((Invoke-Guest $first '90_validate.sh' 'grid db acfs ogg repl' -AllowFail) -ne 0) { $failed.Add("$($first.Name) checks") }
    if ((Invoke-Guest $tgt '90_validate.sh' 'db ogg repl' -AllowFail) -ne 0) { $failed.Add("$($tgt.Name) checks") }
    if ($rows.Count) { $rows | Format-Table node, phase, seconds, action, detail -AutoSize | Out-String | Write-Host }
    if ($failed.Count) { throw "baseline: $($failed -join '; ') (CHECK FAIL lines above)" }
    Write-Host $(if ($DryRun) { '== DRYRUN baseline: nothing was changed' } else { "== BASELINE: lab in the base state (stage A) after $([int]((Get-Date) - $runStart).TotalSeconds) s" })
}

function Step-Validate {
    $first = (Get-RacNodes)[0]
    $tgt = @(Get-Nodes -Config $cfg -Role tgt)[0]
    $failed = [System.Collections.Generic.List[string]]::new()
    if ((Invoke-Guest $first '90_validate.sh' 'grid db acfs ogg repl' -AllowFail) -ne 0) { $failed.Add("$($first.Name) checks") }
    if ((Invoke-Guest $tgt '90_validate.sh' 'db ogg repl' -AllowFail) -ne 0) { $failed.Add("$($tgt.Name) checks") }
    Invoke-Guest $first 'loadgen.sh' '10 60' -Dir shared | Out-Null
    $r = @(Wait-DataMatch $first $tgt 180)
    if (-not $DryRun) {
        $r | Format-Table Table, SourceRows, TargetRows, Missing, Match -AutoSize | Out-String | Write-Host
        if (-not $r.Count -or @($r | Where-Object { -not $_.Match }).Count) { $failed.Add('source and target data differ after 180 s') }
    }
    if ($failed.Count) { throw "validate: $($failed -join '; ')" }
    Write-Host $(if ($DryRun) { '== DRYRUN validate: nothing was checked' } else { '== VALID: lab in the base state (stage A)' })
}

# all: ISO first (download if missing), plan must be READY, then every build step in order;
# each step skips what is already done and gets its own row in logs/steps.csv (film A2).
function Step-All {
    Invoke-LoggedStep iso
    $ready = Step-Plan
    if ($ready -ne 0) {
        if (-not $DryRun) { throw 'plan is NOT READY (list above): fix it, then lab.cmd all' }
        Write-Host '== DRYRUN continues despite NOT READY'
    }
    Invoke-LoggedStep build; Invoke-LoggedStep infra; Invoke-LoggedStep prereq; Invoke-LoggedStep shared
    Invoke-LoggedStep grid; Invoke-LoggedStep db; Invoke-LoggedStep dbca; Invoke-LoggedStep services
    Invoke-LoggedStep tgt; Invoke-LoggedStep acfs; Invoke-LoggedStep ogg; Invoke-LoggedStep xag
    Invoke-LoggedStep oggconf; Invoke-LoggedStep validate
}

# Krok wewnatrz all z wlasnym wierszem steps.csv (start, koniec, wynik, proba)
# A step inside all with its own steps.csv row (start, end, result, attempt)
function Invoke-LoggedStep([string]$Name) {
    $start = Get-Date
    $res = 'error'
    try { & "Step-$Name"; $res = 'ok' } finally { Write-StepLog $Name $start $res }
}

function Get-OsProfile { (Import-PowerShellDataFile (Join-Path $RepoRoot 'host\os-profiles.psd1'))[$cfg.Os.Profile] }

# ISO jak w szablonie vbox-lab: brak = pobranie curl.exe (-C - wznawia), potem suma SHA-256 z os-profiles.psd1
# ISO as in the vbox-lab template: missing = curl.exe download (-C - resumes), then SHA-256 from os-profiles.psd1
function Step-Iso {
    $os = Get-OsProfile
    $iso = Join-Path $cfg.IsoDir $os.IsoFile
    if (Test-Path -LiteralPath $iso) {
        Write-Host "== ISO already there: $iso"
    } else {
        if ($DryRun) { Write-Host "  DRY  curl.exe -L -C - --fail -o $iso.part $($os.IsoUrl)"; return }
        New-Item -ItemType Directory -Force -Path $cfg.IsoDir | Out-Null
        Write-Host "== ISO downloading: $($os.IsoUrl)"
        & curl.exe -L -C - --fail -o "$iso.part" $os.IsoUrl
        if ($LASTEXITCODE -ne 0) { throw "ISO download failed (curl exit $LASTEXITCODE): put $($os.IsoFile) into $($cfg.IsoDir) by hand" }
        Move-Item -LiteralPath "$iso.part" -Destination $iso
    }
    $hash = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
    if ($hash -ne $os.Sha256.ToUpper()) { throw "ISO SHA-256 mismatch: $hash, expected $($os.Sha256) ($iso): delete it, then lab.cmd iso" }
    Write-Host '== ISO SHA-256 OK'
}

function Step-Infra {
    $n = @(Get-Nodes -Config $cfg -Role infra)[0]
    Invoke-Guest $n '10_dnsmasq.sh' | Out-Null
    Invoke-Guest $n '20_chrony.sh' | Out-Null
    if ((Invoke-Guest $n '90_validate.sh' -AllowFail) -ne 0) { throw "gginfra validation failed (CHECK FAIL lines above)" }
}

# Film A2: every build step with start, end, result and the attempt number -> logs/steps.csv
function Write-StepLog([string]$Step, [datetime]$Start, [string]$Result) {
    if ($DryRun -or $Step -in 'plan', 'status', 'ssh') { return }
    $dir = Join-Path $RepoRoot 'logs'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Join-Path $dir 'steps.csv'
    $n = if (Test-Path $f) { @(Import-Csv $f | Where-Object step -eq $Step).Count + 1 } else { 1 }
    $fmt = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"
    $row = '{0},{1},{2},{3},{4}' -f $Step, $Start.ToUniversalTime().ToString($fmt), [datetime]::UtcNow.ToString($fmt), $Result, $n
    if (-not (Test-Path $f)) { [IO.File]::WriteAllText($f, "step,start_utc,end_utc,result,attempt`n") }
    [IO.File]::AppendAllText($f, "$row`n")
}
$stepStart = Get-Date
$stepResult = 'error'
try {
# logs\STOP: stop a running build after the current step (lab.cmd all or a step list); remove the file to go on
if ($Verb -notin 'plan', 'status', 'ssh', 'start', 'stop', 'shutdown', 'destroy' -and (Test-Path (Join-Path $RepoRoot 'logs\STOP'))) {
    throw "logs\STOP exists: build steps are paused. Delete it to continue (lab.cmd $Verb)"
}
switch ($Verb) {
    'plan'    { exit (Step-Plan) }
    'net'     { Step-Net }
    'build'   { Step-Build }
    'infra'   { Step-Infra }
    'prereq'  { Step-Prereq }
    'shared'  { Step-Shared }
    'grid'    { Step-Grid }
    'db'      { Step-Db }
    'dbca'    { Step-Dbca }
    'services' { Step-Services }
    'tgt'     { Step-Tgt }
    'acfs'    { Step-Acfs }
    'ogg'     { Step-Ogg }
    'xag'     { Step-Xag }
    'oggconf' { Step-Oggconf }
    'validate' { Step-Validate }
    'all'     { Step-All }
    'status'  { Step-Status }
    'ssh'     { Step-Ssh }
    'start'   { Step-Start }
    'baseline' { Step-Baseline }
    'stop'    { Step-Stop }
    'shutdown' { Step-Shutdown }
    'destroy' { Step-Destroy }
    # Reserved verbs: say where the work is (exit 2), no stack trace
    'test'     { Write-Host "lab.cmd test: run one failure test with .\tests\run_test.ps1 -Test T<n> [-ApprovedBy <name>] [-Repeat N] (TESTS.md)"; exit 2 }
    'snapshot' { Write-Host 'lab.cmd snapshot: the base-state disk snapshot arrives with Task 12 (first build)'; exit 2 }
    'maa'      { Write-Host 'lab.cmd maa: stage B (NGINX in front of the Service Manager, MAA) waits for MOS KB101098 (Task 9)'; exit 2 }
    'iso'      { Step-Iso }
    default   { throw "Step '$Verb' is not implemented yet (see PLAN.md)" }
}
$stepResult = 'ok'
} finally { Write-StepLog $Verb $stepStart $stepResult }
