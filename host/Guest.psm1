# ==============================================================================
# Tytul:        Guest.psm1
# Opis:         Pliki dla skryptow na maszynach: lab.env (ustawienia z lab.config.psd1, bez
#               hasla) i hosts.env (rekordy DNS labu, SCAN jako 3 wiersze dla round-robin).
#               Zapis do guest/out/<wezel>/, konce linii LF.
# Description [EN]: Files for the guest scripts: lab.env (settings from lab.config.psd1, no
#               password) and hosts.env (lab DNS records, SCAN as 3 lines for round-robin).
#               Written to guest/out/<node>/ with LF endings.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.4 (sumy kontrolne w wyniku Compare-CompareLines; 1.3: render *.oby, Compare-CompareLines)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - PowerShell 7, host/Config.psm1 (Get-Nodes)
# Requirements [EN]: - PowerShell 7, host/Config.psm1 (Get-Nodes)
#
# Uzycie [PL]:       Write-GuestFiles -Config $c -Node gginfra -OutDir guest\out
# Usage [EN]:        Write-GuestFiles -Config $c -Node gginfra -OutDir guest\out
# ==============================================================================
Set-StrictMode -Version Latest

# hosts file format (ip fqdn short): the first name of a line is what dnsmasq returns for PTR.
function Get-LabHostsText([hashtable]$Config) {
    $d = $Config.Network.Domain
    $lines = foreach ($n in $Config.Nodes) { '{0,-15} {1}.{2}  {1}' -f $n.PublicIp, $n.Name, $d }
    $lines += foreach ($n in Get-Nodes -Config $Config -Role rac) {
        '{0,-15} {1}-vip.{2}  {1}-vip' -f $n.VipIp, $n.Name, $d
        '{0,-15} {1}-priv.{2}  {1}-priv' -f $n.PrivIp, $n.Name, $d
    }
    $lines += foreach ($ip in $Config.Network.ScanIps) { '{0,-15} {1}.{2}  {1}' -f $ip, $Config.Network.ScanName, $d }
    $lines += '{0,-15} {1}.{2}  {1}' -f $Config.Network.OggVip, $Config.Network.OggVipName, $d
    ($lines -join "`n") + "`n"
}

