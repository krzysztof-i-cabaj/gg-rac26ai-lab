# ==============================================================================
# Tytul:        Kickstart.psm1
# Opis:         Render kickstartow OL9: base.ks.tmpl + sekcje roli (infra, rac, tgt), wartosci
#               z lab.config.psd1, zapis kickstart/out/<wezel>.ks z koncami LF. Tryb -Masked
#               (plan) nie wstawia hasla; prawdziwy render bierze je tylko z $env:LAB_PASS.
# Description [EN]: Renders OL9 kickstarts: base.ks.tmpl + role sections (infra, rac, tgt),
#               values from lab.config.psd1, writes kickstart/out/<node>.ks with LF endings.
#               -Masked (plan) inserts no password; a real render takes it from $env:LAB_PASS only.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.2 (THP madvise z preinstall 26ai; blokada jadra bez repozytoriow)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, host/Config.psm1 (Get-GgConfig, Get-Nodes)
# Requirements [EN]: - PowerShell 7, host/Config.psm1 (Get-GgConfig, Get-Nodes)
#
# Uzycie [PL]:       Invoke-RenderKickstart -Config $c -Node ggrac1 -RepoRoot . [-Masked] [-OutDir X]
# Usage [EN]:        Invoke-RenderKickstart -Config $c -Node ggrac1 -RepoRoot . [-Masked] [-OutDir X]
# ==============================================================================
Set-StrictMode -Version Latest

$script:MaskedPass = 'MASKED_LAB_PASS'

function Get-LabPass {
    $p = $env:LAB_PASS
    if (-not $p) { throw 'LAB_PASS is not set (see SETTINGS.md)' }
    # Letters, digits and _ only: safe inside kickstart quotes, sed and database clients.
    if ($p -notmatch '^[A-Za-z0-9_]{8,}$') { throw 'LAB_PASS must be at least 8 letters, digits or _ (no spaces, quotes or ;)' }
    $p
}

function Get-SshPublicKey([hashtable]$Config) {
    $path = $Config.Ssh.KeyPath -replace '^~', $HOME
    if (Test-Path "$path.pub") { return (Get-Content -Raw "$path.pub").Trim() }
    'SSH_KEY_CREATED_AT_BUILD'
}

# /etc/hosts lines: public names, VIPs, interconnect names, GoldenGate VIP. No SCAN.
function Get-HostsBlock([hashtable]$Config) {
    $d = $Config.Network.Domain
    $lines = foreach ($n in $Config.Nodes) { '{0,-15} {1}.{2}  {1}' -f $n.PublicIp, $n.Name, $d }
    $lines += foreach ($n in Get-Nodes -Config $Config -Role rac) { '{0,-15} {1}-vip.{2}  {1}-vip' -f $n.VipIp, $n.Name, $d }
    $lines += foreach ($n in Get-Nodes -Config $Config -Role rac) { '{0,-15} {1}-priv.{2}  {1}-priv' -f $n.PrivIp, $n.Name, $d }
    $lines += '{0,-15} {1}.{2}  {1}' -f $Config.Network.OggVip, $Config.Network.OggVipName, $d
    $lines -join "`n"
}

function Get-RoleSections([string]$Path) {
    $text = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $m = [regex]::Match($text, '(?s)#@@ PACKAGES\n(.*?)#@@ POST\n(.*)$')
    if (-not $m.Success) { throw "Role template without #@@ PACKAGES / #@@ POST markers: $Path" }
    @{ Packages = $m.Groups[1].Value.TrimEnd(); Post = $m.Groups[2].Value.TrimEnd() }
}

function Get-InfraIp([hashtable]$Config) { @(Get-Nodes -Config $Config -Role infra)[0].PublicIp }

