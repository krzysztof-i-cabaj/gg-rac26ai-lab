# ==============================================================================
# Tytul:        BootKickstart.psm1
# Opis:         Serce automatu: wlacza VM, czeka na menu ISO i "wpisuje" na klawiaturze
#               VM klawisz Tab oraz parametry startowe (inst.ks=...), a potem Enter.
#               Reszte robi instalator Linuksa wedlug pliku kickstart. Wait-Ssh czeka,
#               az zainstalowany system odpowie na porcie 22.
# Description [EN]: The heart of the automation: powers on the VM, waits for the ISO menu
#               and "types" Tab plus the boot parameters (inst.ks=...) and Enter on the
#               VM keyboard. The Linux installer does the rest from the kickstart file.
#               Wait-Ssh waits until the installed system answers on port 22.
#
# Autor:        KCB Kris
# Data:         2026-11-06
# Wersja:       3.0 (vbox-lab; czas oczekiwania i tryb okna z configu)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - VirtualBox 7.0+, Scancode.psm1, serwer KS na hoscie
# Requirements [EN]: - VirtualBox 7.0+, Scancode.psm1, KS server on the host
#
# Uzycie [PL]:       Start-VmWithKickstart -VmName gitlab1 -KsUrl http://192.168.56.1:8000/kickstart/out/gitlab1.ks -VmIp 192.168.56.70 -VmHostname gitlab1.lab.test
# Usage [EN]:        same as above
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Scancode.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'VmBuilder.psm1') -Force -DisableNameChecking

function Start-VmWithKickstart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$KsUrl,
        [Parameter(Mandatory)][string]$VmIp,
        [Parameter(Mandatory)][string]$VmHostname,
        [string]$Netmask = '255.255.255.0',
        [string]$NetDevice = 'enp0s3',
        [int]$BootMenuWaitSec = 10,
        [ValidateSet('headless', 'gui')][string]$WindowType = 'gui'
    )
    Write-Step "Rozruch / boot '$VmName' z kickstartem: $KsUrl"
    Start-LabVm -Name $VmName -Type $WindowType

    # Menu ISO czeka na wybor ok. 60 s, wiec dluzsze czekanie jest bezpieczne, a zbyt krotkie nie.
    # The ISO menu waits about 60 s, so a longer wait is safe and a too short one is not.
    Write-Log -Level Info -Message "Czekam $BootMenuWaitSec s na menu ISO / waiting for the ISO menu"
    Start-Sleep -Seconds $BootMenuWaitSec

    # Tab = edycja parametrow pierwszej pozycji menu / Tab = edit the first menu entry
    Send-VmTab -Vm $VmName
    Start-Sleep -Milliseconds 500

    # ip= bez bramy (puste pole): serwer KS jest w tej samej podsieci, a brama host-only
    # bylaby slepa i psula trase domyslna. / no gateway: the KS server is on the same subnet
    # and a host-only gateway would be a dead end that breaks the default route.
    $bootLine = " inst.ks=$KsUrl inst.text ip=${VmIp}:::${Netmask}:${VmHostname}:${NetDevice}:none"
    Write-Log -Level Debug -Message "Linia startowa / boot line: $bootLine"
    Send-VmString -Vm $VmName -Text $bootLine
    Start-Sleep -Milliseconds 500

    Send-VmEnter -Vm $VmName
    Write-Ok "Parametry wyslane, instalacja ruszyla / install started: $VmName"
}

function Wait-Ssh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [int]$TimeoutMinutes = 30,
        [int]$IntervalSec = 10
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log -Level Info -Message "Czekam max ${TimeoutMinutes} min na SSH ${IpAddress}:22 / waiting for SSH"
    while ((Get-Date) -lt $deadline) {
        $tcp = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect($IpAddress, 22, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(2000) -and $tcp.Connected) {
                $tcp.EndConnect($async)
                Write-Host ''
                Write-Ok "SSH odpowiada / SSH up: $IpAddress"
                return
            }
        } catch {
            # jeszcze nie / not yet
        } finally {
            if ($tcp) { $tcp.Close() }
        }
        Start-Sleep -Seconds $IntervalSec
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    throw "Brak SSH na ${IpAddress}:22 po ${TimeoutMinutes} min. Zobacz okno VM (Alt+F2 = konsola instalatora)."
}

Export-ModuleMember -Function 'Start-VmWithKickstart', 'Wait-Ssh'
