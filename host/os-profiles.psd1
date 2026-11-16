# ==============================================================================
# Tytul:        os-profiles.psd1
# Opis:         Dystrybucje Linuksa, ktore lab umie zainstalowac: skad wziac ISO, jego
#               suma SHA-256, repozytoria instalacji sieciowej, typ systemu w VirtualBox.
#               Nowa dystrybucja z rodziny RHEL = nowy wpis tutaj (ten sam kickstart).
# Description [EN]: Linux distributions the lab can install: ISO source, SHA-256, network
#               install repositories, VirtualBox OS type. A new RHEL-family distribution
#               is one more entry here (same kickstart).
#
# Autor:        KCB Kris
# Data:         2026-11-06
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czytany przez lab.ps1; wybor w lab.config.psd1 (Os.Profile)
# Requirements [EN]: - read by lab.ps1; chosen in lab.config.psd1 (Os.Profile)
#
# Uzycie [PL]:       Os = @{ Profile = 'ol8' }
# Usage [EN]:        Os = @{ Profile = 'ol8' }
# ==============================================================================
@{
    # Najmniejsze ISO startowe (boot): system i pakiety dociagaja sie z internetu.
    # Smallest boot ISO: the OS and packages are downloaded from the internet.
    ol9 = @{
        Title   = 'Oracle Linux 9.8'
        IsoFile = 'OracleLinux-R9-U8-x86_64-boot.iso'
        IsoUrl  = 'https://yum.oracle.com/ISOS/OracleLinux/OL9/u8/x86_64/OracleLinux-R9-U8-x86_64-boot.iso'
        Sha256  = 'FEC471A2F0324E958D18A55E8704A61CD39A49F029448699664BD4E97496DD5F'
        OsType  = 'Oracle_64'
        Url     = 'https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/'
        Repos   = @(
            @{ Name = 'ol9_appstream'; Url = 'https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/' }
        )
    }
    ol8 = @{
        Title   = 'Oracle Linux 8.10'
        IsoFile = 'OracleLinux-R8-U10-x86_64-boot.iso'
        IsoUrl  = 'https://yum.oracle.com/ISOS/OracleLinux/OL8/u10/x86_64/OracleLinux-R8-U10-x86_64-boot.iso'
        Sha256  = 'C7009CA2B28DDBEDD6C09FC9141F933DEC01A6EA73C503634786809746AF1906'
        OsType  = 'Oracle_64'
        Url     = 'https://yum.oracle.com/repo/OracleLinux/OL8/baseos/latest/x86_64/'
        Repos   = @(
            @{ Name = 'ol8_appstream'; Url = 'https://yum.oracle.com/repo/OracleLinux/OL8/appstream/x86_64/' }
        )
    }
    rocky9 = @{
        Title   = 'Rocky Linux 9.8'
        IsoFile = 'Rocky-9.8-x86_64-boot.iso'
        IsoUrl  = 'https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.8-x86_64-boot.iso'
        Sha256  = 'D6EEEFDC8437C593D41A3150FCCA4A734C55642ED472EECDDA99720BB1370881'
        OsType  = 'RedHat_64'
        Url     = 'https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/'
        Repos   = @(
            @{ Name = 'appstream'; Url = 'https://download.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/' }
        )
    }
}
