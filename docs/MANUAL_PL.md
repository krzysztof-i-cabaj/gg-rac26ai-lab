# ✋ Instalacja, droga 3 — w pełni ręcznie, polecenie po poleceniu

🇬🇧 [English](MANUAL.md) | 🇵🇱 Polski

[![Droga](https://img.shields.io/badge/Droga-3_ręczna-orange)]()
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26.1_+_RU_23.26.4-red)]()
[![GoldenGate](https://img.shields.io/badge/GoldenGate-23.26.4_+_XAG_10.2-blueviolet)]()
[![Źródło](https://img.shields.io/badge/Polecenia_z-guest%2F**-blue)]()

> 🎯 Cały lab **bez naszych skryptów**: polecenia, które wykonuje `guest/**`, w tej samej kolejności i z tymi samymi
> parametrami, dla osób, które budują to na własnych serwerach (fizycznych, w innym wirtualizatorze, w chmurze). Każda
> sekcja podaje swój odpowiednik w automacie, więc gdy coś wychodzi inaczej, można porównać ze skryptem.

Inne drogi: [INSTALL_AUTO_PL.md](INSTALL_AUTO_PL.md) (jedno polecenie), [INSTALL_STEPWISE_PL.md](INSTALL_STEPWISE_PL.md)
(po jednym kroku `lab.cmd`). Pojęcia używane niżej: [CONCEPTS_PL.md](CONCEPTS_PL.md).

## 0. 📋 Zanim zaczniesz

**Oznaczenia.** **[root@ggrac1]** = jako root na ggrac1; **[grid@oba]** = jako grid na ggrac1 i na ggrac2;
**[oracle@ggtgt]** = jako oracle na ggtgt. „Oba” oznacza zawsze dwa węzły RAC.

**Wartości.** Nazwy, adresy i ścieżki to wartości labu z `lab.config.psd1` ([ENVIRONMENT_PL.md](ENVIRONMENT_PL.md)).
Na własnych serwerach zamieniaj je konsekwentnie: nazwy interfejsów (`enp0s3` publiczny, `enp0s9` prywatny), nazwy
dysków, adresy, domenę.

| Element | Wartość w labie |
|---|---|
| Domena, serwer DNS + NTP | `gg.lab.test`, `gginfra` 192.168.58.10 |
| Węzły RAC | `ggrac1` .11 (VIP .21, prywatny 10.58.0.11), `ggrac2` .12 (VIP .22, prywatny 10.58.0.12) |
| SCAN, VIP GoldenGate, cel | `ggrac-scan` .31 .32 .33, `oggvip` .40, `ggtgt` .50 |
| Grid home, DB home | `/u01/app/23.26/grid`, `/u01/app/oracle/product/23.26/dbhome_1` |
| GoldenGate home, XAG home, deploymenty | `/u01/app/ogg/ogg26ai_ma`, `/u01/app/xag`, `/u01/oggdeploy` |
| Katalog z paczkami | `/u01/stage` (ZIP-y Oracle; nazwy ze spacjami łatwiej obsłużyć z `_` zamiast spacji) |

**Hasła.** Nigdy w linii poleceń, nigdy w pliku, który inni mogą czytać. W każdej powłoce root / grid / oracle, która
hasła potrzebuje, wczytaj je raz; pliki odpowiedzi i pliki SQL mają znaczniki `@@LAB_PASS@@` i `@@OGG_ADMIN_PASS@@`,
które poniższa funkcja wypełnia wewnątrz basha w prywatnej kopii:

```bash
read -rsp 'Lab password: ' LAB_PASS; echo; export LAB_PASS
read -rsp 'GoldenGate admin password: ' OGG_ADMIN_PASS; echo; export OGG_ADMIN_PASS
render() {   # render <szablon> <wynik>: znaczniki -> hasła, plik z prawami 600, nic w argv
    local t; t=$(<"$1"); t=${t//@@OGG_ADMIN_PASS@@/$OGG_ADMIN_PASS}
    ( umask 077; printf '%s\n' "${t//@@LAB_PASS@@/$LAB_PASS}" > "$2" )
}
```

`LAB_PASS`: litery, cyfry, `_`, co najmniej 8 znaków. `OGG_ADMIN_PASS`: GoldenGate 23.26 wymaga 8–30 znaków z małą
literą, wielką literą, cyfrą i jednym z `- ! @ % & * . # _` (skrypty biorą `LAB_PASS` i dopisują brakujące klasy).
Każdą wypełnioną kopię usuń zaraz po użyciu.

**Pliki.** ZIP-y Oracle ([ENVIRONMENT_PL.md](ENVIRONMENT_PL.md#-oprogramowanie-i-wersje)) trafiają do `/u01/stage` na
ggrac1 (GI, RU GI, DB, RU DB, OPatch, GoldenGate, XAG), na ggrac2 (GoldenGate) i na ggtgt (DB, RU DB, OPatch,
GoldenGate). Katalogi repozytorium `sql/` i `ogg/` też kopiujesz na maszyny; polecenia, które z nich korzystają
(`@sql/...`, `ogg/...`), uruchamiasz z katalogu z tymi kopiami, jako użytkownik, do którego on należy.

## 1. 🖥️ Maszyny

Wymagania na dowolnej platformie: 2 węzły RAC po 3 vCPU / 14 GB RAM / 100 GB dysku lokalnego, cel 2 vCPU / 6 GB /
80 GB, mały serwer DNS/NTP (1 vCPU / 2 GB / 20 GB); dwa współdzielone urządzenia blokowe widoczne na obu węzłach RAC
(60 GB na `+DATA`, 30 GB na `+FRA`, bez partycji); sieć publiczna dla wszystkich, sieć prywatna tylko między węzłami
RAC; internet (albo lokalne lustro) dla `dnf`.

**VirtualBox** — wywołania, które robi `lab.cmd build` (`host/modules/VmBuilder.psm1`, `lab.ps1`), na hoście Windows w
PowerShellu 7. Sieć host-only i dyski współdzielone:

```powershell
VBoxManage hostonlyif create                                   # wypisuje nazwę nowej karty
VBoxManage hostonlyif ipconfig "<karta>" --ip 192.168.58.1 --netmask 255.255.255.0
VBoxManage dhcpserver remove --ifname "<karta>"
VBoxManage createmedium disk --filename D:\VMs\gg-rac26ai-shared\gg-rac26ai-DATA1.vdi --size 61440 --format VDI --variant Fixed
VBoxManage modifymedium disk D:\VMs\gg-rac26ai-shared\gg-rac26ai-DATA1.vdi --type shareable
VBoxManage createmedium disk --filename D:\VMs\gg-rac26ai-shared\gg-rac26ai-FRA1.vdi --size 30720 --format VDI --variant Fixed
VBoxManage modifymedium disk D:\VMs\gg-rac26ai-shared\gg-rac26ai-FRA1.vdi --type shareable
```

Jedna maszyna (tu `ggrac1`; RAM / CPU / dysk według tabeli w [ENVIRONMENT_PL.md](ENVIRONMENT_PL.md#-maszyny)):

```powershell
VBoxManage createvm --name ggrac1 --ostype Oracle_64 --register --basefolder D:\VMs
VBoxManage modifyvm ggrac1 --description "vbox-lab:gg-rac26ai" --memory 14336 --cpus 3 `
  --nic1 hostonly --hostonlyadapter1 "<karta>" --nictype1 virtio --nic2 nat --nictype2 virtio `
  --boot1 disk --boot2 dvd --boot3 none --boot4 none --ioapic on --rtcuseutc on --paravirtprovider kvm `
  --graphicscontroller vmsvga --vram 16 --audio-driver none --usb off
VBoxManage createmedium disk --filename D:\VMs\ggrac1\ggrac1-os.vdi --size 102400 --format VDI
VBoxManage storagectl ggrac1 --name SATA --add sata --controller IntelAhci --portcount 2
VBoxManage storageattach ggrac1 --storagectl SATA --port 0 --type hdd --medium D:\VMs\ggrac1\ggrac1-os.vdi --nonrotational on
VBoxManage storageattach ggrac1 --storagectl SATA --port 1 --type dvddrive --medium D:\ISOs\OracleLinux-R9-U8-x86_64-boot.iso
# tylko węzły RAC: karta interconnectu i dyski współdzielone
VBoxManage modifyvm ggrac1 --nic3 intnet --intnet3 ggrac-ic --nictype3 virtio
VBoxManage storagectl ggrac1 --name SATA --portcount 4
VBoxManage storageattach ggrac1 --storagectl SATA --port 2 --device 0 --type hdd --medium D:\VMs\gg-rac26ai-shared\gg-rac26ai-DATA1.vdi --mtype shareable
VBoxManage storageattach ggrac1 --storagectl SATA --port 3 --device 0 --type hdd --medium D:\VMs\gg-rac26ai-shared\gg-rac26ai-FRA1.vdi --mtype shareable
VBoxManage startvm ggrac1 --type headless
```

Odpowiednik w automacie: `lab.cmd build` (`Step-Build`, `New-SharedDisks`, `Add-VmExtras` w `lab.ps1`).

## 2. 🐧 Oracle Linux 9.8

Instalacja z ISO startowego OL 9.8, pakiety z yum.oracle.com (BaseOS latest, AppStream, **UEKR8**). Wszystkie ustawienia
są w szablonach `kickstart/base.ks.tmpl` i `kickstart/role-*.ks.tmpl`; przy własnej instalacji odtwórz je:

- `selinux --enforcing`, `firewall --disabled`, strefa czasowa `Europe/Warsaw --utc`, usługi sshd, chronyd,
  NetworkManager.
- Sieć: `enp0s3` statycznie (np. 192.168.58.11/24, nazwa `ggrac1.gg.lab.test`, **bez trasy domyślnej**), `enp0s8` DHCP
  (jedyna trasa domyślna), na węzłach RAC `enp0s9` statycznie 10.58.0.11/24 bez trasy domyślnej.
- Tylko dysk systemowy (`sda`): `/boot` 1 GB xfs, swap = RAM w GB (1–16 GB), `/` 30 GB xfs, `/u01` reszta (na serwerze
  DNS reszta idzie do `/`). Dysków współdzielonych nie dotykaj.
- Pakiety: `@core openssh-server chrony firewalld bind-utils net-tools curl jq tar unzip rsync lsof vim-enhanced
  bash-completion policycoreutils-python-utils python3-dnf-plugin-versionlock kernel-uek`, do tego
  `oracle-ai-database-preinstall-26ai` i `nfs-utils` (RAC), `oracle-ai-database-preinstall-26ai` (cel),
  `dnsmasq` (serwer DNS).

Odpowiednik w automacie: `lab.cmd build` (kickstart renderuje `host/Kickstart.psm1`, linia startowa
`inst.ks=http://192.168.58.1:8000/kickstart/out/<vm>.ks inst.text ip=<ip>:::255.255.255.0:<fqdn>:enp0s3:none`).

## 3. 🧰 Przygotowanie systemu (sekcja `%post` kickstartu)

**[root@wszystkie maszyny]** klucz SSH, skoki zegara, nazwy labu (bez SCAN: SCAN jest tylko w DNS):

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo '<twój klucz publiczny>' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && restorecon -R /root/.ssh
sed -i 's/^makestep .*/makestep 1.0 -1/' /etc/chrony.conf     # skok przy każdej dużej odchyłce (wstrzymane VM)
cat >> /etc/hosts <<'EOF'
192.168.58.10   gginfra.gg.lab.test  gginfra
192.168.58.11   ggrac1.gg.lab.test  ggrac1
192.168.58.12   ggrac2.gg.lab.test  ggrac2
192.168.58.50   ggtgt.gg.lab.test  ggtgt
192.168.58.21   ggrac1-vip.gg.lab.test  ggrac1-vip
192.168.58.22   ggrac2-vip.gg.lab.test  ggrac2-vip
10.58.0.11      ggrac1-priv.gg.lab.test  ggrac1-priv
10.58.0.12      ggrac2-priv.gg.lab.test  ggrac2-priv
192.168.58.40   oggvip.gg.lab.test  oggvip
EOF
```

**[root@oba]** blokada jądra (ACFS obsługuje tylko certyfikowane jądra, KB129209), użytkownik grid, grupy, katalogi,
limity, zeroconf, HugePages, profile:

```bash
mapfile -t kpkgs < <(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 'kernel*')
dnf -y versionlock add "${kpkgs[@]}"

getent group asmadmin >/dev/null || groupadd -g 54327 asmadmin
getent group asmdba   >/dev/null || groupadd -g 54328 asmdba
getent group asmoper  >/dev/null || groupadd -g 54329 asmoper
id grid >/dev/null 2>&1 || useradd -u 54331 -g oinstall -G asmadmin,asmdba,asmoper,dba,racdba -m -s /bin/bash grid
usermod -a -G asmdba,racdba oracle
passwd grid; passwd oracle

mkdir -p /u01/app/grid /u01/app/23.26/grid /u01/app/oraInventory /u01/stage /u01/app/xag
mkdir -p /u01/app/oracle /u01/app/oracle/product/23.26/dbhome_1 /u01/app/ogg/ogg26ai_ma
chown -R grid:oinstall /u01/app/grid /u01/app/23.26 /u01/app/oraInventory /u01/stage /u01/app/xag
chown -R oracle:oinstall /u01/app/oracle /u01/app/ogg
chmod -R 775 /u01

cat > /etc/security/limits.d/zz-grid.conf <<'EOF'
grid   soft   nofile    1024
grid   hard   nofile    65536
grid   soft   nproc     16384
grid   hard   nproc     16384
grid   soft   stack     10240
grid   hard   stack     32768
grid   soft   memlock   unlimited
grid   hard   memlock   unlimited
oracle soft   memlock   unlimited
oracle hard   memlock   unlimited
EOF
grep -q '^NOZEROCONF' /etc/sysconfig/network || echo 'NOZEROCONF=yes' >> /etc/sysconfig/network
printf 'vm.nr_hugepages = 2112\nvm.hugetlb_shm_group = 54322\n' > /etc/sysctl.d/99-oracle-hugepages.conf   # SGA 4096 MB / 2 + 64
sysctl --system >/dev/null

cat >> /home/grid/.bash_profile <<'EOF'
export ORACLE_BASE=/u01/app/grid
export ORACLE_HOME=/u01/app/23.26/grid
export ORACLE_SID=+ASM1          # +ASM2 na ggrac2
export PATH=/u01/app/xag/bin:$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:$PATH
umask 022
EOF
cat >> /home/oracle/.bash_profile <<'EOF'
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=/u01/app/oracle/product/23.26/dbhome_1
export ORACLE_SID=ggcdb1         # ggcdb2 na ggrac2
export OGG_HOME=/u01/app/ogg/ogg26ai_ma
export PATH=/u01/app/xag/bin:$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:$OGG_HOME/bin:$PATH
umask 022
EOF
echo 'export PATH=/u01/app/xag/bin:/u01/app/23.26/grid/bin:$PATH' >> /root/.bash_profile   # agctl z XAG przed tym z GI
```

**[root@ggtgt]** to samo dla celu (tylko oracle, bez grid, bez blokady jądra):

```bash
passwd oracle
mkdir -p /u01/app/oracle /u01/app/oracle/product/23.26/dbhome_1 /u01/app/oraInventory /u01/stage /u01/app/ogg/ogg26ai_ma /u01/oggdeploy /u01/oradata
chown -R oracle:oinstall /u01 && chmod -R 775 /u01
printf 'vm.nr_hugepages = 1344\nvm.hugetlb_shm_group = 54322\n' > /etc/sysctl.d/99-oracle-hugepages.conf && sysctl --system >/dev/null
cat >> /home/oracle/.bash_profile <<'EOF'
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=/u01/app/oracle/product/23.26/dbhome_1
export ORACLE_SID=tgtcdb
export OGG_HOME=/u01/app/ogg/ogg26ai_ma
export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:$OGG_HOME/bin:$PATH
umask 022
EOF
```

Transparent HugePages: zostaw `madvise` (ustawia to pakiet preinstall 26ai na UEK 7+); nie wyłączaj ich.
Odpowiednik w automacie: `%post` kickstartu (`kickstart/base.ks.tmpl`, `role-rac.ks.tmpl`, `role-tgt.ks.tmpl`).

## 4. 🌐 Serwer DNS i czasu (gginfra)

**[root@gginfra]**

```bash
cat > /etc/lab.hosts <<'EOF'
192.168.58.10   gginfra.gg.lab.test  gginfra
192.168.58.11   ggrac1.gg.lab.test  ggrac1
192.168.58.12   ggrac2.gg.lab.test  ggrac2
192.168.58.50   ggtgt.gg.lab.test  ggtgt
192.168.58.21   ggrac1-vip.gg.lab.test  ggrac1-vip
10.58.0.11      ggrac1-priv.gg.lab.test  ggrac1-priv
192.168.58.22   ggrac2-vip.gg.lab.test  ggrac2-vip
10.58.0.12      ggrac2-priv.gg.lab.test  ggrac2-priv
192.168.58.31   ggrac-scan.gg.lab.test  ggrac-scan
192.168.58.32   ggrac-scan.gg.lab.test  ggrac-scan
192.168.58.33   ggrac-scan.gg.lab.test  ggrac-scan
192.168.58.40   oggvip.gg.lab.test  oggvip
EOF
cat > /etc/dnsmasq.d/lab.conf <<'EOF'
domain-needed
bogus-priv
no-hosts
addn-hosts=/etc/lab.hosts
domain=gg.lab.test
local=/gg.lab.test/
local=/58.168.192.in-addr.arpa/
listen-address=127.0.0.1,192.168.58.10
bind-interfaces
cache-size=1000
EOF
systemctl enable --now dnsmasq && systemctl restart dnsmasq
mkdir -p /etc/chrony.d
grep -q '^include /etc/chrony.d/\*.conf' /etc/chrony.conf || echo 'include /etc/chrony.d/*.conf' >> /etc/chrony.conf
printf 'allow 192.168.58.0/24\nlocal stratum 8\n' > /etc/chrony.d/lab-server.conf
systemctl restart chronyd && systemctl enable chronyd
systemctl disable --now firewalld
```

Sprawdzenie: `dig +short ggrac-scan.gg.lab.test @127.0.0.1` (3 adresy), `dig +short -x 192.168.58.11 @127.0.0.1`
(`ggrac1.gg.lab.test.`), `dig +short yum.oracle.com @127.0.0.1` (przekazane dalej), `chronyc tracking`
(`Leap status : Normal`). Przy istniejącym firmowym DNS: załóż tam te same rekordy A i PTR, SCAN jako trzy rekordy A
jednej nazwy.

Odpowiednik w automacie: `lab.cmd infra` (`guest/infra/10_dnsmasq.sh`, `20_chrony.sh`, `90_validate.sh`).

## 5. 🕰️ Resolver, czas, zapora (węzły RAC i ggtgt)

**[root@oba]** i **[root@ggtgt]**

```bash
printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/90-lab-dns.conf && systemctl reload NetworkManager
rm -f /etc/resolv.conf && printf 'search gg.lab.test\nnameserver 192.168.58.10\n' > /etc/resolv.conf
mkdir -p /etc/chrony.d && echo 'server 192.168.58.10 iburst' > /etc/chrony.d/lab-client.conf
sed -i -E '/^(pool|server) /s/^/#/' /etc/chrony.conf
grep -q '^include /etc/chrony.d/\*.conf' /etc/chrony.conf || echo 'include /etc/chrony.d/*.conf' >> /etc/chrony.conf
systemctl restart chronyd
systemctl disable --now avahi-daemon.socket avahi-daemon.service 2>/dev/null
systemctl disable --now firewalld
```

Kontrole przed Grid Infrastructure:

```bash
chronyc -n sources                                   # ^* 192.168.58.10
dig +short ggrac-scan.gg.lab.test | sort             # 192.168.58.31 .32 .33
dig +short -x 192.168.58.11                          # ggrac1.gg.lab.test.
for h in ggrac1 ggrac2 ggrac1-priv ggrac2-priv; do ping -c1 -W2 $h >/dev/null && echo "ok $h"; done
for ip in 192.168.58.31 192.168.58.32 192.168.58.33 192.168.58.21 192.168.58.22 192.168.58.40; do ping -c1 -W1 $ip >/dev/null && echo "BUSY $ip"; done   # nie może nic wypisać
rpm -q oracle-ai-database-preinstall-26ai
cat /sys/kernel/mm/transparent_hugepage/enabled      # [madvise]
dnf versionlock list | grep kernel; uname -r         # działające jądro jest jednym z zablokowanych
```

Odpowiednik w automacie: `lab.cmd prereq` (`guest/rac/10_os_prereq.sh`), na ggtgt pierwsza część `lab.cmd tgt`
(`guest/tgt/10_os_prereq.sh`).

## 6. 💾 Dyski ASM przez udev

**[root@oba]** znajdź każdy dysk współdzielony po rozmiarze i przypisz regułę do jego numeru seryjnego:

```bash
lsblk -dbo NAME,SIZE,TYPE                            # 64424509440 bajtów = DATA1, 32212254720 = FRA1
udevadm info --query=property --name=/dev/sdb | sed -n 's/^ID_SERIAL=//p'
udevadm info --query=property --name=/dev/sdc | sed -n 's/^ID_SERIAL=//p'
cat > /etc/udev/rules.d/99-oracle-asmdevices.rules <<'EOF'
KERNEL=="sd*", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL}=="<numer DATA1>", SYMLINK+="oracleasm/DATA1", OWNER="grid", GROUP="asmdba", MODE="0660"
KERNEL=="sd*", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL}=="<numer FRA1>", SYMLINK+="oracleasm/FRA1", OWNER="grid", GROUP="asmdba", MODE="0660"
EOF
udevadm control --reload-rules && udevadm trigger --type=devices --action=change && udevadm settle
ls -lL /dev/oracleasm/                               # brw-rw---- grid asmdba na obu węzłach
```

Grupa `asmdba`, nie `asmadmin`: baza 26ai musi móc otworzyć urządzenia (z `asmadmin` dbca padał z ORA-15001). Na tych
dyskach nie zakładaj partycji.

Odpowiednik w automacie: `lab.cmd shared` (`guest/rac/20_asm_udev.sh`).

## 7. 🔑 Zaufanie SSH dla grid i oracle

**[grid@oba]**, potem to samo **[oracle@oba]**:

```bash
[ -f ~/.ssh/id_rsa ] || { mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -f ~/.ssh/id_rsa; }
cat ~/.ssh/id_rsa.pub          # klucze obu węzłów wpisz do ~/.ssh/authorized_keys na obu węzłach (prawa 600)
ssh-keyscan -T 5 ggrac1 ggrac1.gg.lab.test ggrac2 ggrac2.gg.lab.test 192.168.58.11 192.168.58.12 2>/dev/null | sort -u > ~/.ssh/known_hosts
for h in ggrac1 ggrac1.gg.lab.test ggrac2 ggrac2.gg.lab.test 192.168.58.11 192.168.58.12; do ssh -o BatchMode=yes $h true && echo "ok $h"; done
```

Format PEM: klient SSH instalatorów (Java) odrzucał już nowszy format kluczy OpenSSH (INS-06006); PEM jest bezpieczny.
Odpowiednik w automacie: `lab.cmd shared` (`guest/rac/30_ssh_equivalence.sh keygen|authorize|verify`).

## 8. 🧱 Grid Infrastructure 23.26 z RU 23.26.4

**[grid@ggrac1]** rozpakowanie GI, podmiana OPatch, rozpakowanie RU:

```bash
cd /u01/app/23.26/grid && unzip -q -o /u01/stage/V1054596-01-OracleDatabaseGridInfrastructure23.26.1.0.0forLinux_x86-64.zip
cd /u01/app/23.26/grid && rm -rf OPatch && unzip -q -o /u01/stage/p6880880_230000_Linux-x86-64.zip
mkdir -p /u01/stage/ru_gi && cd /u01/stage/ru_gi && unzip -q -o /u01/stage/p40002013_230000_Linux-x86-64.zip   # -> 40002013/
```

**[root@ggrac1]** `CVUQDISK_GRP=oinstall rpm -ivh /u01/app/23.26/grid/cv/rpm/cvuqdisk-*.rpm`, skopiuj RPM na ggrac2
(`scp`) i to samo polecenie **[root@ggrac2]** z `/tmp/cvuqdisk-*.rpm`.

**[grid@ggrac1]** plik odpowiedzi. 26ai używa krótkich kluczy (`installOption`, `scanName`, `clusterNodes` …): plik z 19c
z kluczami `oracle.install.*` nie zadziała. Porównaj swój z `/u01/app/23.26/grid/install/response/gridsetup.rsp`.
Szablon: `response/gridsetup.rsp.tmpl`; z wartościami labu:

```bash
cat > ~/gridsetup.rsp.tmpl <<'EOF'
oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v23.0.0
INVENTORY_LOCATION=/u01/app/oraInventory
installOption=CRS_CONFIG
ORACLE_BASE=/u01/app/grid
clusterUsage=RAC
OSDBA=asmdba
OSOPER=asmoper
OSASM=asmadmin
scanType=LOCAL_SCAN
scanName=ggrac-scan
scanPort=1521
configureAsExtendedCluster=false
clusterName=ggrac
configureGNS=false
configureDHCPAssignedVIPs=false
clusterNodes=ggrac1:ggrac1-vip,ggrac2:ggrac2-vip
networkInterfaceList=enp0s3:192.168.58.0:1,enp0s9:10.58.0.0:5
storageOption=FLEX_ASM_STORAGE
useIPMI=false
sysasmPassword=@@LAB_PASS@@
diskGroupName=DATA
redundancy=EXTERNAL
auSize=4
diskList=/dev/oracleasm/DATA1
diskString=/dev/oracleasm/*
asmsnmpPassword=@@LAB_PASS@@
ignoreDownNodes=false
configureBackupDG=false
managementOption=NONE
executeRootScript=false
EOF
render ~/gridsetup.rsp.tmpl /u01/stage/grid.rsp
cd /tmp && /u01/app/23.26/grid/gridSetup.sh -silent -ignorePrereqFailure -applyRU /u01/stage/ru_gi/40002013 -responseFile /u01/stage/grid.rsp
```

Kod wyjścia 0 = OK, 6 = OK z ostrzeżeniami (przeczytaj log w `/u01/app/oraInventory/logs`).

**[root@ggrac1]**, potem **[root@ggrac2]**, jeden po drugim (nigdy równolegle):

```bash
/u01/app/oraInventory/orainstRoot.sh
/u01/app/23.26/grid/root.sh          # log: /u01/app/23.26/grid/install/root_<węzeł>*.log; ponowne uruchomienie wznawia od punktu kontrolnego
```

**[root@oba]** AHF / TFA wyłączone zaraz po `root.sh` (na węzłach z 2–3 vCPU zagładzał bazę, patrz
[PITFALLS_26AI_PL.md](PITFALLS_26AI_PL.md); ponowne włączenie: `systemctl enable --now oracle-tfa`):

```bash
timeout 600 /opt/oracle.ahf/bin/ahfctl stopahf -all
systemctl disable --now oracle-tfa.service
systemctl is-active oracle-tfa.service              # inactive
```

**[grid@ggrac1]** narzędzia konfiguracyjne, potem `+FRA`:

```bash
cd /tmp && /u01/app/23.26/grid/gridSetup.sh -silent -executeConfigTools -responseFile /u01/stage/grid.rsp
rm -f /u01/stage/grid.rsp
asmca -silent -createDiskGroup -diskGroupName FRA -disk '/dev/oracleasm/FRA1' -redundancy EXTERNAL -au_size 4 \
      -compatible.asm 23.0.0.0.0 -compatible.rdbms 23.0.0.0.0
srvctl start diskgroup -diskgroup FRA               # asmca montuje ją tylko tam, gdzie działał
```

Kontrole **[grid@ggrac1]**: `crsctl check cluster -all` (online, nic offline), `olsnodes -n` (2 węzły),
`srvctl status scan_listener` (3 działają), `srvctl status scan` (3 VIP-y), `asmcmd lsdg` (`DATA/`, `FRA/`). GI 23.26 nie
ma zasobu `ora.ctssd` ani polecenia `crsctl check ctss`: czas trzyma chrony.

Odpowiednik w automacie: `lab.cmd grid` (`guest/rac/40_install_grid.sh stage|cvuqdisk|install|root|ahf|config|fra`,
`90_validate.sh grid`). Dokumentacja: *Oracle Grid Infrastructure Installation and Upgrade Guide for Linux* (instalacja
cicha z plikiem odpowiedzi).

## 9. 🗄️ Oprogramowanie bazy (oba węzły z ggrac1)

**[oracle@ggrac1]**

```bash
cd /u01/app/oracle/product/23.26/dbhome_1 && unzip -q -o /u01/stage/V1054592-01-OracleDatabase23.26.1.0.0forLinux_x86-64.zip
cd /u01/app/oracle/product/23.26/dbhome_1 && rm -rf OPatch && unzip -q -o /u01/stage/p6880880_230000_Linux-x86-64.zip
mkdir -p /u01/stage/ru_db && cd /u01/stage/ru_db && unzip -q -o /u01/stage/p40007731_230000_Linux-x86-64.zip   # -> 40007731/
cat > /u01/stage/db_install.rsp <<'EOF'
oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v23.0.0
installOption=INSTALL_DB_SWONLY
UNIX_GROUP_NAME=oinstall
INVENTORY_LOCATION=/u01/app/oraInventory
ORACLE_HOME=/u01/app/oracle/product/23.26/dbhome_1
ORACLE_BASE=/u01/app/oracle
installEdition=EE
OSDBA=dba
OSOPER=oper
OSBACKUPDBA=backupdba
OSDGDBA=dgdba
OSKMDBA=kmdba
OSRACDBA=racdba
executeRootScript=false
clusterNodes=ggrac1,ggrac2
EOF
cd /tmp && /u01/app/oracle/product/23.26/dbhome_1/runInstaller -silent -ignorePrereqFailure -waitforcompletion \
  -applyRU /u01/stage/ru_db/40007731 -responseFile /u01/stage/db_install.rsp
```

**[root@ggrac1]**, potem **[root@ggrac2]**: `/u01/app/oracle/product/23.26/dbhome_1/root.sh`

Kontrola **[oracle@oba]**: `$ORACLE_HOME/OPatch/opatch lspatches`.
Odpowiednik w automacie: `lab.cmd db` (`guest/shared/install_db.sh stage|install|root`, plik `response/db_install.rsp.tmpl`).

## 10. 🏛️ Źródłowa baza RAC `ggcdb`

**[oracle@ggrac1]** (szablon `response/dbca_src.rsp.tmpl`):

```bash
cat > ~/dbca_src.rsp.tmpl <<'EOF'
responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v23.0.0
gdbName=ggcdb
sid=ggcdb
databaseConfigType=RAC
RACOneNodeServiceName=
policyManaged=false
createServerPool=false
nodelist=ggrac1,ggrac2
templateName=/u01/app/oracle/product/23.26/dbhome_1/assistants/dbca/templates/General_Purpose.dbc
sysPassword=@@LAB_PASS@@
systemPassword=@@LAB_PASS@@
emConfiguration=NONE
runCVUChecks=false
dvConfiguration=false
olsConfiguration=false
createAsContainerDatabase=true
numberOfPDBs=1
pdbName=SRCPDB
useLocalUndoForPDBs=true
pdbAdminPassword=@@LAB_PASS@@
storageType=ASM
diskGroupName=+DATA/{DB_UNIQUE_NAME}/
datafileDestination=+DATA/{DB_UNIQUE_NAME}/
recoveryGroupName=+FRA
recoveryAreaDestination=+FRA
characterSet=AL32UTF8
nationalCharacterSet=AL16UTF16
registerWithDirService=false
listeners=
variables=
initParams=use_large_pages=TRUE,sga_target=4096M,pga_aggregate_target=1024M,processes=400
sampleSchema=false
memoryPercentage=
databaseType=MULTIPURPOSE
automaticMemoryManagement=false
totalMemory=
EOF
render ~/dbca_src.rsp.tmpl /u01/stage/dbca_src.rsp
cd /tmp && dbca -silent -createDatabase -responseFile /u01/stage/dbca_src.rsp -ignorePreReqs -enableArchive true -recoveryAreaSize 26112
rm -f /u01/stage/dbca_src.rsp
srvctl status database -db ggcdb
sqlplus / as sysdba @sql/01_src_prep_cdb.sql 1280 SRCPDB
```

`26112` MB = 85 % z 30 GB `+FRA`. Co robi `01_src_prep_cdb.sql`, gdybyś wolał wpisać to sam:

```sql
ALTER SYSTEM SET enable_goldengate_replication=TRUE SCOPE=BOTH SID='*';
ALTER SYSTEM SET streams_pool_size=1280M SCOPE=BOTH SID='*';     -- MAA: 1 Extract x 1 GB x 1,25
ALTER DATABASE FORCE LOGGING;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SYSTEM ARCHIVE LOG CURRENT;
ALTER PLUGGABLE DATABASE SRCPDB OPEN INSTANCES=ALL;
```

Baza musi być w trybie ARCHIVELOG (stąd `-enableArchive true`). Odpowiednik w automacie: `lab.cmd dbca`
(`guest/rac/60_create_db.sh`).

## 11. 🧭 Serwisy i dane demo

**[oracle@ggrac1]**

```bash
srvctl add service -db ggcdb -service gg_srcpdb -pdb SRCPDB -preferred ggcdb1 -available ggcdb2
srvctl add service -db ggcdb -service srv_load1 -pdb SRCPDB -preferred ggcdb1 -available ggcdb2
srvctl add service -db ggcdb -service srv_load2 -pdb SRCPDB -preferred ggcdb2 -available ggcdb1
for s in gg_srcpdb srv_load1 srv_load2; do srvctl start service -db ggcdb -service $s; srvctl status service -db ggcdb -service $s; done
sqlplus / as sysdba @sql/05_demo_schema.sql SRCPDB
sqlplus / as sysdba @sql/06_loadgen.sql SRCPDB
```

`gg_srcpdb` to singleton (jedna instancja preferowana, jedna zapasowa): Extract łączy się przez niego, a XAG trzyma
GoldenGate na węźle, na którym ten serwis działa (`--use_local_services`, sekcja 16). `srvctl status service` w 26ai
wypisuje „running on instances: …” (starsze wydania: „instance(s)”). Odpowiednik w automacie: `lab.cmd services`
(`guest/rac/65_services.sh`, `90_validate.sh db`).

## 12. 🎯 Baza docelowa `tgtcdb` (ggtgt)

**[oracle@ggtgt]** oprogramowanie: jak w sekcji 9 (rozpakowanie DB, OPatch, RU do `/u01/stage/ru_db`), z **pustym**
`clusterNodes=` w `db_install.rsp`; potem **[root@ggtgt]** `/u01/app/oraInventory/orainstRoot.sh` (pierwsza instalacja na
tej maszynie) i `/u01/app/oracle/product/23.26/dbhome_1/root.sh`.

**[oracle@ggtgt]** listener i baza (szablon `response/dbca_tgt.rsp.tmpl`):

```bash
cat > $ORACLE_HOME/network/admin/listener.ora <<'EOF'
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ggtgt.gg.lab.test)(PORT = 1521))
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))))
EOF
lsnrctl start
cat > ~/dbca_tgt.rsp.tmpl <<'EOF'
responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v23.0.0
gdbName=tgtcdb
sid=tgtcdb
databaseConfigType=SI
templateName=/u01/app/oracle/product/23.26/dbhome_1/assistants/dbca/templates/General_Purpose.dbc
sysPassword=@@LAB_PASS@@
systemPassword=@@LAB_PASS@@
emConfiguration=NONE
runCVUChecks=false
dvConfiguration=false
olsConfiguration=false
createAsContainerDatabase=true
numberOfPDBs=1
pdbName=TGTPDB
useLocalUndoForPDBs=true
pdbAdminPassword=@@LAB_PASS@@
storageType=FS
datafileDestination=/u01/oradata/{DB_UNIQUE_NAME}/
recoveryAreaDestination=
characterSet=AL32UTF8
nationalCharacterSet=AL16UTF16
registerWithDirService=false
listeners=LISTENER
variables=
initParams=use_large_pages=TRUE,sga_target=2560M,pga_aggregate_target=512M,processes=300
sampleSchema=false
memoryPercentage=
databaseType=MULTIPURPOSE
automaticMemoryManagement=false
totalMemory=
EOF
render ~/dbca_tgt.rsp.tmpl /u01/stage/dbca_tgt.rsp
cd /tmp && dbca -silent -createDatabase -responseFile /u01/stage/dbca_tgt.rsp -ignorePreReqs && rm -f /u01/stage/dbca_tgt.rsp
```

**[root@ggtgt]** autostart. Przy SELinux w trybie Enforcing systemd nie może wykonać `dbstart` z katalogu Oracle
(`203/EXEC Permission denied`, katalog ma etykietę `default_t`); działa, gdy skrypt czyta bash:

```bash
sed -i -E 's|^(tgtcdb:[^:]+):N|\1:Y|' /etc/oratab
cat > /etc/systemd/system/oracle-db.service <<'EOF'
[Unit]
Description=Oracle Database (tgtcdb) and listener
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=oracle
Group=oinstall
ExecStart=/usr/bin/bash /u01/app/oracle/product/23.26/dbhome_1/bin/dbstart /u01/app/oracle/product/23.26/dbhome_1
ExecStop=/usr/bin/bash /u01/app/oracle/product/23.26/dbhome_1/bin/dbshut /u01/app/oracle/product/23.26/dbhome_1
RemainAfterExit=yes
TimeoutSec=600
LimitMEMLOCK=infinity
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable oracle-db.service
```

**[oracle@ggtgt]** parametr GoldenGate, stan PDB, te same tabele demo i wiersze startowe co w źródle (bez ładowania
początkowego):

```bash
sqlplus / as sysdba @sql/03_tgt_prep_cdb.sql TGTPDB     # enable_goldengate_replication, FORCE LOGGING, TGTPDB OPEN + SAVE STATE
sqlplus / as sysdba @sql/05_demo_schema.sql TGTPDB
```

Odpowiednik w automacie: `lab.cmd tgt` (`guest/tgt/10_os_prereq.sh`, `50_install_db.sh`, `60_create_db.sh`,
`90_validate.sh db`).

## 13. 📂 ACFS na deployment GoldenGate

**[root@oba]**

```bash
/u01/app/23.26/grid/bin/acfsdriverstate supported      # musi wypisać ACFS-9200 (supported)
/u01/app/23.26/grid/bin/acfsdriverstate loaded || /u01/app/23.26/grid/bin/acfsload start
mkdir -p /u01/oggdeploy
```

**[grid@ggrac1]**

```bash
asmcmd volcreate -G DATA -s 20G OGGVOL
asmcmd volinfo -G DATA OGGVOL          # „Volume Device: /dev/asm/oggvol-NNN”
```

**[root@ggrac1]** (`NNN` z `volinfo`; formatuj tylko pusty wolumen):

```bash
/sbin/mkfs -t acfs /dev/asm/oggvol-NNN
/u01/app/23.26/grid/bin/srvctl add filesystem -device /dev/asm/oggvol-NNN -volume OGGVOL -diskgroup DATA \
    -path /u01/oggdeploy -user oracle -autostart RESTORE
/u01/app/23.26/grid/bin/srvctl start filesystem -volume OGGVOL -diskgroup DATA -node ggrac1
chown oracle:oinstall /u01/oggdeploy && chmod 775 /u01/oggdeploy
/u01/app/23.26/grid/bin/crsctl stat res ora.data.oggvol.acfs -t     # ONLINE tylko na ggrac1
```

Zamontowany na **jednym** węźle (MAA): XAG przenosi go razem z GoldenGate. Odpowiednik w automacie: `lab.cmd acfs`
(`guest/rac/70_acfs.sh prep|create`). Dokumentacja: *Oracle Automatic Storage Management Administrator's Guide* (ACFS).

## 14. 🔁 Oprogramowanie GoldenGate i deployment celu

**[oracle@ggrac1]**, **[oracle@ggrac2]**, **[oracle@ggtgt]**: lokalne oprogramowanie na każdej maszynie

```bash
mkdir -p /u01/stage/ogg && cd /u01/stage/ogg && unzip -q -o /u01/stage/p40225913_2326402OGGRU_Linux-x86-64.zip
cat > /u01/stage/oggcore.rsp <<'EOF'
oracle.install.responseFileVersion=/oracle/install/rspfmt_ogginstall_response_schema_v23_1_0
INSTALL_OPTION=ORA23ai
SOFTWARE_LOCATION=/u01/app/ogg/ogg26ai_ma
INVENTORY_LOCATION=/u01/app/oraInventory
UNIX_GROUP_NAME=oinstall
EOF
cd /tmp && /u01/stage/ogg/*/Disk1/runInstaller -silent -waitforcompletion -responseFile /u01/stage/oggcore.rsp
/u01/app/ogg/ogg26ai_ma/bin/adminclient -v | head -3
```

`INSTALL_OPTION=ORA23ai`: porównaj z `/u01/stage/ogg/*/Disk1/response/oggcore.rsp` swojego wydania (strona w
dokumentacji online wciąż podaje starsze wartości). Jeśli potem nie ma `/etc/oraInst.loc`: **[root]**
`/u01/app/oraInventory/orainstRoot.sh`. Osobna łatka zbiorcza (przy ZIP-ie z pełną instalacją niepotrzebna) to
`opatch apply -silent` z `ORACLE_HOME=/u01/app/ogg/ogg26ai_ma`, przy zatrzymanym GoldenGate.

**[oracle@ggtgt]** Service Manager i deployment celu (szablon `ogg/oggca_target.rsp.tmpl`):

```bash
cat > ~/oggca_target.rsp.tmpl <<'EOF'
oracle.install.responseFileVersion=/oracle/install/rspfmt_oggca_response_schema_v23_1_0
CONFIGURATION_OPTION=ADD
DEPLOYMENT_NAME=oggtarget
ADMINISTRATOR_USER=oggadmin
ADMINISTRATOR_PASSWORD=@@OGG_ADMIN_PASS@@
SERVICEMANAGER_DEPLOYMENT_HOME=/u01/oggdeploy/ggsm01
HOST_SERVICEMANAGER=ggtgt.gg.lab.test
PORT_SERVICEMANAGER=9100
SECURITY_ENABLED=false
STRONG_PWD_POLICY_ENABLED=true
CREATE_NEW_SERVICEMANAGER=true
REGISTER_SERVICEMANAGER_AS_A_SERVICE=true
INTEGRATE_SERVICEMANAGER_WITH_XAG=false
EXISTING_SERVICEMANAGER_IS_XAG_ENABLED=false
OGG_SOFTWARE_HOME=/u01/app/ogg/ogg26ai_ma
OGG_DEPLOYMENT_HOME=/u01/oggdeploy/oggtarget
ENV_LD_LIBRARY_PATH=${OGG_HOME}/lib/instantclient:${OGG_HOME}/lib
ENV_TNS_ADMIN=/u01/oggdeploy/oggtarget/etc
ENV_STREAMS_POOL_SIZE=
ENV_USER_VARS=
PORT_ADMINSRVR=9101
PORT_DISTSRVR=9102
PORT_RCVRSRVR=9103
METRICS_SERVER_ENABLED=true
PORT_PMSRVR=9104
UDP_PORT_PMSRVR=
OGG_SCHEMA=ggadmin
REMOVE_DEPLOYMENT_FROM_DISK=
EOF
render ~/oggca_target.rsp.tmpl /u01/stage/oggca_target.rsp
cd /tmp && /u01/app/ogg/ogg26ai_ma/bin/oggca.sh -silent -responseFile /u01/stage/oggca_target.rsp
```

**[root@ggtgt]** jednostka systemd. `registerServiceManager.sh` czyta ten sam plik odpowiedzi, więc usuń go dopiero po nim:

```bash
/u01/oggdeploy/ggsm01/bin/registerServiceManager.sh
rm -f /u01/stage/oggca_target.rsp
systemctl enable --now OracleGoldenGate.service
curl -s -o /dev/null -w '%{http_code}\n' http://ggtgt.gg.lab.test:9100/services/v2/deployments    # 200 albo 401
```

Etap A działa bez TLS (`SECURITY_ENABLED=false`, ścieżka `ws://`). Odpowiednik w automacie: `lab.cmd ogg`
(`guest/shared/install_ogg.sh`, `guest/tgt/86_oggca_target.sh`, `tgt/90_validate.sh ogg`).

## 15. 🧲 XAG, VIP GoldenGate i deployment źródła

**[grid@ggrac1]** XAG 10.2 na obu węzłach (MAA: GoldenGate Microservices wymaga XAG 10.2 lub nowszego; `XAG_HOME`
musi być pusty na wszystkich węzłach):

```bash
mkdir -p /u01/stage/xag_pkg && cd /u01/stage/xag_pkg && unzip -q -o /u01/stage/p31215432_190000_Generic.zip
cd /u01/stage/xag_pkg/xag && ./xagsetup.sh --install --directory /u01/app/xag --all_nodes
/u01/app/xag/bin/agctl query releaseversion
```

Kontrola **[root]** i **[oracle]** na obu węzłach: `command -v agctl` musi wypisać `/u01/app/xag/bin/agctl` (Grid home ma
starszy agctl).

**[root@ggrac1]** najpierw VIP aplikacyjny: `oggca` wiąże Service Manager źródła z nazwą `oggvip`, więc adres musi już
działać. Sieć 1 = sieć publiczna (`crsctl status resource -p -attr NAME,USR_ORA_SUBNET -w "TYPE = ora.network.type"`
pokazuje `ora.net1.network` = 192.168.58.0):

```bash
/u01/app/23.26/grid/bin/appvipcfg create -network=1 -ip=192.168.58.40 -vipname=oggvip -user=root
/u01/app/23.26/grid/bin/crsctl setperm resource oggvip -u user:oracle:r-x
/u01/app/23.26/grid/bin/crsctl start resource oggvip -n ggrac1
ip -o addr | grep 192.168.58.40                   # na ggrac1
```

**[oracle@ggrac1]** deployment źródła na ACFS, zintegrowany z XAG, niezarejestrowany jako usługa systemd (szablon
`ogg/oggca_source.rsp.tmpl`):

```bash
mountpoint /u01/oggdeploy                         # musi być tu zamontowany
cat > ~/oggca_source.rsp.tmpl <<'EOF'
oracle.install.responseFileVersion=/oracle/install/rspfmt_oggca_response_schema_v23_1_0
CONFIGURATION_OPTION=ADD
DEPLOYMENT_NAME=oggsource
ADMINISTRATOR_USER=oggadmin
ADMINISTRATOR_PASSWORD=@@OGG_ADMIN_PASS@@
SERVICEMANAGER_DEPLOYMENT_HOME=/u01/oggdeploy/ggsm01
HOST_SERVICEMANAGER=oggvip.gg.lab.test
PORT_SERVICEMANAGER=9100
SECURITY_ENABLED=false
STRONG_PWD_POLICY_ENABLED=true
CREATE_NEW_SERVICEMANAGER=true
REGISTER_SERVICEMANAGER_AS_A_SERVICE=false
INTEGRATE_SERVICEMANAGER_WITH_XAG=true
EXISTING_SERVICEMANAGER_IS_XAG_ENABLED=false
OGG_SOFTWARE_HOME=/u01/app/ogg/ogg26ai_ma
OGG_DEPLOYMENT_HOME=/u01/oggdeploy/oggsource
ENV_LD_LIBRARY_PATH=${OGG_HOME}/lib/instantclient:${OGG_HOME}/lib
ENV_TNS_ADMIN=/u01/oggdeploy/oggsource/etc
ENV_STREAMS_POOL_SIZE=
ENV_USER_VARS=
PORT_ADMINSRVR=9101
PORT_DISTSRVR=9102
PORT_RCVRSRVR=9103
METRICS_SERVER_ENABLED=true
PORT_PMSRVR=9104
UDP_PORT_PMSRVR=
OGG_SCHEMA=ggadmin
REMOVE_DEPLOYMENT_FROM_DISK=
EOF
render ~/oggca_source.rsp.tmpl /u01/stage/oggca_source.rsp
cd /tmp && /u01/app/ogg/ogg26ai_ma/bin/oggca.sh -silent -responseFile /u01/stage/oggca_source.rsp
rm -f /u01/stage/oggca_source.rsp
mkdir -p /u01/oggdeploy/oggsource/etc
cat > /u01/oggdeploy/oggsource/etc/tnsnames.ora <<'EOF'
OGGSOURCE_PDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = IPC)(KEY = LISTENER))
    (CONNECT_DATA = (SERVICE_NAME = gg_srcpdb)))
EOF
```

Alias idzie przez IPC do **lokalnego** listenera: na którymkolwiek węźle działa GoldenGate, Extract łączy się z lokalną
instancją przez serwis-singleton (MAA). Plik leży na ACFS i przenosi się razem z deploymentem.

Odpowiednik w automacie: `lab.cmd xag` (`guest/rac/85_install_xag.sh`, `87_xag_register.sh vip`, `86_oggca_source.sh`).

## 16. 🔗 Rejestracja GoldenGate w XAG

**[root@ggrac1]** jeden zasób XAG na Service Manager i jego deploymenty. Opcje są dokładnie takie jak w
`Get-AgctlAddArgs` (`host/Guest.psm1`); agctl czyta hasło `oggadmin` ze standardowego wejścia:

```bash
printf '%s\n' "$OGG_ADMIN_PASS" | agctl add goldengate oggsource --service_manager \
  --gg_home /u01/app/ogg/ogg26ai_ma \
  --config_home /u01/oggdeploy/ggsm01/etc/conf \
  --var_home /u01/oggdeploy/ggsm01/var \
  --port 9100 \
  --oracle_home /u01/app/ogg/ogg26ai_ma/lib/instantclient \
  --adminuser oggadmin \
  --user oracle --group oinstall \
  --vip_name oggvip \
  --filesystems ora.data.oggvol.acfs \
  --db_services ora.ggcdb.gg_srcpdb.svc --use_local_services \
  --nodes ggrac1,ggrac2
```

| Opcja | Znaczenie |
|---|---|
| `--service_manager` | zasób to Service Manager Microservices. Szablon XAG pokazuje samą flagę, tekst MAA pokazuje `--service_manager yes`; skrypt próbuje najpierw samej flagi, a `yes` powtarza tylko przy błędzie składni; w drodze automatycznej przyjęta forma trafia do `/root/lab/logs/xag_register.log` na ggrac1. Jeśli sama flaga u ciebie nie przejdzie, użyj `--service_manager yes` (która forma przeszła w tym labie, ten dokument nie podaje: niesprawdzone) |
| `--gg_home`, `--oracle_home` | oprogramowanie GoldenGate i dołączony do niego Instant Client |
| `--config_home`, `--var_home` | deploymentu **Service Managera** na ACFS |
| `--port`, `--adminuser` | port i administrator Service Managera: XAG loguje się nimi przy kontroli stanu |
| `--vip_name oggvip` | VIP z `appvipcfg` (agctl go nie tworzy) |
| `--filesystems` | zasób ACFS, który musi być zamontowany tam, gdzie działa GoldenGate |
| `--db_services ... --use_local_services` | GoldenGate działa na węźle, na którym działa `gg_srcpdb`, i łączy się lokalnie |
| `--nodes` | węzły, na których może działać |

```bash
agctl config goldengate oggsource
agctl start goldengate oggsource --node ggrac1
agctl status goldengate oggsource                 # ... is running on ggrac1
```

Uwaga: `agctl config goldengate <nazwa>` zwraca kod 0 także dla niezarejestrowanej nazwy (komunikat XAG-212): czytaj
tekst, nie tylko kod wyjścia. Jeśli `agctl start` pada, a proces Service Managera uruchomiony przez `oggca` wciąż działa
poza XAG, najpierw zatrzymaj ten proces.

Odpowiednik w automacie: `lab.cmd xag` (`guest/rac/87_xag_register.sh add`, `90_validate.sh ogg`). Dokumentacja: Oracle
MAA *Oracle GoldenGate Microservices Architecture on Oracle RAC* (zadania konfiguracji z XAG i ACFS); dokumentacja XAG
10.2 w paczce.

## 17. 📤 Replikacja po stronie źródła: użytkownik, Extract, Distribution Path

**[oracle@ggrac1]** (na węźle, na którym działa GoldenGate) użytkownik `ggadmin` lokalny w PDB, rola `OGG_CAPTURE` (bez
`c##ggadmin`, bez `GRANT DBA`):

```bash
render sql/02_src_users_pdb.sql /u01/stage/02_src_users_pdb.sql
sqlplus / as sysdba @/u01/stage/02_src_users_pdb.sql SRCPDB && rm -f /u01/stage/02_src_users_pdb.sql
install -D -m 640 ogg/ext1.prm /u01/oggdeploy/oggsource/etc/conf/ogg/ext1.prm
/u01/app/ogg/ogg26ai_ma/bin/adminclient
```

`ext1.prm`:

```text
EXTRACT ext1
USERIDALIAS ggsource DOMAIN OracleGoldenGate
TRANLOGOPTIONS INTEGRATEDPARAMS (max_sga_size 512, parallelism 2)
WARNLONGTRANS 2H, CHECKINTERVAL 30M
EXTTRAIL et
DDL INCLUDE MAPPED
TABLE HR.*;
TABLE SALES.*;
```

W adminclient (skrypty podają `PASSWORD <...>` przez potok; przy pisaniu ręcznie pomiń to i odpowiedz na pytanie o
hasło: zachowanie pytania niesprawdzone w tym labie):

```text
CONNECT http://oggvip.gg.lab.test:9100 DEPLOYMENT oggsource AS oggadmin
ALTER CREDENTIALSTORE ADD USER ggadmin@OGGSOURCE_PDB ALIAS ggsource DOMAIN OracleGoldenGate
ALTER CREDENTIALSTORE ADD USER oggadmin ALIAS ggtgt_dp DOMAIN OracleGoldenGate
DBLOGIN USERIDALIAS ggsource DOMAIN OracleGoldenGate
ADD SCHEMATRANDATA HR
ADD SCHEMATRANDATA SALES
ADD HEARTBEATTABLE, FREQUENCY 5
REGISTER EXTRACT ext1 DATABASE
ADD EXTRACT ext1, INTEGRATED TRANLOG, BEGIN NOW
ADD EXTTRAIL et, EXTRACT ext1
ADD PROFILE MAA AUTOSTART YES DELAY 60 AUTORESTART YES RETRIES 5 WAITSECONDS 30 RESETSECONDS 1800 DISABLEONFAILURE YES
ALTER EXTRACT ext1, PROFILE MAA
START EXTRACT ext1
ADD DISTPATH dp1 SOURCE trail://localhost:9102/services/v2/sources?trail=et TARGET ws://ggtgt.gg.lab.test:9103/services/v2/targets?trail=et AUTHENTICATION USERIDALIAS ggtgt_dp DOMAIN OracleGoldenGate
START DISTPATH dp1
INFO ALL
INFO DISTPATH dp1
```

- `ggadmin@OGGSOURCE_PDB` używa aliasu TNS z sekcji 15; hasło to hasło bazy (`LAB_PASS`).
- `ggtgt_dp` trzyma **administratora GoldenGate** celu (`OGG_ADMIN_PASS`): Distribution Path loguje się nim do
  Receivera celu.
- `REGISTER EXTRACT ext1 DATABASE` bez `CONTAINER`: Extract na poziomie PDB (nazwa PDB nie może mieć myślnika, OGG-08221).
- `FREQUENCY 5`: heartbeat co 5 s zamiast 60 s, więc lag jest mierzony dokładnie.
- Profil `MAA`: autostart 60 s po starcie deploymentu, do 5 restartów.
- Źródłem ścieżki jest `localhost`, więc działa na tym węźle, na którym akurat działa GoldenGate.

Odpowiednik w automacie: `lab.cmd oggconf`, pierwsza połowa (`guest/rac/88_oggconf_source.sh`, `ogg/setup_source.oby`,
`ogg/setup_path.oby`).

## 18. 📥 Replikacja po stronie celu: użytkownik, Parallel Replicat

**[oracle@ggtgt]** `ggadmin` w `TGTPDB` z `OGG_APPLY`, DML na tabelach demo, uprawnienia DDL (tylko w labie, dla testu
DDL):

```bash
render sql/04_tgt_users_pdb.sql /u01/stage/04_tgt_users_pdb.sql
sqlplus / as sysdba @/u01/stage/04_tgt_users_pdb.sql TGTPDB && rm -f /u01/stage/04_tgt_users_pdb.sql
install -D -m 640 ogg/rep1.prm /u01/oggdeploy/oggtarget/etc/conf/ogg/rep1.prm
/u01/app/ogg/ogg26ai_ma/bin/adminclient
```

`rep1.prm`:

```text
REPLICAT rep1
USERIDALIAS ggtarget DOMAIN OracleGoldenGate
MAP_PARALLELISM 2
MAP HR.*, TARGET HR.*;
MAP SALES.*, TARGET SALES.*;
```

```text
CONNECT http://ggtgt.gg.lab.test:9100 DEPLOYMENT oggtarget AS oggadmin
ALTER CREDENTIALSTORE ADD USER ggadmin@ggtgt.gg.lab.test:1521/TGTPDB ALIAS ggtarget DOMAIN OracleGoldenGate
DBLOGIN USERIDALIAS ggtarget DOMAIN OracleGoldenGate
ADD HEARTBEATTABLE, FREQUENCY 5
ADD CHECKPOINTTABLE ggadmin.ggs_checkpoint
ADD REPLICAT rep1, PARALLEL, EXTTRAIL et, CHECKPOINTTABLE ggadmin.ggs_checkpoint
ADD PROFILE MAA AUTOSTART YES DELAY 60 AUTORESTART YES RETRIES 5 WAITSECONDS 30 RESETSECONDS 1800 DISABLEONFAILURE YES
ALTER REPLICAT rep1, PROFILE MAA
START REPLICAT rep1
INFO ALL
```

`PARALLEL` jest ważne: bez niego `ADD REPLICAT` tworzy klasyczny Replicat. Bez ładowania początkowego: obie strony
powstały z tymi samymi wierszami startowymi (`05_demo_schema.sql`). Odpowiednik w automacie: `lab.cmd oggconf`, druga
połowa (`guest/tgt/88_oggconf_target.sh`, `ogg/setup_target.oby`).

## 19. ✅ Sprawdzenie: obciążenie i porównanie danych

Odczekaj ok. minuty (autostart profilu), potem **[oracle@ggrac1]** w adminclient `INFO ALL` (EXTRACT ext1 RUNNING),
`INFO DISTPATH dp1` (running); **[oracle@ggtgt]** `INFO ALL` (REPLICAT rep1 RUNNING).

Obciążenie z obu instancji naraz, 10 wierszy na sekundę przez 60 s, jako SYSTEM przez SCAN (dwie powłoki):

```bash
sqlplus system@//ggrac-scan.gg.lab.test:1521/srv_load1      # SQL> exec sales.loadgen.run(10, 60)
sqlplus system@//ggrac-scan.gg.lab.test:1521/srv_load2      # SQL> exec sales.loadgen.run(10, 60)
```

Potem porównanie: **[oracle@ggrac1]** `sqlplus -S / as sysdba @sql/10_compare.sql SRCPDB` i **[oracle@ggtgt]**
`sqlplus -S / as sysdba @sql/10_compare.sql TGTPDB`. Każde wypisuje wiersze `COMPARE <tabela> <wiersze> <suma>`; wszystkie
muszą być równe po obu stronach (replikacja jest asynchroniczna: powtarzaj do kilku minut).

Lag heartbeat na celu, najświeższa ścieżka (to samo zapytanie co w `tgt/90_validate.sh`), poniżej 30 s:

```sql
alter session set container = TGTPDB;
select nvl(round(min(incoming_lag + nvl(incoming_heartbeat_age, 0))
         keep (dense_rank first order by incoming_heartbeat_age nulls last)), 999) as lag_s
from ggadmin.gg_lag;
```

Odpowiednik w automacie: `lab.cmd validate` (`90_validate.sh` po obu stronach, `guest/shared/loadgen.sh 10 60`,
`guest/shared/compare.sh`). Dalej: [OPERATIONS_PL.md](OPERATIONS_PL.md).