function Invoke-RenderKickstart {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$OutDir,
        [switch]$Masked
    )
    $n = @($Config.Nodes | Where-Object Name -eq $Node)
    if ($n.Count -ne 1) { throw "Unknown node: $Node" }
    $n = $n[0]
    if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'kickstart\out' }
    $profiles = Import-PowerShellDataFile (Join-Path $RepoRoot 'host\os-profiles.psd1')
    $os = $profiles[$Config.Os.Profile]
    $net = $Config.Network
    $ora = $Config.Oracle
    $pass = if ($Masked) { $script:MaskedPass } else { Get-LabPass }
    $role = Get-RoleSections (Join-Path $RepoRoot "kickstart\role-$($n.Role).ks.tmpl")
    $prefix = ($net.HostIp -split '\.')[0..2] -join '.'
    $fqdn = "$($n.Name).$($net.Domain)"

    $nics = @("network --bootproto=static --device=enp0s3 --ip=$($n.PublicIp) --netmask=$($net.Netmask) --hostname=$fqdn --nodefroute --activate",
              'network --bootproto=dhcp --device=enp0s8 --activate')
    if ($n.Role -eq 'rac') {
        $nics += "network --bootproto=static --device=enp0s9 --ip=$($n.PrivIp) --netmask=$($net.Interconnect.Mask) --nodefroute --activate"
    }

    $repos = @(@($os.Repos) | ForEach-Object { "repo --name=$($_.Name) --baseurl=$($_.Url)" })
    if ($Config.Os.Kernel -eq 'uek') {
        $uek = $Config.Os.UekRepo
        $repos += "repo --name=ol9_$uek --baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/$uek/x86_64/"
        $kernelPkgs = 'kernel-uek'
    } else {
        $kernelPkgs = '-kernel-uek'
    }

    $swapGb = [math]::Min([math]::Max([math]::Floor($n.Ram / 1024), 1), 16)
    $parts = @('part /boot --fstype=xfs  --size=1024 --ondisk=sda', "part swap  --fstype=swap --size=$($swapGb * 1024) --ondisk=sda")
    if ($n.Role -eq 'infra') { $parts += 'part /     --fstype=xfs  --size=1 --grow --ondisk=sda' }
    else { $parts += 'part /     --fstype=xfs  --size=30720 --ondisk=sda', 'part /u01  --fstype=xfs  --size=1 --grow --ondisk=sda' }

    # rac and tgt resolve only through gginfra (SCAN round-robin); NetworkManager must not
    # replace resolv.conf with the NAT resolver. gginfra keeps NAT DNS as its upstream.
    $resolver = '# gginfra: resolver from NAT DHCP (dnsmasq upstream)'
    if ($n.Role -ne 'infra') {
        $resolver = @"
cat > /etc/NetworkManager/conf.d/90-lab-dns.conf <<'EOF'
[main]
dns=none
EOF
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
search $($net.Domain)
nameserver $(Get-InfraIp $Config)
EOF
"@
    }

    # ACFS/ADVM runs only on certified kernels (MOS KB129209): lock exactly what was installed.
    $kernelPost = '# no kernel lock outside RAC'
    if ($n.Role -eq 'rac') {
        $kernelPost = @'
# No repos: the resolver already points at gginfra, whose DNS starts only in step infra.
mapfile -t kpkgs < <(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 'kernel*')
dnf -y -q --disablerepo='*' versionlock add "${kpkgs[@]}"
'@
    }

    $sga = if ($n.Role -eq 'rac') { $ora.SrcSgaMb } else { $ora.TgtSgaMb }
    # Transparent HugePages: 26ai on UEK7+ wants madvise (install guide), set by the preinstall RPM. Not disabled.
    $tuning = @"
cat > /etc/sysctl.d/99-oracle-hugepages.conf <<'EOF'
vm.nr_hugepages = $([int]($sga / 2) + 64)
vm.hugetlb_shm_group = 54322
EOF
"@

    $racNames = @(Get-Nodes -Config $Config -Role rac | ForEach-Object Name)
    $map = [ordered]@{
        '{{NIC_LINES}}' = $nics -join "`n"; '{{OS_REPOS}}' = $repos -join "`n"; '{{PART_LINES}}' = $parts -join "`n"
        '{{KERNEL_PACKAGES}}' = $kernelPkgs; '{{ROLE_PACKAGES}}' = $role.Packages
        '{{RESOLVER_POST}}' = $resolver; '{{KERNEL_POST}}' = $kernelPost; '{{ROLE_POST}}' = $role.Post
        '{{ORACLE_TUNING}}' = $tuning
        '{{HOSTS_BLOCK}}' = Get-HostsBlock $Config; '{{SSH_PUBKEY}}' = Get-SshPublicKey $Config
        '{{NODE}}' = $n.Name; '{{ROLE}}' = $n.Role; '{{NODE_NUM}}' = "$([array]::IndexOf($racNames, $n.Name) + 1)"
        '{{HOST_IP}}' = $net.HostIp; '{{PUBLIC_SUBNET}}' = "$prefix.0/24"
        '{{KEYBOARD}}' = $Config.Os.Keyboard; '{{TIMEZONE}}' = $Config.Os.Timezone; '{{OS_URL}}' = $os.Url
        '{{GRID_HOME}}' = $ora.GridHome; '{{DB_HOME}}' = $ora.DbHome; '{{STAGE_DIR}}' = $ora.StageDir
        '{{SRC_DB}}' = $ora.SrcDb; '{{TGT_DB}}' = $ora.TgtDb
        '{{XAG_HOME}}' = $Config.Ogg.XagHome; '{{OGG_HOME}}' = $Config.Ogg.Home
        '{{LAB_PASS}}' = $pass
    }
    $t = [IO.File]::ReadAllText((Join-Path $RepoRoot 'kickstart\base.ks.tmpl')) -replace "`r`n", "`n"
    # Composite tokens first (they contain simple tokens), password last.
    foreach ($k in $map.Keys) { $t = $t.Replace($k, "$($map[$k])") }
    if ($t -match '\{\{[A-Z_]+\}\}') { throw "Unresolved kickstart token: $($Matches[0])" }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $out = Join-Path $OutDir "$($n.Name).ks"
    [IO.File]::WriteAllText($out, ($t -replace "`r", ''), [Text.UTF8Encoding]::new($false))
    $out
}

# Rendered kickstarts hold the password: removed once the install is over.
function Remove-RenderedKickstart([string]$Dir) {
    Get-ChildItem $Dir -Filter '*.ks' -ErrorAction SilentlyContinue | Remove-Item -Force
}

Export-ModuleMember -Function Get-LabPass, Invoke-RenderKickstart, Remove-RenderedKickstart, Get-HostsBlock
