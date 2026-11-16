# ==============================================================================
# Tytul:        Binaries.psm1
# Opis:         Stan binariow Oracle w katalogu Binaries.Dir: obecnosc, suma SHA-256,
#               numer RU, wersja GoldenGate i OPatch oraz uklad ZIP-a XAG czytane z WNETRZA
#               ZIP-a (nazwy bywaja rozne).
# Description [EN]: Oracle binaries status in Binaries.Dir: presence, SHA-256, RU number,
#               GoldenGate and OPatch version and the XAG ZIP layout read from INSIDE the ZIP
#               (file names vary).
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7; Get-RuInfo przeniesiony z labu rac19c-2node-lab (T-158)
# Requirements [EN]: - PowerShell 7; Get-RuInfo ported from rac19c-2node-lab (T-158)
#
# Uzycie [PL]:       Get-BinaryStatus -Config $c | Format-Table
# Usage [EN]:        Get-BinaryStatus -Config $c | Format-Table
# ==============================================================================
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ZipEntries([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try { @($z.Entries | ForEach-Object FullName) } finally { $z.Dispose() }
}

# Katalog glowny ZIP-a = numer RU; GI ma <nr>/bundle.xml, DB ma <nr>/etc/config/inventory.xml
# ZIP top dir = RU number; GI has <nr>/bundle.xml, DB has <nr>/etc/config/inventory.xml
function Get-RuInfo([string]$Path, [ValidateSet('GI', 'DB')][string]$Kind) {
    $e = Get-ZipEntries $Path
    $tops = @($e | Where-Object { $_ -match '^\d+/' } | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    $id = if ($tops.Count -eq 1) { $tops[0] } else { '' }
    $marker = if ($Kind -eq 'GI') { "$id/bundle.xml" } else { "$id/etc/config/inventory.xml" }
    [pscustomobject]@{ Id = $id; Valid = [bool]($id -and ($e -contains $marker)) }
}

# Minimalny OPatch: readme RU DB 23.26.4 wymaga >= 12.2.0.1.53 (readme RU GI: >= 12.2.0.1.48)
# Minimum OPatch: the DB RU 23.26.4 readme requires >= 12.2.0.1.53 (GI RU readme: >= 12.2.0.1.48)
$script:OPatchMin = '12.2.0.1.53'

function Get-ZipText([string]$Path, [string]$Entry) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $e = $z.GetEntry($Entry)
        if (-not $e) { return $null }
        $r = [IO.StreamReader]::new($e.Open())
        try { $r.ReadToEnd() } finally { $r.Dispose() }
    } finally { $z.Dispose() }
}

# Porownanie liczbowe wersji z kropkami (12.2.0.1.100 > 12.2.0.1.53) / numeric dotted-version compare
function Test-VersionAtLeast([string]$Version, [string]$Min) {
    if ($Version -notmatch '^\d+(\.\d+)*$') { return $false }
    $a = @($Version -split '\.' | ForEach-Object { [int]$_ })
    $b = @($Min -split '\.' | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $y = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($x -ne $y) { return $x -gt $y }
    }
    $true
}

# Wersja GG z nazwy pliku (z kropkami) albo z nazwy release notes w ZIP-ie; brak pewnosci = '?'.
# Katalog komponentu OUI (oracle.oggcore.services/23.4.0.0.0) to NIE wydanie: paczka 23.26.4.0.2 go ma.
# GG version from the file name (dotted) or from the release notes name inside the ZIP; uncertain = '?'.
# The OUI component dir (oracle.oggcore.services/23.4.0.0.0) is NOT the release: the 23.26.4.0.2 package has it.
function Get-OggInfo([string]$Path) {
    $re = '23\.\d+(\.\d+){0,3}'
    $v = ([regex]::Match((Split-Path -Leaf $Path), $re)).Value
    if (-not $v) {
        $hit = Get-ZipEntries $Path | Where-Object { $_ -match '(?i)release-notes-23\.' } | Select-Object -First 1
        if ($hit) { $v = ([regex]::Match($hit, $re)).Value }
    }
    [pscustomobject]@{ Version = $(if ($v) { $v } else { '?' }) }
}

# OPatch: wersja z OPatch/version.txt w ZIP-ie, Valid = co najmniej OPatchMin
# OPatch: version from OPatch/version.txt in the ZIP, Valid = at least OPatchMin
function Get-OPatchInfo([string]$Path) {
    $t = Get-ZipText $Path 'OPatch/version.txt'
    $v = if ($t) { ([regex]::Match($t, 'OPATCH_VERSION:\s*(\d+(?:\.\d+)*)')).Groups[1].Value } else { '' }
    [pscustomobject]@{ Version = $v; Min = $script:OPatchMin; Valid = [bool]($v -and (Test-VersionAtLeast $v $script:OPatchMin)) }
}

# XAG: 85_install_xag.sh robi cd xag && ./xagsetup.sh, wiec xag/xagsetup.sh musi byc na gorze ZIP-a
# XAG: 85_install_xag.sh does cd xag && ./xagsetup.sh, so xag/xagsetup.sh must be at the top of the ZIP
function Get-XagInfo([string]$Path) {
    [pscustomobject]@{ Valid = [bool]((Get-ZipEntries $Path) -contains 'xag/xagsetup.sh') }
}

function Get-BinaryStatus {
    param([Parameter(Mandatory)][hashtable]$Config)
    $b = $Config.Binaries
    $kinds = [ordered]@{
        GridZip = 'GI base'; DbZip = 'DB base'; GridRu = 'GI RU'; DbRu = 'DB RU'; OPatch = 'OPatch'
        OggZip = 'GoldenGate'; OggBundle = 'GG bundle'; XagZip = 'XAG'
    }
    # OggBundle opcjonalny: OggZip z MOS to pelna instalacja (Kris 15.11) / optional: the MOS OggZip is a full install
    $optional = @('OggBundle')
    foreach ($name in $kinds.Keys) {
        $file = [string]$b[$name]
        $path = if ($file) { Join-Path $b.Dir $file } else { '' }
        $present = [bool]($path -and (Test-Path -LiteralPath $path))
        $shaOk = $null
        if ($present -and $b.Sha256.ContainsKey($name)) {
            $shaOk = ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $b.Sha256[$name].ToUpper())
        }
        $version = ''
        $problem = ''
        if ($present) {
            $version = switch ($name) {
                'GridRu' { (Get-RuInfo $path GI).Id }
                'DbRu'   { (Get-RuInfo $path DB).Id }
                'OggZip' { (Get-OggInfo $path).Version }
                'OPatch' {
                    $o = Get-OPatchInfo $path
                    if (-not $o.Valid) {
                        $problem = if ($o.Version) { "OPatch too old: $($o.Version) < $($o.Min) ($file)" }
                                   else { "OPatch ZIP without OPatch/version.txt: $file" }
                    }
                    $o.Version
                }
                'XagZip' {
                    if (-not (Get-XagInfo $path).Valid) { $problem = "XAG ZIP layout: no xag/xagsetup.sh at the top ($file)" }
                    ''
                }
                default  { ([regex]::Match($file, '23\.\d+(\.\d+){0,3}')).Value }
            }
        }
        [pscustomobject]@{
            Name = $name; Kind = $kinds[$name]; File = $file; Path = $path
            Present = $present; Sha256Ok = $shaOk; Version = $version
            Optional = ($name -in $optional); Problem = $problem
        }
    }
}

Export-ModuleMember -Function Get-ZipEntries, Get-ZipText, Test-VersionAtLeast, Get-RuInfo, Get-OggInfo, Get-OPatchInfo,
    Get-XagInfo, Get-BinaryStatus
