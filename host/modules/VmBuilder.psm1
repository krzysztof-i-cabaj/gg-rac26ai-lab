# ==============================================================================
# Tytul:        VmBuilder.psm1
# Opis:         Tworzenie, start, zatrzymanie i usuwanie VM przez VBoxManage. Kazda VM
#               dostaje znacznik "vbox-lab:<nazwa labu>" w opisie: tylko tak oznaczone
#               maszyny wolno temu labowi usunac. Dwie karty sieciowe: host-only
#               (enp0s3, staly adres) i NAT (enp0s8, internet do pobierania pakietow).
# Description [EN]: VM create/start/stop/remove via VBoxManage. Each VM carries a
#               "vbox-lab:<lab name>" tag in its description: only tagged machines may be
#               removed by this lab. Two NICs: host-only (enp0s3, fixed address) and
#               NAT (enp0s8, internet for packages).
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       3.2 (ponawianie przy chwilowej blokadzie sesji VBoxSVC)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - VirtualBox 7.0+, adapter host-only (Network.psm1)
# Requirements [EN]: - VirtualBox 7.0+, host-only adapter (Network.psm1)
#
# Uzycie [PL]:       New-LabVm -Name gitlab1 -LabName gitlab-lab -Ram 10240 -Cpu 4 -DiskMb 81920 ...
#                    Remove-LabVm -Name gitlab1 -LabName gitlab-lab
# Usage [EN]:        same as above
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

# Porty SATA: 0 = dysk systemowy, 1 = DVD z ISO / SATA ports: 0 = OS disk, 1 = ISO DVD
$script:DvdPort = 1

# VBoxSVC zwalnia blokade sesji z opoznieniem: ile razy i co ile ponawiac polecenie.
# VBoxSVC releases the session lock with a delay: how many repeats and how far apart.
$script:LockRetries = 5
$script:LockRetryDelayMs = 2000

function Invoke-VBox {
    # Kazde polecenie zmieniajace stan: blad VBoxManage konczy krok z pelnym komunikatem.
    # Wyjatek: "already locked for a session (or being unlocked)" zaraz po poprzednim poleceniu
    # na tej samej VM. Polecenie nic wtedy nie zmienilo, wiec czekamy i ponawiamy.
    # Every state-changing command: a VBoxManage error stops the step with the full message.
    # Exception: "already locked for a session (or being unlocked)" right after the previous
    # command on the same VM. Nothing was changed then, so wait and repeat.
    $vbox = Get-VBoxManagePath
    foreach ($try in 0..$script:LockRetries) {
        $out = & $vbox @args 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        $text = ($out | ForEach-Object { "$_" }) -join ' '
        if ($try -lt $script:LockRetries -and $text -match 'already locked for a session') {
            Write-Log -Level Warn -Message "VBoxManage $($args[0]) $($args[1]): blokada sesji, ponawiam / session lock, retrying ($($try + 1)/$script:LockRetries)"
            Start-Sleep -Milliseconds $script:LockRetryDelayMs
            continue
        }
        throw "VBoxManage $($args[0]) $($args[1]): $text"
    }
}

function Test-VmExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { return $false }
    return [bool](@(& $vbox list vms) | Where-Object { $_ -like "`"$Name`" *" })
}

function Get-VmState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-VmExists -Name $Name)) { return 'absent' }
    $info = (& (Get-VBoxManagePath) showvminfo $Name --machinereadable) -join "`n"
    return ([regex]::Match($info, '(?m)^VMState="(.+?)"')).Groups[1].Value
}

function Test-VmOwnedByLab {
    # Czy VM ma znacznik tego labu / does the VM carry this lab's tag
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$LabName)
    $info = (& (Get-VBoxManagePath) showvminfo $Name --machinereadable) -join "`n"
    return $info.Contains("vbox-lab:$LabName")
}

function Set-VmInstalled {
    # Znacznik "system zainstalowany": odroznia gotowa maszyne od niedokonczonej.
    # "OS installed" marker: tells a finished machine from an unfinished one.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Invoke-VBox setextradata $Name 'vbox-lab/installed' '1'
}

function Test-VmInstalled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return [bool]((& (Get-VBoxManagePath) getextradata $Name 'vbox-lab/installed') -match 'Value: 1')
}

