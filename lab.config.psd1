# ==============================================================================
# Tytul:        lab.config.psd1
# Opis:         Cala konfiguracja labu GoldenGate 26ai + RAC 26ai: maszyny, siec,
#               dyski, binaria Oracle, nazwy baz i obiektow GoldenGate.
# Description [EN]: Whole lab configuration: VMs, network, disks, Oracle binaries,
#               database and GoldenGate object names.
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czytany przez lab.ps1 (host/Config.psm1 sprawdza poprawnosc)
# Requirements [EN]: - read by lab.ps1 (host/Config.psm1 validates it)
#
# Uzycie [PL]:       zmien wartosci, potem .\lab.cmd plan
# Usage [EN]:        edit values, then .\lab.cmd plan
# ==============================================================================
@{
    LabName = 'gg-rac26ai'
    # Dysk na maszyny: dowolna litera, tez z linii polecen (-Drive E) / any drive letter, also via -Drive E
    LabDrive    = 'D'
    MinFreeGb   = 300
    # 'warn' = brak miejsca tylko ostrzega (Kris 14.11); 'error' = plan zglasza NOT READY
    SpaceCheck  = 'warn'
    IsoDir      = 'D:\ISOs'         # katalog ISO (krok iso pobiera brakujace) / ISO dir

    Os = @{
        Profile = 'ol9'          # host\os-profiles.psd1
        # Jadro: 'uek' albo 'rhck' - ustalic wg MOS KB129209 (ACFS) przed budowa
        # Kernel: 'uek' or 'rhck' - decide from MOS KB129209 (ACFS) before building
        Kernel  = 'uek'
        # Repozytorium UEK dla Kernel='uek' (UEKR7 albo UEKR8, tez wg KB129209) / UEK repo for Kernel='uek'
        UekRepo  = 'UEKR8'
        Keyboard = 'pl'
        Timezone = 'Europe/Warsaw'
    }

    # Serwer kickstartu na hoscie, dziala tylko w czasie build / host kickstart server, build only
    KsServer = @{ Port = 8000 }

    Network = @{
        Domain     = 'gg.lab.test'
        HostIp     = '192.168.58.1'
        Netmask    = '255.255.255.0'
        ScanName   = 'ggrac-scan'
        ScanIps    = @('192.168.58.31', '192.168.58.32', '192.168.58.33')
        OggVipName = 'oggvip'
        OggVip     = '192.168.58.40'
        Interconnect = @{ Net = 'ggrac-ic'; Subnet = '10.58.0.0'; Mask = '255.255.255.0' }
    }

    # Role: infra (DNS + NTP), rac (wezel klastra), tgt (cel replikacji)
    Nodes = @(
        @{ Name = 'gginfra'; Role = 'infra'; PublicIp = '192.168.58.10'; Cpu = 1; Ram = 2048;  OsDiskGb = 20 }
        @{ Name = 'ggrac1';  Role = 'rac';   PublicIp = '192.168.58.11'; VipIp = '192.168.58.21'; PrivIp = '10.58.0.11'; Cpu = 3; Ram = 14336; OsDiskGb = 100 }
        @{ Name = 'ggrac2';  Role = 'rac';   PublicIp = '192.168.58.12'; VipIp = '192.168.58.22'; PrivIp = '10.58.0.12'; Cpu = 3; Ram = 14336; OsDiskGb = 100 }
        @{ Name = 'ggtgt';   Role = 'tgt';   PublicIp = '192.168.58.50'; Cpu = 2; Ram = 6144;  OsDiskGb = 80 }
    )

    # Dyski wspoldzielone RAC: fixed + shareable / RAC shared disks: fixed + shareable
    SharedDisks = @(
        @{ Name = 'DATA1'; SizeGb = 60; DiskGroup = 'DATA' }   # OCR, voting, baza, wolumen ACFS OGGVOL
        @{ Name = 'FRA1';  SizeGb = 30; DiskGroup = 'FRA' }    # archivelogi wszystkich watkow
    )

    # Binaria Oracle: nazwy plikow w Dir. Puste = jeszcze nie pobrane.
    # Oracle binaries: file names in Dir. Empty = not downloaded yet.
    Binaries = @{
        Dir       = 'D:\install\oracle-26ai'   # set to your download folder / ustaw na swoj katalog z paczkami
        GridZip   = 'V1054596-01-OracleDatabaseGridInfrastructure23.26.1.0.0forLinux x86-64.zip'
        DbZip    = 'V1054592-01-OracleDatabase23.26.1.0.0forLinux x86-64.zip'
        GridRu    = 'p40002013_230000_Linux-x86-64.zip'          # RU GI 23.26.4 (MOS)
        DbRu      = 'p40007731_230000_Linux-x86-64.zip'          # RU DB 23.26.4 (MOS)
        OPatch    = 'p6880880_230000_Linux-x86-64.zip'           # OPatch 12.2.0.1.55 dla 23.x (MOS)
        OggZip    = 'p40225913_2326402OGGRU_Linux-x86-64.zip'    # GoldenGate 23.26.4.0.2 for Oracle, Complete Install (MOS)
        OggBundle = ''    # puste: OggZip to pelna instalacja / empty: OggZip is a full install
        XagZip    = 'p31215432_190000_Generic.zip'               # XAG 10.2 bug fix MLR, pelny pakiet (MOS)
        # Opcjonalne sumy SHA-256 / optional SHA-256 sums: @{ GridZip = '...' }
        Sha256    = @{}
    }

    Oracle = @{
        ClusterName = 'ggrac'
        GridHome    = '/u01/app/23.26/grid'
        DbHome      = '/u01/app/oracle/product/23.26/dbhome_1'
        StageDir    = '/u01/stage'
        SrcDb       = 'ggcdb'          # instancje ggcdb1, ggcdb2
        SrcPdb    = 'SRCPDB'
        GgService   = 'gg_srcpdb'      # singleton: preferred ggcdb1, available ggcdb2
        LoadServices = @('srv_load1', 'srv_load2')
        TgtDb       = 'tgtcdb'
        TgtPdb      = 'TGTPDB'
        StreamsPoolMb = 1280
        # SGA w MB; HugePages w kickstarcie = SGA/2 MB + zapas / SGA in MB; kickstart HugePages = SGA/2 MB + margin
        SrcSgaMb    = 4096
        TgtSgaMb    = 2560
    }

    Ogg = @{
        HaStage      = 'A'                          # A: XAG + ACFS + VIP; B: + NGINX (MAA)
        Home         = '/u01/app/ogg/ogg26ai_ma'
        XagHome      = '/u01/app/xag'
        DeployRoot   = '/u01/oggdeploy'             # ACFS
        ServiceManager = 'ggsm01'
        SmPort       = 9100
        # Porty uslug deploymentu (zrodlo i cel takie same) / deployment service ports (same on source and target)
        Ports        = @{ Admin = 9101; Dist = 9102; Recv = 9103; Pm = 9104 }
        AdminUser    = 'oggadmin'                   # admin Service Managera i deploymentow / SM and deployment admin
        SourceDeployment = 'oggsource'
        TargetDeployment = 'oggtarget'
        AcfsVolume   = 'OGGVOL'
        AcfsSizeGb   = 20
        Extract      = 'ext1'
        Trail        = 'et'
        Path         = 'dp1'
        Replicat     = 'rep1'
        CheckpointTable = 'ggadmin.ggs_checkpoint'
    }

    Ssh = @{ KeyPath = '~\.ssh\id_ed25519' }
}
