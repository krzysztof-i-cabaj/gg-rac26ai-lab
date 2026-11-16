# ==============================================================================
# Tytul:        VmPlan.psm1
# Opis:         Plan maszyn bez wywolan VBoxManage: karty sieciowe, dyski wspoldzielone
#               RAC, kolejnosc rozruchu, sumy RAM/dysku, lista VM do usuniecia (tylko
#               ze znacznikiem labu). Wykonanie planu jest w lab.ps1 (Step-Build).
# Description [EN]: VM plan without VBoxManage calls: NICs, RAC shared disks, boot order,
#               RAM/disk totals, destroy list (lab-tagged VMs only). lab.ps1 executes it.
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, host/Config.psm1
# Requirements [EN]: - PowerShell 7, host/Config.psm1
#
# Uzycie [PL]:       Get-VmPlan -Config $c -SharedDir D:\VMs\gg-rac26ai-shared
# Usage [EN]:        Get-VmPlan -Config $c -SharedDir D:\VMs\gg-rac26ai-shared
# ==============================================================================
Set-StrictMode -Version Latest

# SATA: port 0 = dysk OS, port 1 = DVD (jak w vbox-lab), dyski wspoldzielone od portu 2
# SATA: port 0 = OS disk, port 1 = DVD (as in vbox-lab), shared disks from port 2
$script:FirstSharedPort = 2

function Get-SharedDiskPath {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][hashtable]$Disk, [Parameter(Mandatory)][string]$SharedDir)
    Join-Path $SharedDir "$($Config.LabName)-$($Disk.Name).vdi"
}

function Get-VmPlan {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$SharedDir)
    foreach ($n in $Config.Nodes) {
        $nics = [System.Collections.Generic.List[object]]::new()
        $nics.Add([pscustomobject]@{ Index = 1; Type = 'hostonly'; Target = $Config.Network.HostIp })
        $nics.Add([pscustomobject]@{ Index = 2; Type = 'nat'; Target = '' })
        $shared = @()
        if ($n.Role -eq 'rac') {
            $nics.Add([pscustomobject]@{ Index = 3; Type = 'intnet'; Target = $Config.Network.Interconnect.Net })
            $port = $script:FirstSharedPort
            $shared = foreach ($d in $Config.SharedDisks) {
                [pscustomobject]@{
                    Name = $d.Name; DiskGroup = $d.DiskGroup; SizeMb = [int]$d.SizeGb * 1024; Port = $port++
                    Path = Get-SharedDiskPath -Config $Config -Disk $d -SharedDir $SharedDir
                }
            }
        }
        [pscustomobject]@{
            Name = $n.Name; Role = $n.Role; Ram = $n.Ram; Cpu = $n.Cpu; OsDiskMb = [int]$n.OsDiskGb * 1024
            Nics = $nics.ToArray(); SharedDisks = @($shared); Boot = @('disk', 'dvd')
            Tag = "vbox-lab:$($Config.LabName)"
        }
    }
}

function Get-PlanTotals {
    param([Parameter(Mandatory)][hashtable]$Config)
    $ram = ($Config.Nodes | Measure-Object -Property Ram -Sum).Sum
    $os = ($Config.Nodes | Measure-Object -Property OsDiskGb -Sum).Sum
    $sh = ($Config.SharedDisks | Measure-Object -Property SizeGb -Sum).Sum
    [pscustomobject]@{ RamMb = [int]$ram; DiskGb = [int]($os + $sh); SharedGb = [int]$sh }
}

# Tylko VM z opisem dokladnie "vbox-lab:<lab>" / only VMs described exactly "vbox-lab:<lab>"
function Get-DestroyList {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Vms, [Parameter(Mandatory)][string]$LabName)
    @($Vms | Where-Object { ([string]$_.Description).Trim() -eq "vbox-lab:$LabName" } | ForEach-Object Name)
}

Export-ModuleMember -Function Get-SharedDiskPath, Get-VmPlan, Get-PlanTotals, Get-DestroyList