function Clear-LabVmLeftovers {
    # Resztki po nieudanej budowie: katalog i dysk bez zarejestrowanej VM. Bez tego createvm
    # konczy sie bledem "already exists". Cudzych plikow nie ruszamy.
    # Leftovers of a failed build: folder and disk without a registered VM. Without this
    # createvm fails with "already exists". Files of others are left alone.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$LabName, [string]$Folder = '')
    $base = if ($Folder) { $Folder } else { Get-VBoxMachineFolder }
    $dir = [IO.Path]::Combine($base, $Name)
    if (-not (Test-Path $dir)) { return }
    $vboxFiles = @(Get-ChildItem $dir -File -Filter '*.vbox*')
    $ours = @($vboxFiles | Where-Object { (Get-Content -Raw $_.FullName).Contains("vbox-lab:$LabName") }).Count -gt 0
    $other = @(Get-ChildItem $dir -File | Where-Object { $_.Name -notlike '*.vbox*' -and $_.Name -ne "$Name-os.vdi" })
    if (-not $ours -and ($vboxFiles.Count -gt 0 -or $other.Count -gt 0)) {
        throw "Katalog $dir istnieje i nie wyglada na ten lab. Przenies go albo zmien Nodes.Name."
    }
    Write-Log -Level Warn -Message "Usuwam resztki po nieudanej budowie: $dir"
    $vdi = Join-Path $dir "$Name-os.vdi"
    # Dysk moze zostac w rejestrze VirtualBox / the disk may stay in the VirtualBox registry
    & (Get-VBoxManagePath) closemedium disk $vdi --delete 2>$null | Out-Null
    Remove-Item -LiteralPath $dir -Recurse -Force
}

function Get-VBoxMachineFolder {
    (& (Get-VBoxManagePath) list systemproperties | Select-String 'Default machine folder' |
        ForEach-Object { ($_ -split ':\s+', 2)[1].Trim() })
}

function New-LabVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LabName,
        [Parameter(Mandatory)][int]$Ram,
        [Parameter(Mandatory)][int]$Cpu,
        [Parameter(Mandatory)][int]$DiskMb,
        [Parameter(Mandatory)][string]$HostonlyAdapter,
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$OsType,
        [string]$Folder = ''
    )
    $vbox = Get-VBoxManagePath
    Write-Step "VM '$Name': RAM ${Ram} MB, vCPU $Cpu, dysk / disk ${DiskMb} MB"
    if (Test-VmExists -Name $Name) { throw "VM '$Name' juz istnieje: Step-Build powinien ja obsluzyc." }
    Clear-LabVmLeftovers -Name $Name -LabName $LabName -Folder $Folder

    $create = @('createvm', '--name', $Name, '--ostype', $OsType, '--register')
    if ($Folder) { $create += @('--basefolder', $Folder) }
    Invoke-VBox @create

    # Rozruch: DYSK przed DVD. Pusty dysk -> instalator z DVD, po instalacji system z dysku.
    # Odwrotna kolejnosc to petla instalacji. paravirt kvm = stabilny zegar gosci Linux.
    # Boot: DISK before DVD. Empty disk -> installer from DVD, afterwards the installed OS.
    # The reverse order loops the install. paravirt kvm = stable clock for Linux guests.
    Invoke-VBox modifyvm $Name `
        --description "vbox-lab:$LabName" `
        --memory $Ram --cpus $Cpu `
        --nic1 hostonly --hostonlyadapter1 $HostonlyAdapter --nictype1 virtio `
        --nic2 nat --nictype2 virtio `
        --boot1 disk --boot2 dvd --boot3 none --boot4 none `
        --ioapic on --rtcuseutc on --paravirtprovider kvm `
        --graphicscontroller vmsvga --vram 16 `
        --audio-driver none --usb off

    $cfgLine = & $vbox showvminfo $Name --machinereadable | Where-Object { $_ -like 'CfgFile=*' }
    $vmDir = Split-Path -Parent (([regex]::Match($cfgLine, 'CfgFile="(.+)"')).Groups[1].Value -replace '\\\\', '\')
    $vdi = Join-Path $vmDir "$Name-os.vdi"

    Invoke-VBox createmedium disk --filename $vdi --size $DiskMb --format VDI
    Invoke-VBox storagectl $Name --name SATA --add sata --controller IntelAhci --portcount 2
    Invoke-VBox storageattach $Name --storagectl SATA --port 0 --type hdd --medium $vdi --nonrotational on
    Invoke-VBox storageattach $Name --storagectl SATA --port $script:DvdPort --type dvddrive --medium $IsoPath
    Write-Ok "Utworzono VM / created: $Name ($vdi)"
}

