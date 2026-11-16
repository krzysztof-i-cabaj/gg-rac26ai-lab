# ==============================================================================
# Tytul:        Network.psm1
# Opis:         Siec host-only VirtualBox: szuka adaptera o adresie hosta z configu,
#               a gdy go nie ma, tworzy nowy (Windows pokaze okno UAC). DHCP wylaczone,
#               bo maszyny labu maja adresy statyczne z kickstartu.
# Description [EN]: VirtualBox host-only network: finds the adapter with the host IP
#               from the config, creates one when missing (Windows shows a UAC prompt).
#               DHCP off, because lab VMs get static addresses from the kickstart.
#
# Autor:        KCB Kris
# Data:         2026-11-06
# Wersja:       3.1 (naprawa adaptera, ktory po aktualizacji VirtualBoksa stracil adres)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - VirtualBox 7.0+
# Requirements [EN]: - VirtualBox 7.0+
#
# Uzycie [PL]:       $adapter = Initialize-LabNetwork -HostIp 192.168.56.1
# Usage [EN]:        $adapter = Initialize-LabNetwork -HostIp 192.168.56.1
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking

function Get-LabHostonlyAdapter {
    # Zwraca nazwe adaptera o danym adresie albo $null / returns the adapter name or $null
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostIp)
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { return $null }
    $name = $null
    foreach ($line in @(& $vbox list hostonlyifs)) {
        if ($line -match '^Name:\s*(.+)$') { $name = $Matches[1].Trim() }
        if ($line -match '^IPAddress:\s*(.+)$' -and $Matches[1].Trim() -eq $HostIp) { return $name }
    }
    return $null
}

function Get-LabBrokenAdapter {
    # Aktualizacja VirtualBoksa potrafi skasowac adres adaptera: zostaje 0.0.0.0 albo 169.254.x.
    # A VirtualBox update can wipe an adapter's address: 0.0.0.0 or 169.254.x is left.
    $name = $null
    foreach ($line in @(& (Get-VBoxManagePath) list hostonlyifs)) {
        if ($line -match '^Name:\s*(.+)$') { $name = $Matches[1].Trim() }
        if ($line -match '^IPAddress:\s*(0\.0\.0\.0|169\.254\.\S+)') { return $name }
    }
    return $null
}

function Initialize-LabNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostIp,
        [string]$Netmask = '255.255.255.0'
    )
    Write-Step "Siec / network: adapter host-only $HostIp"
    $vbox = Get-VBoxManagePath
    if (-not $vbox) { throw 'VBoxManage.exe not found.' }

    $name = Get-LabHostonlyAdapter -HostIp $HostIp
    if ($name) {
        Write-Ok "Adapter istnieje / exists: $name"
    } elseif ($name = Get-LabBrokenAdapter) {
        Write-Log -Level Warn -Message "Adapter stracil adres, przywracam $HostIp / adapter lost its address: $name"
        & $vbox hostonlyif ipconfig $name --ip $HostIp --netmask $Netmask | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Nie udalo sie ustawic adresu adaptera $name" }
        Write-Ok "Naprawiono / repaired: $name"
    } else {
        Write-Log -Level Info -Message 'Tworze adapter host-only (Windows moze zapytac o zgode) / creating adapter (UAC prompt possible)'
        $created = & $vbox hostonlyif create
        # Wynik / output: Interface 'VirtualBox Host-Only Ethernet Adapter #2' was successfully created
        $name = ([regex]::Match(($created -join ' '), "'([^']+)'")).Groups[1].Value
        if (-not $name) { throw "Nie odczytano nazwy adaptera z: $created" }
        & $vbox hostonlyif ipconfig $name --ip $HostIp --netmask $Netmask | Out-Null
        Write-Ok "Utworzono / created: $name"
    }
    # DHCP wylaczony: adresy sa statyczne / DHCP off: addresses are static
    & $vbox dhcpserver remove --ifname $name 2>$null | Out-Null
    return $name
}

Export-ModuleMember -Function 'Get-LabHostonlyAdapter', 'Initialize-LabNetwork'
