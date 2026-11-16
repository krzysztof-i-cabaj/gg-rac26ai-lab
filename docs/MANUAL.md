# ✋ Install path 3 — fully manual, command by command

🇬🇧 English | 🇵🇱 [Polski](MANUAL_PL.md)

[![Path](https://img.shields.io/badge/Path-3_manual-orange)]()
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26.1_+_RU_23.26.4-red)]()
[![GoldenGate](https://img.shields.io/badge/GoldenGate-23.26.4_+_XAG_10.2-blueviolet)]()
[![Source](https://img.shields.io/badge/Commands_from-guest%2F**-blue)]()

> 🎯 The whole lab **without our scripts**: the commands that `guest/**` runs, in the same order, with the same
> parameters, for people who build this on their own servers (physical, another hypervisor, a cloud). Every section
> names its automation equivalent, so you can compare with the script when something differs.

Other paths: [INSTALL_AUTO.md](INSTALL_AUTO.md) (one command), [INSTALL_STEPWISE.md](INSTALL_STEPWISE.md) (one
`lab.cmd` step at a time). Concepts used below: [CONCEPTS.md](CONCEPTS.md).

## 0. 📋 Before you start

**Notation.** **[root@ggrac1]** = as root on ggrac1; **[grid@both]** = as grid on ggrac1 and on ggrac2;
**[oracle@ggtgt]** = as oracle on ggtgt. "both" always means the two RAC nodes.

**Values.** Names, addresses and paths are the lab values from `lab.config.psd1` ([ENVIRONMENT.md](ENVIRONMENT.md)).
On your own servers replace them consistently: interface names (`enp0s3` public, `enp0s9` private), disk names,
addresses, domain.

| Item | Lab value |
|---|---|
| Domain, DNS + NTP server | `gg.lab.test`, `gginfra` 192.168.58.10 |
| RAC nodes | `ggrac1` .11 (VIP .21, private 10.58.0.11), `ggrac2` .12 (VIP .22, private 10.58.0.12) |
| SCAN, GoldenGate VIP, target | `ggrac-scan` .31 .32 .33, `oggvip` .40, `ggtgt` .50 |
| Grid home, DB home | `/u01/app/23.26/grid`, `/u01/app/oracle/product/23.26/dbhome_1` |
| GoldenGate home, XAG home, deployments | `/u01/app/ogg/ogg26ai_ma`, `/u01/app/xag`, `/u01/oggdeploy` |
| Stage directory | `/u01/stage` (Oracle ZIPs; names with spaces are easier with `_` instead) |

**Passwords.** Never on the command line, never in a file that others can read. In every root / grid / oracle shell that
needs one, read it once; response files and SQL files carry the tokens `@@LAB_PASS@@` and `@@OGG_ADMIN_PASS@@`, which
the helper below fills inside bash into a private copy:

```bash
read -rsp 'Lab password: ' LAB_PASS; echo; export LAB_PASS
read -rsp 'GoldenGate admin password: ' OGG_ADMIN_PASS; echo; export OGG_ADMIN_PASS
render() {   # render <template> <output>: tokens -> passwords, file mode 600, nothing in argv
    local t; t=$(<"$1"); t=${t//@@OGG_ADMIN_PASS@@/$OGG_ADMIN_PASS}
    ( umask 077; printf '%s\n' "${t//@@LAB_PASS@@/$LAB_PASS}" > "$2" )
}
```

`LAB_PASS`: letters, digits, `_`, at least 8. `OGG_ADMIN_PASS`: GoldenGate 23.26 requires 8–30 characters with a lower
case letter, an upper case letter, a digit and one of `- ! @ % & * . # _` (the scripts use `LAB_PASS` plus the missing
classes). Delete every rendered copy right after use.

**Files.** The Oracle ZIPs ([ENVIRONMENT.md](ENVIRONMENT.md#-software-and-versions)) go to `/u01/stage` on ggrac1 (GI,
GI RU, DB, DB RU, OPatch, GoldenGate, XAG), on ggrac2 (GoldenGate) and on ggtgt (DB, DB RU, OPatch, GoldenGate).
The repository folders `sql/` and `ogg/` are copied to the VMs as well; commands that use them (`@sql/...`, `ogg/...`) run
from the directory that holds these copies, as the user who owns it.

## 1. 🖥️ Machines

Requirements for any platform: 2 RAC nodes with 3 vCPU / 14 GB RAM / 100 GB local disk, the target with 2 vCPU / 6 GB /
80 GB, a small DNS/NTP server (1 vCPU / 2 GB / 20 GB); two shared block devices visible on both RAC nodes (60 GB for
`+DATA`, 30 GB for `+FRA`, no partitions); a public network for all, a private network between the RAC nodes only;
internet (or a local mirror) for `dnf`.

**VirtualBox** — the calls `lab.cmd build` makes (`host/modules/VmBuilder.psm1`, `lab.ps1`), on the Windows host in
PowerShell 7. Host-only network and shared disks:

```powershell
VBoxManage hostonlyif create                                   # prints the new adapter name
VBoxManage hostonlyif ipconfig "<adapter>" --ip 192.168.58.1 --netmask 255.255.255.0
VBoxManage dhcpserver remove --ifname "<adapter>"
VBoxManage createmedium disk --filename D:\VMs\gg-rac26ai-shared\gg-rac26ai-DATA1.vdi --size 61440 --format VDI --variant Fixed
VBoxManage modifymedium disk D:\VMs\gg-rac26ai-shared\gg-rac26ai-DATA1.vdi --type shareable
VBoxManage createmedium disk --filename D:\VMs\gg-rac26ai-shared\gg-rac26ai-FRA1.vdi --size 30720 --format VDI --variant Fixed
VBoxManage modifymedium disk D:\VMs\gg-rac26ai-shared\gg-rac26ai-FRA1.vdi --type shareable
```

One VM (here `ggrac1`; RAM / CPU / disk per the table in [ENVIRONMENT.md](ENVIRONMENT.md#-machines)):

```powershell
VBoxManage createvm --name ggrac1 --ostype Oracle_64 --register --basefolder D:\VMs
VBoxManage modifyvm ggrac1 --description "vbox-lab:gg-rac26ai" --memory 14336 --cpus 3 `
  --nic1 hostonly --hostonlyadapter1 "<adapter>" --nictype1 virtio --nic2 nat --nictype2 virtio `
  --boot1 disk --boot2 dvd --boot3 none --boot4 none --ioapic on --rtcuseutc on --paravirtprovider kvm `
  --graphicscontroller vmsvga --vram 16 --audio-driver none --usb off
VBoxManage createmedium disk --filename D:\VMs\ggrac1\ggrac1-os.vdi --size 102400 --format VDI
VBoxManage storagectl ggrac1 --name SATA --add sata --controller IntelAhci --portcount 2
VBoxManage storageattach ggrac1 --storagectl SATA --port 0 --type hdd --medium D:\VMs\ggrac1\ggrac1-os.vdi --nonrotational on
VBoxManage storageattach ggrac1 --storagectl SATA --port 1 --type dvddrive --medium D:\ISOs\OracleLinux-R9-U8-x86_64-boot.iso
# RAC nodes only: interconnect NIC and the shared disks
VBoxManage modifyvm ggrac1 --nic3 intnet --intnet3 ggrac-ic --nictype3 virtio
VBoxManage storagectl ggrac1 --name SATA --portcount 4
VBoxManage storageattach ggrac1 --storagectl SATA --port 2 --device 0 --type hdd --medium D:\VMs\gg-rac26ai-shared\gg-rac26ai-DATA1.vdi --mtype shareable
VBoxManage storageattach ggrac1 --storagectl SATA --port 3 --device 0 --type hdd --medium D:\VMs\gg-rac26ai-shared\gg-rac26ai-FRA1.vdi --mtype shareable
VBoxManage startvm ggrac1 --type headless
```

Automation equivalent: `lab.cmd build` (`Step-Build`, `New-SharedDisks`, `Add-VmExtras` in `lab.ps1`).

## 2. 🐧 Oracle Linux 9.8

Install from the OL 9.8 boot ISO, packages from yum.oracle.com (BaseOS latest, AppStream, **UEKR8**). The kickstart
templates `kickstart/base.ks.tmpl` and `kickstart/role-*.ks.tmpl` hold every setting; with your own install, match them:

- `selinux --enforcing`, `firewall --disabled`, timezone `Europe/Warsaw --utc`, services sshd, chronyd, NetworkManager.
- Network: `enp0s3` static (e.g. 192.168.58.11/24, hostname `ggrac1.gg.lab.test`, **no default route**), `enp0s8` DHCP
  (the only default route), on RAC nodes `enp0s9` static 10.58.0.11/24 without default route.
- Only the OS disk (`sda`): `/boot` 1 GB xfs, swap = RAM in GB (1–16 GB), `/` 30 GB xfs, `/u01` the rest (on the DNS
  server: `/` takes the rest). Leave the shared disks untouched.
- Packages: `@core openssh-server chrony firewalld bind-utils net-tools curl jq tar unzip rsync lsof vim-enhanced
  bash-completion policycoreutils-python-utils python3-dnf-plugin-versionlock kernel-uek`, plus
  `oracle-ai-database-preinstall-26ai` and `nfs-utils` (RAC), `oracle-ai-database-preinstall-26ai` (target),
  `dnsmasq` (DNS server).

Automation equivalent: `lab.cmd build` (kickstart rendered by `host/Kickstart.psm1`, boot line
`inst.ks=http://192.168.58.1:8000/kickstart/out/<vm>.ks inst.text ip=<ip>:::255.255.255.0:<fqdn>:enp0s3:none`).

## 3. 🧰 OS preparation (the kickstart `%post`)

**[root@all VMs]** SSH key, clock stepping, lab names (no SCAN here: SCAN only in DNS):

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo '<your public key>' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && restorecon -R /root/.ssh
sed -i 's/^makestep .*/makestep 1.0 -1/' /etc/chrony.conf     # step on any large offset (paused VMs)
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

**[root@both]** kernel lock (ACFS supports only certified kernels, KB129209), grid user, groups, directories, limits,
zeroconf, HugePages, profiles:

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
export ORACLE_SID=+ASM1          # +ASM2 on ggrac2
export PATH=/u01/app/xag/bin:$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:$PATH
umask 022
EOF
cat >> /home/oracle/.bash_profile <<'EOF'
export ORACLE_BASE=/u01/app/oracle
export ORACLE_HOME=/u01/app/oracle/product/23.26/dbhome_1
export ORACLE_SID=ggcdb1         # ggcdb2 on ggrac2
export OGG_HOME=/u01/app/ogg/ogg26ai_ma
export PATH=/u01/app/xag/bin:$ORACLE_HOME/bin:$ORACLE_HOME/OPatch:$OGG_HOME/bin:$PATH
umask 022
EOF
echo 'export PATH=/u01/app/xag/bin:/u01/app/23.26/grid/bin:$PATH' >> /root/.bash_profile   # XAG agctl before the GI one
```

**[root@ggtgt]** the same idea for the target (oracle only, no grid, no kernel lock):

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

Transparent HugePages: leave `madvise` (set by the 26ai preinstall package on UEK 7+); do not disable them.
Automation equivalent: kickstart `%post` (`kickstart/base.ks.tmpl`, `role-rac.ks.tmpl`, `role-tgt.ks.tmpl`).

## 4. 🌐 DNS and time server (gginfra)

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

Check: `dig +short ggrac-scan.gg.lab.test @127.0.0.1` (3 addresses), `dig +short -x 192.168.58.11 @127.0.0.1`
(`ggrac1.gg.lab.test.`), `dig +short yum.oracle.com @127.0.0.1` (forwarded), `chronyc tracking` (`Leap status : Normal`).
With an existing corporate DNS: create the same A and PTR records there, the SCAN as three A records of one name.

Automation equivalent: `lab.cmd infra` (`guest/infra/10_dnsmasq.sh`, `20_chrony.sh`, `90_validate.sh`).

## 5. 🕰️ Resolver, time, firewall (RAC nodes and ggtgt)

**[root@both]** and **[root@ggtgt]**

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

Checks before Grid Infrastructure:

```bash
chronyc -n sources                                   # ^* 192.168.58.10
dig +short ggrac-scan.gg.lab.test | sort             # 192.168.58.31 .32 .33
dig +short -x 192.168.58.11                          # ggrac1.gg.lab.test.
for h in ggrac1 ggrac2 ggrac1-priv ggrac2-priv; do ping -c1 -W2 $h >/dev/null && echo "ok $h"; done
for ip in 192.168.58.31 192.168.58.32 192.168.58.33 192.168.58.21 192.168.58.22 192.168.58.40; do ping -c1 -W1 $ip >/dev/null && echo "BUSY $ip"; done   # must print nothing
rpm -q oracle-ai-database-preinstall-26ai
cat /sys/kernel/mm/transparent_hugepage/enabled      # [madvise]
dnf versionlock list | grep kernel; uname -r         # the running kernel is a locked one
```

Automation equivalent: `lab.cmd prereq` (`guest/rac/10_os_prereq.sh`), on ggtgt the first part of `lab.cmd tgt`
(`guest/tgt/10_os_prereq.sh`).

## 6. 💾 ASM disks with udev

**[root@both]** find each shared disk by its size and bind a rule to its serial:

```bash
lsblk -dbo NAME,SIZE,TYPE                            # 64424509440 bytes = DATA1, 32212254720 = FRA1
udevadm info --query=property --name=/dev/sdb | sed -n 's/^ID_SERIAL=//p'
udevadm info --query=property --name=/dev/sdc | sed -n 's/^ID_SERIAL=//p'
cat > /etc/udev/rules.d/99-oracle-asmdevices.rules <<'EOF'
KERNEL=="sd*", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL}=="<serial of DATA1>", SYMLINK+="oracleasm/DATA1", OWNER="grid", GROUP="asmdba", MODE="0660"
KERNEL=="sd*", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", ENV{ID_SERIAL}=="<serial of FRA1>", SYMLINK+="oracleasm/FRA1", OWNER="grid", GROUP="asmdba", MODE="0660"
EOF
udevadm control --reload-rules && udevadm trigger --type=devices --action=change && udevadm settle
ls -lL /dev/oracleasm/                               # brw-rw---- grid asmdba on both nodes
```

Group `asmdba`, not `asmadmin`: the 26ai database must be able to open the devices (with `asmadmin` dbca failed with
ORA-15001). No partitions on these disks.

Automation equivalent: `lab.cmd shared` (`guest/rac/20_asm_udev.sh`).

## 7. 🔑 SSH equivalence for grid and oracle

**[grid@both]**, then the same **[oracle@both]**:

```bash
[ -f ~/.ssh/id_rsa ] || { mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -f ~/.ssh/id_rsa; }
cat ~/.ssh/id_rsa.pub          # put both nodes' keys into ~/.ssh/authorized_keys on both nodes (mode 600)
ssh-keyscan -T 5 ggrac1 ggrac1.gg.lab.test ggrac2 ggrac2.gg.lab.test 192.168.58.11 192.168.58.12 2>/dev/null | sort -u > ~/.ssh/known_hosts
for h in ggrac1 ggrac1.gg.lab.test ggrac2 ggrac2.gg.lab.test 192.168.58.11 192.168.58.12; do ssh -o BatchMode=yes $h true && echo "ok $h"; done
```

PEM format: the installers' Java SSH client has rejected the newer OpenSSH key format before (INS-06006); PEM is the
safe choice. Automation equivalent: `lab.cmd shared` (`guest/rac/30_ssh_equivalence.sh keygen|authorize|verify`).

## 8. 🧱 Grid Infrastructure 23.26 with RU 23.26.4

**[grid@ggrac1]** unpack GI, replace OPatch, unpack the RU:

```bash
cd /u01/app/23.26/grid && unzip -q -o /u01/stage/V1054596-01-OracleDatabaseGridInfrastructure23.26.1.0.0forLinux_x86-64.zip
cd /u01/app/23.26/grid && rm -rf OPatch && unzip -q -o /u01/stage/p6880880_230000_Linux-x86-64.zip
mkdir -p /u01/stage/ru_gi && cd /u01/stage/ru_gi && unzip -q -o /u01/stage/p40002013_230000_Linux-x86-64.zip   # -> 40002013/
```

**[root@ggrac1]** `CVUQDISK_GRP=oinstall rpm -ivh /u01/app/23.26/grid/cv/rpm/cvuqdisk-*.rpm`, copy the RPM to ggrac2
(`scp`), and the same command **[root@ggrac2]** with `/tmp/cvuqdisk-*.rpm`.

**[grid@ggrac1]** response file. 26ai uses the short keys (`installOption`, `scanName`, `clusterNodes` …): a 19c file
with `oracle.install.*` keys does not work. Compare yours with `/u01/app/23.26/grid/install/response/gridsetup.rsp`.
Template: `response/gridsetup.rsp.tmpl`; filled with the lab values:

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

Return code 0 = OK, 6 = OK with warnings (read the log in `/u01/app/oraInventory/logs`).

**[root@ggrac1]**, then **[root@ggrac2]**, one after the other (never in parallel):

```bash
/u01/app/oraInventory/orainstRoot.sh
/u01/app/23.26/grid/root.sh          # log: /u01/app/23.26/grid/install/root_<node>*.log; a re-run resumes from its checkpoint
```

**[root@both]** AHF / TFA off, right after `root.sh` (on 2–3 vCPU nodes it starved the database, see
[PITFALLS_26AI.md](PITFALLS_26AI.md); re-enable later with `systemctl enable --now oracle-tfa`):

```bash
timeout 600 /opt/oracle.ahf/bin/ahfctl stopahf -all
systemctl disable --now oracle-tfa.service
systemctl is-active oracle-tfa.service              # inactive
```

**[grid@ggrac1]** configuration tools, then `+FRA`:

```bash
cd /tmp && /u01/app/23.26/grid/gridSetup.sh -silent -executeConfigTools -responseFile /u01/stage/grid.rsp
rm -f /u01/stage/grid.rsp
asmca -silent -createDiskGroup -diskGroupName FRA -disk '/dev/oracleasm/FRA1' -redundancy EXTERNAL -au_size 4 \
      -compatible.asm 23.0.0.0.0 -compatible.rdbms 23.0.0.0.0
srvctl start diskgroup -diskgroup FRA               # asmca mounts it only where it ran
```

Checks **[grid@ggrac1]**: `crsctl check cluster -all` (online, nothing offline), `olsnodes -n` (2 nodes),
`srvctl status scan_listener` (3 running), `srvctl status scan` (3 VIPs), `asmcmd lsdg` (`DATA/`, `FRA/`). GI 23.26 has
no `ora.ctssd` resource and no `crsctl check ctss`: chrony keeps the time.

Automation equivalent: `lab.cmd grid` (`guest/rac/40_install_grid.sh stage|cvuqdisk|install|root|ahf|config|fra`,
`90_validate.sh grid`). Reference: *Oracle Grid Infrastructure Installation and Upgrade Guide for Linux* (silent
installation with a response file).

## 9. 🗄️ Database software (both nodes from ggrac1)

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

**[root@ggrac1]**, then **[root@ggrac2]**: `/u01/app/oracle/product/23.26/dbhome_1/root.sh`

Check **[oracle@both]**: `$ORACLE_HOME/OPatch/opatch lspatches`.
Automation equivalent: `lab.cmd db` (`guest/shared/install_db.sh stage|install|root`, response `response/db_install.rsp.tmpl`).

## 10. 🏛️ Source RAC CDB `ggcdb`

**[oracle@ggrac1]** (template `response/dbca_src.rsp.tmpl`):

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

`26112` MB = 85 % of the 30 GB `+FRA`. What `01_src_prep_cdb.sql` does, if you prefer to type it:

```sql
ALTER SYSTEM SET enable_goldengate_replication=TRUE SCOPE=BOTH SID='*';
ALTER SYSTEM SET streams_pool_size=1280M SCOPE=BOTH SID='*';     -- MAA: 1 Extract x 1 GB x 1.25
ALTER DATABASE FORCE LOGGING;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SYSTEM ARCHIVE LOG CURRENT;
ALTER PLUGGABLE DATABASE SRCPDB OPEN INSTANCES=ALL;
```

The database must be in ARCHIVELOG mode (hence `-enableArchive true`). Automation equivalent: `lab.cmd dbca`
(`guest/rac/60_create_db.sh`).

## 11. 🧭 Services and demo data

**[oracle@ggrac1]**

```bash
srvctl add service -db ggcdb -service gg_srcpdb -pdb SRCPDB -preferred ggcdb1 -available ggcdb2
srvctl add service -db ggcdb -service srv_load1 -pdb SRCPDB -preferred ggcdb1 -available ggcdb2
srvctl add service -db ggcdb -service srv_load2 -pdb SRCPDB -preferred ggcdb2 -available ggcdb1
for s in gg_srcpdb srv_load1 srv_load2; do srvctl start service -db ggcdb -service $s; srvctl status service -db ggcdb -service $s; done
sqlplus / as sysdba @sql/05_demo_schema.sql SRCPDB
sqlplus / as sysdba @sql/06_loadgen.sql SRCPDB
```

`gg_srcpdb` is a singleton (one preferred, one available instance): the Extract connects through it, and XAG keeps
GoldenGate on the node where it runs (`--use_local_services`, section 16). 26ai `srvctl status service` prints
"running on instances: …" (older releases: "instance(s)"). Automation equivalent: `lab.cmd services`
(`guest/rac/65_services.sh`, `90_validate.sh db`).

## 12. 🎯 Target database `tgtcdb` (ggtgt)

**[oracle@ggtgt]** software: as in section 9 (unzip DB, OPatch, RU into `/u01/stage/ru_db`), with `clusterNodes=`
**empty** in `db_install.rsp`; then **[root@ggtgt]** `/u01/app/oraInventory/orainstRoot.sh` (first install on this VM)
and `/u01/app/oracle/product/23.26/dbhome_1/root.sh`.

**[oracle@ggtgt]** listener and database (template `response/dbca_tgt.rsp.tmpl`):

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

**[root@ggtgt]** autostart. With SELinux Enforcing, systemd cannot execute `dbstart` from the Oracle home
(`203/EXEC Permission denied`, the home is labelled `default_t`); letting bash read the script works:

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

**[oracle@ggtgt]** GoldenGate parameter, PDB state, the same demo tables and seed rows as the source (no initial load):

```bash
sqlplus / as sysdba @sql/03_tgt_prep_cdb.sql TGTPDB     # enable_goldengate_replication, FORCE LOGGING, TGTPDB OPEN + SAVE STATE
sqlplus / as sysdba @sql/05_demo_schema.sql TGTPDB
```

Automation equivalent: `lab.cmd tgt` (`guest/tgt/10_os_prereq.sh`, `50_install_db.sh`, `60_create_db.sh`,
`90_validate.sh db`).

## 13. 📂 ACFS for the GoldenGate deployment

**[root@both]**

```bash
/u01/app/23.26/grid/bin/acfsdriverstate supported      # must print ACFS-9200 (supported)
/u01/app/23.26/grid/bin/acfsdriverstate loaded || /u01/app/23.26/grid/bin/acfsload start
mkdir -p /u01/oggdeploy
```

**[grid@ggrac1]**

```bash
asmcmd volcreate -G DATA -s 20G OGGVOL
asmcmd volinfo -G DATA OGGVOL          # "Volume Device: /dev/asm/oggvol-NNN"
```

**[root@ggrac1]** (`NNN` from `volinfo`; format only an empty volume):

```bash
/sbin/mkfs -t acfs /dev/asm/oggvol-NNN
/u01/app/23.26/grid/bin/srvctl add filesystem -device /dev/asm/oggvol-NNN -volume OGGVOL -diskgroup DATA \
    -path /u01/oggdeploy -user oracle -autostart RESTORE
/u01/app/23.26/grid/bin/srvctl start filesystem -volume OGGVOL -diskgroup DATA -node ggrac1
chown oracle:oinstall /u01/oggdeploy && chmod 775 /u01/oggdeploy
/u01/app/23.26/grid/bin/crsctl stat res ora.data.oggvol.acfs -t     # ONLINE on ggrac1 only
```

Mounted on **one** node (MAA): XAG moves it with GoldenGate. Automation equivalent: `lab.cmd acfs`
(`guest/rac/70_acfs.sh prep|create`). Reference: *Oracle Automatic Storage Management Administrator's Guide* (ACFS).

## 14. 🔁 GoldenGate software and the target deployment

**[oracle@ggrac1]**, **[oracle@ggrac2]**, **[oracle@ggtgt]**: local software in each

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

`INSTALL_OPTION=ORA23ai`: compare with `/u01/stage/ogg/*/Disk1/response/oggcore.rsp` of your release (the online page
still lists older values). If `/etc/oraInst.loc` is missing afterwards: **[root]** `/u01/app/oraInventory/orainstRoot.sh`.
A separate bundle patch (not needed with the complete-install ZIP) would be `opatch apply -silent` with
`ORACLE_HOME=/u01/app/ogg/ogg26ai_ma`, with GoldenGate stopped.

**[oracle@ggtgt]** Service Manager and the target deployment (template `ogg/oggca_target.rsp.tmpl`):

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

**[root@ggtgt]** systemd unit. `registerServiceManager.sh` re-reads the same response file, so remove it only afterwards:

```bash
/u01/oggdeploy/ggsm01/bin/registerServiceManager.sh
rm -f /u01/stage/oggca_target.rsp
systemctl enable --now OracleGoldenGate.service
curl -s -o /dev/null -w '%{http_code}\n' http://ggtgt.gg.lab.test:9100/services/v2/deployments    # 200 or 401
```

Stage A runs without TLS (`SECURITY_ENABLED=false`, `ws://` path). Automation equivalent: `lab.cmd ogg`
(`guest/shared/install_ogg.sh`, `guest/tgt/86_oggca_target.sh`, `tgt/90_validate.sh ogg`).

## 15. 🧲 XAG, the GoldenGate VIP and the source deployment

**[grid@ggrac1]** XAG 10.2 on both nodes (MAA: GoldenGate Microservices needs XAG 10.2 or later; `XAG_HOME` must be
empty on all nodes):

```bash
mkdir -p /u01/stage/xag_pkg && cd /u01/stage/xag_pkg && unzip -q -o /u01/stage/p31215432_190000_Generic.zip
cd /u01/stage/xag_pkg/xag && ./xagsetup.sh --install --directory /u01/app/xag --all_nodes
/u01/app/xag/bin/agctl query releaseversion
```

Check **[root]** and **[oracle]** on both nodes: `command -v agctl` must print `/u01/app/xag/bin/agctl` (the GI home has
an older agctl).

**[root@ggrac1]** the application VIP first: `oggca` binds the source Service Manager to the `oggvip` name, so the
address must already be up. Network 1 = the public network (`crsctl status resource -p -attr NAME,USR_ORA_SUBNET -w
"TYPE = ora.network.type"` shows `ora.net1.network` = 192.168.58.0):

```bash
/u01/app/23.26/grid/bin/appvipcfg create -network=1 -ip=192.168.58.40 -vipname=oggvip -user=root
/u01/app/23.26/grid/bin/crsctl setperm resource oggvip -u user:oracle:r-x
/u01/app/23.26/grid/bin/crsctl start resource oggvip -n ggrac1
ip -o addr | grep 192.168.58.40                   # on ggrac1
```

**[oracle@ggrac1]** source deployment on ACFS, integrated with XAG, not registered as a systemd service (template
`ogg/oggca_source.rsp.tmpl`):

```bash
mountpoint /u01/oggdeploy                         # must be mounted here
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

The alias goes through IPC to the **local** listener: whichever node runs GoldenGate, the Extract connects to the local
instance through the singleton service (MAA). The file lives on ACFS and moves with the deployment.

Automation equivalent: `lab.cmd xag` (`guest/rac/85_install_xag.sh`, `87_xag_register.sh vip`, `86_oggca_source.sh`).

## 16. 🔗 Register GoldenGate with XAG

**[root@ggrac1]** one XAG resource for the Service Manager and its deployments. The options are exactly those of
`Get-AgctlAddArgs` (`host/Guest.psm1`); agctl reads the `oggadmin` password from standard input:

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

| Option | Meaning |
|---|---|
| `--service_manager` | the resource is a Microservices Service Manager. The XAG template shows a bare flag, MAA text shows `--service_manager yes`; the script tries the bare flag first and repeats with `yes` only on a syntax error; in the automated path the accepted form is written to `/root/lab/logs/xag_register.log` on ggrac1. If the bare flag fails for you, use `--service_manager yes` (which form XAG 10.2 accepted in this lab is not recorded in this document) |
| `--gg_home`, `--oracle_home` | GoldenGate software, and its bundled Instant Client |
| `--config_home`, `--var_home` | of the **Service Manager** deployment on ACFS |
| `--port`, `--adminuser` | Service Manager port and administrator: XAG logs in for its health check |
| `--vip_name oggvip` | the VIP from `appvipcfg` (not created by agctl) |
| `--filesystems` | ACFS resource that must be mounted where GoldenGate runs |
| `--db_services ... --use_local_services` | GoldenGate runs on the node where `gg_srcpdb` runs, and connects locally |
| `--nodes` | candidate nodes |

```bash
agctl config goldengate oggsource
agctl start goldengate oggsource --node ggrac1
agctl status goldengate oggsource                 # ... is running on ggrac1
```

Note: `agctl config goldengate <name>` returns code 0 also for a name that is not registered (message XAG-212): read
the text, not only the exit code. If `agctl start` fails while a Service Manager process started by `oggca` still runs
outside XAG, stop that process first.

Automation equivalent: `lab.cmd xag` (`guest/rac/87_xag_register.sh add`, `90_validate.sh ogg`). References: Oracle MAA
*Oracle GoldenGate Microservices Architecture on Oracle RAC* (configuration tasks with XAG and ACFS); the XAG 10.2
documentation in the package.

## 17. 📤 Source replication: user, Extract, Distribution Path

**[oracle@ggrac1]** (on the node where GoldenGate runs) user `ggadmin` local to the PDB, role `OGG_CAPTURE` (no
`c##ggadmin`, no `GRANT DBA`):

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

In adminclient (the scripts send `PASSWORD <...>` through a pipe; typed by hand, leave it out and answer the prompt:
prompt behaviour not verified in this lab):

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

- `ggadmin@OGGSOURCE_PDB` uses the TNS alias of section 15; the password is the database password (`LAB_PASS`).
- `ggtgt_dp` holds the **GoldenGate admin** of the target (`OGG_ADMIN_PASS`): the Distribution Path logs in to the
  target Receiver with it.
- `REGISTER EXTRACT ext1 DATABASE` without `CONTAINER`: per-PDB Extract (the PDB name must not contain a dash, OGG-08221).
- `FREQUENCY 5`: heartbeat every 5 s instead of 60 s, so lag is measured finely.
- Profile `MAA`: autostart 60 s after the deployment starts, up to 5 restarts.
- The path source is `localhost`, so it works on whichever node runs GoldenGate.

Automation equivalent: `lab.cmd oggconf`, first half (`guest/rac/88_oggconf_source.sh`, `ogg/setup_source.oby`,
`ogg/setup_path.oby`).

## 18. 📥 Target replication: user, Parallel Replicat

**[oracle@ggtgt]** `ggadmin` in `TGTPDB` with `OGG_APPLY`, DML on the demo tables, DDL privileges (lab only, for the DDL
test):

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

`PARALLEL` matters: without it `ADD REPLICAT` creates a classic Replicat. No initial load: both sides were created with
the same seed rows (`05_demo_schema.sql`). Automation equivalent: `lab.cmd oggconf`, second half
(`guest/tgt/88_oggconf_target.sh`, `ogg/setup_target.oby`).

## 19. ✅ Check: load and data comparison

Wait about a minute (profile autostart), then **[oracle@ggrac1]** adminclient `INFO ALL` (EXTRACT ext1 RUNNING),
`INFO DISTPATH dp1` (running); **[oracle@ggtgt]** `INFO ALL` (REPLICAT rep1 RUNNING).

Load from both instances at the same time, 10 rows per second for 60 s, as SYSTEM through the SCAN (two shells):

```bash
sqlplus system@//ggrac-scan.gg.lab.test:1521/srv_load1      # SQL> exec sales.loadgen.run(10, 60)
sqlplus system@//ggrac-scan.gg.lab.test:1521/srv_load2      # SQL> exec sales.loadgen.run(10, 60)
```

Then compare: **[oracle@ggrac1]** `sqlplus -S / as sysdba @sql/10_compare.sql SRCPDB` and **[oracle@ggtgt]**
`sqlplus -S / as sysdba @sql/10_compare.sql TGTPDB`. Each prints `COMPARE <table> <rows> <hash>` lines; all must be equal
on both sides (replication is asynchronous: repeat for up to a few minutes).

Heartbeat lag on the target, freshest path (the same query as `tgt/90_validate.sh`), below 30 s:

```sql
alter session set container = TGTPDB;
select nvl(round(min(incoming_lag + nvl(incoming_heartbeat_age, 0))
         keep (dense_rank first order by incoming_heartbeat_age nulls last)), 999) as lag_s
from ggadmin.gg_lag;
```

Automation equivalent: `lab.cmd validate` (`90_validate.sh` on both sides, `guest/shared/loadgen.sh 10 60`,
`guest/shared/compare.sh`). Next: [OPERATIONS.md](OPERATIONS.md).