function Get-GuestVars([hashtable]$Config, [string]$Node, [object[]]$Binaries) {
    $n = @($Config.Nodes | Where-Object Name -eq $Node)
    if ($n.Count -ne 1) { throw "Unknown node: $Node" }
    $n = $n[0]
    $net = $Config.Network; $ora = $Config.Oracle; $ogg = $Config.Ogg
    $rac = @(Get-Nodes -Config $Config -Role rac)
    $prefix = ($net.HostIp -split '\.')[0..2] -join '.'
    $vars = [ordered]@{
        NODE_NAME = $n.Name; NODE_ROLE = $n.Role; NODE_IP = $n.PublicIp
        NODE_NUM = if ($n.Role -eq 'rac') { "$([array]::IndexOf(@($rac.Name), $n.Name) + 1)" } else { '' }
        LAB_DOMAIN = $net.Domain; HOST_IP = $net.HostIp; PUBLIC_SUBNET = "$prefix.0/24"; NETMASK = $net.Netmask
        INFRA_NAME = @(Get-Nodes -Config $Config -Role infra)[0].Name; INFRA_IP = @(Get-Nodes -Config $Config -Role infra)[0].PublicIp
        RAC_NODES = ($rac.Name -join ' '); RAC_IPS = ($rac.PublicIp -join ' '); RAC_VIPS = ($rac.VipIp -join ' ')
        RAC_PRIV_IPS = ($rac.PrivIp -join ' '); TGT_NAME = @(Get-Nodes -Config $Config -Role tgt)[0].Name
        TGT_IP = @(Get-Nodes -Config $Config -Role tgt)[0].PublicIp
        IC_SUBNET = $net.Interconnect.Subnet; IC_MASK = $net.Interconnect.Mask
        SCAN_NAME = $net.ScanName; SCAN_IPS = ($net.ScanIps -join ' '); OGG_VIP_NAME = $net.OggVipName; OGG_VIP = $net.OggVip
        CLUSTER_NAME = $ora.ClusterName; GRID_HOME = $ora.GridHome; DB_HOME = $ora.DbHome; STAGE_DIR = $ora.StageDir
        SRC_DB = $ora.SrcDb; SRC_PDB = $ora.SrcPdb; GG_SERVICE = $ora.GgService; LOAD_SERVICES = ($ora.LoadServices -join ' ')
        TGT_DB = $ora.TgtDb; TGT_PDB = $ora.TgtPdb; STREAMS_POOL_MB = "$($ora.StreamsPoolMb)"
        SRC_SGA_MB = "$($ora.SrcSgaMb)"; TGT_SGA_MB = "$($ora.TgtSgaMb)"
        OGG_HA_STAGE = $ogg.HaStage; OGG_HOME = $ogg.Home; XAG_HOME = $ogg.XagHome; OGG_DEPLOY_ROOT = $ogg.DeployRoot
        OGG_SM = $ogg.ServiceManager; OGG_SM_PORT = "$($ogg.SmPort)"; OGG_SRC_DEPLOY = $ogg.SourceDeployment
        OGG_TGT_DEPLOY = $ogg.TargetDeployment; ACFS_VOLUME = $ogg.AcfsVolume; ACFS_SIZE_GB = "$($ogg.AcfsSizeGb)"
        OGG_EXTRACT = $ogg.Extract; OGG_TRAIL = $ogg.Trail; OGG_PATH = $ogg.Path; OGG_REPLICAT = $ogg.Replicat
        OGG_CKPT_TABLE = $ogg.CheckpointTable
        GRID_BASE = '/u01/app/grid'; DB_BASE = '/u01/app/oracle'; INVENTORY = '/u01/app/oraInventory'
        OGG_ADMIN_USER = $ogg.AdminUser; OGG_PORT_ADMIN = "$($ogg.Ports.Admin)"; OGG_PORT_DIST = "$($ogg.Ports.Dist)"
        OGG_PORT_RECV = "$($ogg.Ports.Recv)"; OGG_PORT_PM = "$($ogg.Ports.Pm)"
        OGG_SM_HOME = "$($ogg.DeployRoot)/$($ogg.ServiceManager)"
        OGG_SRC_HOME = "$($ogg.DeployRoot)/$($ogg.SourceDeployment)"; OGG_TGT_HOME = "$($ogg.DeployRoot)/$($ogg.TargetDeployment)"
        # CRS names: ora.<diskgroup>.<volume>.acfs and ora.<db>.<service>.svc (lower case)
        ACFS_DG = 'DATA'   # the ACFS volume lives on +DATA (spec section 4)
        OGG_ACFS_RES = "ora.data.$($ogg.AcfsVolume.ToLower()).acfs"
        OGG_DB_SERVICE_RES = "ora.$($ora.SrcDb.ToLower()).$($ora.GgService.ToLower()).svc"
        # Stage A: the Service Manager binds to the application VIP name; stage B (MAA): 127.0.0.1 behind NGINX
        OGG_SM_HOST = if ($ogg.HaStage -eq 'B') { '127.0.0.1' } else { "$($net.OggVipName).$($net.Domain)" }
        # Distribution Path protocol: ws:// without TLS in stage A, wss:// in stage B (spec section 8)
        OGG_PATH_PROTO = if ($ogg.HaStage -eq 'B') { 'wss' } else { 'ws' }
        # adminclient CONNECT: source through the VIP (stage A: Service Manager port, B: NGINX 443)
        OGG_SRC_URL = if ($ogg.HaStage -eq 'B') { "https://$($net.OggVipName).$($net.Domain):443" } else { "http://$($net.OggVipName).$($net.Domain):$($ogg.SmPort)" }
        OGG_TGT_URL = "http://$(@(Get-Nodes -Config $Config -Role tgt)[0].Name).$($net.Domain):$($ogg.SmPort)"
        # gridSetup: node:vip pairs; public network type 1, interconnect type 5 (ASM + private)
        CLUSTER_NODES = (($rac | ForEach-Object { "$($_.Name):$($_.Name)-vip" }) -join ',')
        # runInstaller/dbca: RAC node list; DB_CLUSTER_NODES empty off RAC = single-instance software
        RAC_NODE_LIST = ($rac.Name -join ',')
        DB_CLUSTER_NODES = if ($n.Role -eq 'rac') { $rac.Name -join ',' } else { '' }
        # dbca -recoveryAreaSize: 85% of the +FRA disks / 85% of the +FRA disks
        FRA_SIZE_MB = "$([math]::Floor((($Config.SharedDisks | Where-Object DiskGroup -eq 'FRA' | Measure-Object SizeGb -Sum).Sum) * 1024 * 0.85))"
        NET_IF_LIST = "enp0s3:$prefix.0:1,enp0s9:$($net.Interconnect.Subnet):5"
        ASM_DISKS = (($Config.SharedDisks | ForEach-Object { "$($_.Name):$($_.SizeGb * 1024)" }) -join ' ')
        DATA_DISKS = (($Config.SharedDisks | Where-Object DiskGroup -eq 'DATA' | ForEach-Object { "/dev/oracleasm/$($_.Name)" }) -join ',')
        FRA_DISKS = (($Config.SharedDisks | Where-Object DiskGroup -eq 'FRA' | ForEach-Object { "/dev/oracleasm/$($_.Name)" }) -join ',')
    }
    # Binaries: stage names (spaces -> _) and RU ids read from the ZIPs by Get-BinaryStatus
    $b = $Config.Binaries
    $ids = @{}
    foreach ($s in @($Binaries)) { if ($s -and $s.Present) { $ids[$s.Name] = "$($s.Version)" } }
    foreach ($pair in @(('GRID_ZIP', 'GridZip'), ('GRID_RU_ZIP', 'GridRu'), ('DB_ZIP', 'DbZip'), ('DB_RU_ZIP', 'DbRu'),
                        ('OPATCH_ZIP', 'OPatch'), ('OGG_ZIP', 'OggZip'), ('OGG_BUNDLE_ZIP', 'OggBundle'), ('XAG_ZIP', 'XagZip'))) {
        $vars[$pair[0]] = if ($b[$pair[1]]) { Get-StageName $b[$pair[1]] } else { '' }
    }
    $vars.GRID_RU_ID = "$($ids['GridRu'])"; $vars.DB_RU_ID = "$($ids['DbRu'])"; $vars.OGG_VERSION = "$($ids['OggZip'])"
    $vars.OGG_AGCTL_ARGS = Get-AgctlAddArgs $vars
    $vars
}