function Sync-VmAdapter {
    # Po aktualizacji VirtualBoksa adres sieci labu moze trafic na inny adapter.
    # After a VirtualBox update the lab network address may land on another adapter.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Adapter)
    $info = (& (Get-VBoxManagePath) showvminfo $Name --machinereadable) -join "`n"
    $current = ([regex]::Match($info, '(?m)^hostonlyadapter1="(.+?)"')).Groups[1].Value
    if ($current -eq $Adapter) { return }
    Write-Log -Level Warn -Message "$Name przepinam na adapter / moving to adapter: $Adapter"
    if ((Get-VmState -Name $Name) -eq 'running') { Invoke-VBox controlvm $Name nic1 hostonly $Adapter }
    else { Invoke-VBox modifyvm $Name --hostonlyadapter1 $Adapter }
}

function Dismount-LabVmIso {
    # Dziala takze na wlaczonej VM / works on a running VM as well
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    & (Get-VBoxManagePath) storageattach $Name --storagectl SATA --port $script:DvdPort --type dvddrive `
        --medium emptydrive --forceunmount 2>$null | Out-Null
    Write-Ok "Odpieto ISO / ISO detached: $Name"
}

function Start-LabVm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('headless', 'gui')][string]$Type = 'headless')
    Invoke-VBox startvm $Name --type $Type
    Write-Ok "Start VM: $Name ($Type)"
}

function Wait-VmPoweroff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VmState -Name $Name) -eq 'poweroff') { Write-Ok "$Name wylaczona / powered off"; return }
        Start-Sleep -Seconds 3
    }
    throw "VM '$Name' nie wylaczyla sie w ${TimeoutSec} s"
}

function Remove-LabVm {
    # Usuwa WYLACZNIE VM z znacznikiem tego labu. VM o tej samej nazwie, ale bez znacznika,
    # to cudza maszyna: odmowa. / Removes ONLY VMs tagged for this lab; refuses any other.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$LabName)
    $vbox = Get-VBoxManagePath
    if (-not (Test-VmExists -Name $Name)) { Write-Skip "VM '$Name' nie istnieje / absent"; return }
    if (-not (Test-VmOwnedByLab -Name $Name -LabName $LabName)) {
        throw "VM '$Name' nie ma znacznika vbox-lab:$LabName — to nie jest maszyna tego labu, nie usuwam."
    }
    if ((Get-VmState -Name $Name) -in 'running', 'paused') {
        & $vbox controlvm $Name poweroff 2>$null | Out-Null
        Wait-VmPoweroff -Name $Name -TimeoutSec 60
    }
    # Okno VM moze chwile trzymac blokade po wylaczeniu, stad kilka prob.
    # The VM window may hold its lock briefly after power-off, hence a few attempts.
    $folder = Split-Path -Parent (Split-Path -Parent (([regex]::Match(((& $vbox showvminfo $Name --machinereadable) -join "`n"), '(?m)^CfgFile="(.+)"')).Groups[1].Value -replace '\\\\', '\\'))
    foreach ($try in 1..5) {
        & $vbox unregistervm $Name --delete 2>$null | Out-Null
        if (-not (Test-VmExists -Name $Name)) { break }
        Start-Sleep -Seconds 3
    }
    if (Test-VmExists -Name $Name) { throw "VM '$Name' nie dala sie usunac. Zamknij jej okno i powtorz." }
    Clear-LabVmLeftovers -Name $Name -LabName $LabName -Folder $folder
    Write-Ok "Usunieto VM / removed: $Name"
}

Export-ModuleMember -Function 'Invoke-VBox', 'Test-VmExists', 'Get-VmState', 'Test-VmOwnedByLab', 'Get-VBoxMachineFolder', `
    'Set-VmInstalled', 'Test-VmInstalled', 'Clear-LabVmLeftovers', `
    'New-LabVm', 'Sync-VmAdapter', 'Dismount-LabVmIso', 'Start-LabVm', 'Wait-VmPoweroff', 'Remove-LabVm'
