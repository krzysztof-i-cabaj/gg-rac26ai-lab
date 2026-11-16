# ==============================================================================
# Tytul:        Config.psm1
# Opis:         Wczytanie i sprawdzenie lab.config.psd1: wymagane klucze, adresy w
#               192.168.58.0/24 bez powtorzen, nazwy PDB bez myslnika (OGG-08221).
# Description [EN]: Loads and validates lab.config.psd1: required keys, unique
#               addresses in the public subnet, PDB names without a dash (OGG-08221).
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7
# Requirements [EN]: - PowerShell 7
#
# Uzycie [PL]:       $c = Get-GgConfig -Path .\lab.config.psd1; Get-Nodes -Config $c -Role rac
# Usage [EN]:        $c = Get-GgConfig -Path .\lab.config.psd1; Get-Nodes -Config $c -Role rac
# ==============================================================================
Set-StrictMode -Version Latest

function Get-StageName([string]$File) { $File -replace ' ', '_' }

function Get-Nodes {
    param([Parameter(Mandatory)][hashtable]$Config, [ValidateSet('infra', 'rac', 'tgt', 'all')][string]$Role = 'all')
    # Wywolujacy opakowuje w @(...): przy jednym wezle PowerShell rozwija tablice
    # Callers wrap in @(...): PowerShell unrolls a single-element array
    @($Config.Nodes | Where-Object { $Role -eq 'all' -or $_.Role -eq $Role })
}

# Wszystkie adresy publiczne labu (wezly, VIP, SCAN, oggvip) / all public lab addresses
function Get-LabIpList {
    param([Parameter(Mandatory)][hashtable]$Config)
    $n = $Config.Network
    @(
        $n.HostIp
        foreach ($node in $Config.Nodes) { $node.PublicIp; if ($node.ContainsKey('VipIp')) { $node.VipIp } }
        $n.ScanIps
        $n.OggVip
    )
}

function Get-GgConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Config not found: $Path" }
    $c = Import-PowerShellDataFile -Path $Path
    foreach ($k in 'LabName', 'Os', 'Network', 'Nodes', 'SharedDisks', 'Binaries', 'Oracle', 'Ogg', 'Ssh') {
        if (-not $c.ContainsKey($k)) { throw "Config key missing: $k" }
    }
    foreach ($r in 'infra', 'rac', 'tgt') {
        $want = if ($r -eq 'rac') { 2 } else { 1 }
        $have = @(Get-Nodes -Config $c -Role $r).Count
        if ($have -ne $want) { throw "Config: expected $want node(s) with Role=$r, found $have" }
    }
    $ips = @(Get-LabIpList -Config $c)
    $dups = @($ips | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($dups) { throw "Config: duplicate address(es): $($dups -join ', ')" }
    $prefix = ($c.Network.HostIp -split '\.')[0..2] -join '.'
    $outside = @($ips | Where-Object { (($_ -split '\.')[0..2] -join '.') -ne $prefix })
    if ($outside) { throw "Config: address(es) outside $prefix.0/24: $($outside -join ', ')" }
    foreach ($k in 'SrcPdb', 'TgtPdb') {
        if ($c.Oracle[$k] -match '-') {
            throw "Config: Oracle.$k '$($c.Oracle[$k])' contains a dash - GoldenGate REGISTER EXTRACT fails with OGG-08221 / ORA-44004"
        }
    }
    if ($c.Ogg.HaStage -notin 'A', 'B') { throw "Config: Ogg.HaStage must be A or B" }
    if (-not $c.ContainsKey('SpaceCheck')) { $c.SpaceCheck = 'warn' }
    if ($c.SpaceCheck -notin 'warn', 'error') { throw "Config: SpaceCheck must be warn or error" }
    if ($c.LabDrive -notmatch '^[A-Za-z]$') { throw "Config: LabDrive must be a single drive letter, got '$($c.LabDrive)'" }
    if ($c.Os.Kernel -notin 'uek', 'rhck') { throw "Config: Os.Kernel must be uek or rhck" }
    $c
}

# Czy RemoteAddress reguly zapory wpuszcza podsiec labu (/24): Any, LocalSubnet albo dokladnie ta podsiec.
# Regula innego labu na tym samym porcie (np. 192.168.56.0/24) nie wystarcza (pierwsza budowa 15.11).
# Does a firewall rule's RemoteAddress let the lab subnet (/24) in: Any, LocalSubnet or exactly that subnet.
# Another lab's rule on the same port (e.g. 192.168.56.0/24) is not enough (first build 15.11).
function Test-RemoteAllowsSubnet([string[]]$Remote, [string]$Subnet) {
    foreach ($r in $Remote) {
        if ($r -in 'Any', 'LocalSubnet', '*') { return $true }
        if ($r -in "$Subnet/255.255.255.0", "$Subnet/24") { return $true }
    }
    $false
}

Export-ModuleMember -Function Get-StageName, Get-Nodes, Get-LabIpList, Get-GgConfig, Test-RemoteAllowsSubnet