# agctl add goldengate for Microservices (MAA 26ai Task 7, XAG 10.2), without --service_manager:
# 87_xag_register.sh adds it as 'yes' (MAA) or as a bare flag (XAG guide), whichever agctl accepts.
# One XAG resource = one Service Manager. The VIP comes from appvipcfg (87 vip), hence --vip_name.
function Get-AgctlAddArgs([System.Collections.IDictionary]$Vars) {
    $fs = $Vars.OGG_ACFS_RES
    # Stage B (MAA): the NGINX resource joins the file systems XAG waits for (Task 9)
    if ($Vars.OGG_HA_STAGE -eq 'B') { $fs = "$fs,nginx" }
    @(
        '--gg_home', $Vars.OGG_HOME
        '--config_home', "$($Vars.OGG_SM_HOME)/etc/conf"
        '--var_home', "$($Vars.OGG_SM_HOME)/var"
        '--port', $Vars.OGG_SM_PORT
        '--oracle_home', "$($Vars.OGG_HOME)/lib/instantclient"
        '--adminuser', $Vars.OGG_ADMIN_USER
        '--user', 'oracle', '--group', 'oinstall'
        '--vip_name', $Vars.OGG_VIP_NAME
        '--filesystems', $fs
        '--db_services', $Vars.OGG_DB_SERVICE_RES, '--use_local_services'
        '--nodes', $Vars.RAC_NODE_LIST
    ) -join ' '
}

function Get-GuestEnvText([hashtable]$Config, [string]$Node, [object[]]$Binaries) {
    $vars = Get-GuestVars $Config $Node $Binaries
    $lines = foreach ($k in $vars.Keys) {
        $v = "$($vars[$k])"
        if ($v -match "'") { throw "lab.env value for $k contains a quote: $v" }
        "$k='$v'"
    }
    "# Generated by lab.ps1 from lab.config.psd1. No secrets here (LAB_PASS: ~/.lab_secrets).`n" + ($lines -join "`n") + "`n"
}

# Response templates (response/*.rsp.tmpl, ogg/*.rsp.tmpl): {{VAR}} = a lab.env value.
# Passwords stay as @@LAB_PASS@@ and are filled on the VM by render_secret (lib.sh), 600 file.
function Get-RenderedRsp([string]$TemplatePath, [System.Collections.IDictionary]$Vars) {
    $t = [IO.File]::ReadAllText($TemplatePath) -replace "`r`n", "`n"
    foreach ($k in $Vars.Keys) { $t = $t.Replace("{{$k}}", "$($Vars[$k])") }
    if ($t -match '\{\{[A-Z_]+\}\}') { throw "Unresolved token $($Matches[0]) in $TemplatePath" }
    $t
}

function Write-GuestFiles {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Node, [Parameter(Mandatory)][string]$OutDir,
          [string]$RepoRoot, [object[]]$Binaries)
    $dir = Join-Path $OutDir $Node
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $enc = [Text.UTF8Encoding]::new($false)
    $vars = Get-GuestVars $Config $Node $Binaries
    [IO.File]::WriteAllText((Join-Path $dir 'lab.env'), (Get-GuestEnvText $Config $Node $Binaries), $enc)
    [IO.File]::WriteAllText((Join-Path $dir 'hosts.env'), (Get-LabHostsText $Config), $enc)
    if ($RepoRoot -and $vars.NODE_ROLE -ne 'infra') {
        foreach ($d in 'response', 'ogg') {
            $src = Join-Path $RepoRoot $d
            if (-not (Test-Path $src)) { continue }
            # *.rsp.tmpl -> *.rsp; obey files (*.oby) may carry {{VAR}} too (setup_path.oby)
            foreach ($f in @(Get-ChildItem $src -Filter '*.rsp.tmpl') + @(Get-ChildItem $src -Filter '*.oby')) {
                $name = $f.Name -replace '\.tmpl$', ''
                [IO.File]::WriteAllText((Join-Path $dir $name), (Get-RenderedRsp $f.FullName $vars), $enc)
            }
        }
    }
    $dir
}

# Lines "COMPARE <table> <rows> <hash>" from sql/10_compare.sql on both sides -> one object per table.
# Missing = source rows - target rows (positive: rows not on the target yet or lost).
function Compare-CompareLines([string[]]$Source, [string[]]$Target) {
    $parse = {
        param($lines)
        $h = [ordered]@{}
        foreach ($l in $lines) {
            if ("$l" -match '^\s*COMPARE\s+(\S+)\s+(\d+)\s+(\d+)\s*$') { $h[$Matches[1]] = @{ Rows = [long]$Matches[2]; Hash = $Matches[3] } }
        }
        $h
    }
    $s = & $parse $Source; $t = & $parse $Target
    foreach ($name in @($s.Keys) + @($t.Keys | Where-Object { -not $s.Contains($_) })) {
        $a = $s[$name]; $b = $t[$name]
        [pscustomobject]@{
            Table = $name
            SourceRows = if ($a) { $a.Rows } else { $null }
            TargetRows = if ($b) { $b.Rows } else { $null }
            Missing = if ($a -and $b) { $a.Rows - $b.Rows } else { $null }
            # SUM(ORA_HASH(all columns)) from sql/10_compare.sql, kept in compare.json as evidence (video)
            SourceHash = if ($a) { $a.Hash } else { $null }
            TargetHash = if ($b) { $b.Hash } else { $null }
            Match = [bool]($a -and $b -and $a.Rows -eq $b.Rows -and $a.Hash -eq $b.Hash)
        }
    }
}

# 95_baseline.sh lines "BASELINE <phase> <seconds> done|noop [details]" -> rows for logs/baseline_steps.csv (video)
function ConvertFrom-BaselineLines([string]$Node, [object[]]$Lines) {
    foreach ($l in @($Lines)) {
        if ("$l" -match '^\s*(?:\[[^\]]+\]\s*)?BASELINE\s+(\S+)\s+(\d+)\s+(done|noop)(?:\s+(.*?))?\s*$') {
            [pscustomobject][ordered]@{ node = $Node; phase = $Matches[1]; seconds = [int]$Matches[2]; action = $Matches[3]; detail = "$($Matches[4])" }
        }
    }
}

Export-ModuleMember -Function ConvertFrom-BaselineLines, Compare-CompareLines, Get-LabHostsText, Get-GuestVars, Get-AgctlAddArgs, Get-GuestEnvText, Get-RenderedRsp, Write-GuestFiles
