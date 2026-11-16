# 🪤 Pitfalls — Oracle AI Database 26ai and GoldenGate 23.26

🇬🇧 English | 🇵🇱 [Polski](PITFALLS_26AI_PL.md)

[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![GoldenGate](https://img.shields.io/badge/GoldenGate-23.26.4-blueviolet)]()
[![Found](https://img.shields.io/badge/Found_by-building_the_lab-orange)]()
[![Fixed](https://img.shields.io/badge/Status-fixed_in_scripts-success)]()

> 🎯 What broke while building this lab with 26ai and GoldenGate 23.26, and what the scripts do about it. If you port
> 19c scripts or runbooks to 26ai, most of these will hit you too. Each row: step, symptom, cause, fix. A separate
> table lists what came from VirtualBox and the laptop, not from the Oracle release.

## 🔴 Release-related (26ai / GI 23.26 / GoldenGate 23.26)

| Step | Symptom | Cause | Fix in the scripts |
|---|---|---|---|
| prereq | a check "Transparent HugePages = never" fails | 26ai on UEK 7+ wants THP = `madvise`, set by the preinstall package; the old rule said `never` | checks for `madvise`, no own `disable-thp` service |
| grid, db | the response-file check stops the step before the installer | 26ai response files use short keys (`installOption`, `scanName`, `clusterNodes` …); the 19c `oracle.install.*` names are gone | `gridsetup.rsp` and `db_install.rsp` rewritten; every key is compared with the sample shipped in the release (`rsp_keys_check` in `guest/lib.sh`) |
| grid | a freshly unzipped GI home is taken for an interrupted install | the 23.26 GI image ZIP already contains `root.sh` | "interrupted" = home in the inventory without `CRS="true"` and without the install marker |
| grid | validation: no `ora.ctssd`, `crsctl check ctss` does not exist | GI 23.26 has no CTSS any more | check "CTSS absent or Observer"; chrony keeps the time |
| grid, after a restart | instance `ggcdb1` terminated by LMHB (ORA-29770, LMD0 not responding), node load far above its vCPU | AHF/TFA installed with GI 23.26 (rediscovery and ADR scans) starved a 2 vCPU node | phase `ahf` right after `root.sh`: `ahfctl stopahf -all`, `systemctl disable --now oracle-tfa.service` (it has `Restart=always`); RAC nodes get 3 vCPU; validation checks that TFA is off |
| dbca | ORA-15001, the database does not see the ASM disks (the GI installer warned with PRVF-9992) | the 26ai database runs with group `asmdba`; the disks had `asmadmin` | udev rule `grid:asmdba 0660` |
| services | service checks fail although the services run | 26ai `srvctl status service` prints "running on instances", not "running on instance(s)" | checks accept both forms |
| services | ORA-01722 reading `streams_pool_size` | `gv$parameter` in 26ai returns a non-numeric value (`DISABLED`) | `to_number(value default null on conversion error)` |
| ogg | `oggca` rejects the administrator password (INS-85080) | GoldenGate 23.26 enforces a strong password: 8–30 characters, lower, upper, digit and one of `- ! @ % & * . # _` | own GoldenGate admin password = lab password plus the missing classes (`ogg_admin_pass`) |
| ogg | `registerServiceManager.sh` fails | it re-runs `oggca.sh` with the same response file (checkpoint) | the response file stays until the end of the step |
| ogg | `INSTALL_OPTION` value not in the online documentation | the docs page still lists older values; the shipped sample has `ORA23ai` | compared with the shipped sample; a mismatch is a warning |
| xag | the script "sees" a resource that does not exist | `crsctl status resource <missing>` returns 0 (CRS-2613) and `agctl config goldengate <missing>` returns 0 (XAG-212) | existence = a `NAME=` line, and no XAG-212 in the text |
| xag | `--service_manager` written two ways | the XAG template shows a bare flag, MAA text `--service_manager yes` | the script tries the bare flag, then `yes` only on a syntax error |
| oggconf | `adminclient` exits with code 2 | adminclient 23.26 returns 2 after any failed command, for example deleting an alias that does not exist yet | alias deletes in a separate session; the result is checked by `validate`, not by the exit code |
| oggconf | ORA-03405 "End of query reached; no additional text should follow" | the 26ai server rejects a `-- comment` after the semicolon on the same line (19c habit) | comments on their own lines; a static test forbids the pattern |
| oggconf | `REGISTER EXTRACT` fails for a PDB with a dash in its name | OGG-08221 / ORA-44004 | config check: PDB names without a dash |
| tgt, after a restart | the target database does not start at boot: `203/EXEC Permission denied` on `dbstart` | SELinux Enforcing, the Oracle home carries the label `default_t`, systemd may not execute files from it | `ExecStart=/usr/bin/bash $ORACLE_HOME/bin/dbstart …` (bash reads the script); validation checks that the unit is active |

## 🟠 Cluster behaviour you should expect (not bugs)

| Situation | What happens | How the lab handles it |
|---|---|---|
| full restart of the cluster | instances start by themselves; services start on whichever instance is first (possibly the *available* one); ACFS with `AUTO_START=restore` is mounted on both nodes | `lab.cmd baseline` moves services and GoldenGate back and unmounts ACFS on the other node |
| manual `srvctl start instance` right after a cluster start | PRCZ-4054: CRS is starting it at the same moment | `baseline` waits up to 300 s for the CRS autostart; PRCZ-4054 counts as started |
| GoldenGate after a cluster start | the XAG health check took longer than its 60 s script timeout on a busy node; CRS cleaned the resource although GoldenGate had started | `baseline` waits 120 s, then up to three `agctl start` tries |
| `crsctl stop cluster -all` from one node | that node stops first and CRS moves GoldenGate, VIP and ACFS to the other node before it stops too | orderly shutdown: `agctl stop goldengate` first, then databases, then `crsctl stop crs` node by node ([OPERATIONS.md](OPERATIONS.md#-orderly-shutdown-recommended-manual-for-now)) |
| repeated instance crashes | `ora.ggcdb.db` restarts an instance at most twice per hour (`RESTART_ATTEMPTS=2`, `UPTIME_THRESHOLD=1h`, defaults); the third crash leaves it down | known in the test results; a manual `srvctl start instance` resets the counter |
| heartbeat lag after a relocation | `ggadmin.gg_lag` keeps one row per path; the path from the old node only ages, so `max()` grows forever | lag = lag + age of the **freshest** path (`probe.sh`, `tgt/90_validate.sh`) |
| ACFS after a relocation | the old node can still show the file system ONLINE | the entry on the node of the VIP wins in the probe |

## 🟡 Not from 26ai: VirtualBox, laptop, lab plumbing

| Symptom | Cause | Fix |
|---|---|---|
| everything several times slower, guest clocks jump, `VBox.log`: `fall back to NEM` | Windows hypervisor (Hyper-V / VBS, Memory integrity) on | lab runs with the hypervisor off ([ENVIRONMENT.md](ENVIRONMENT.md#windows-hypervisor-off)) |
| `VBox.log`: `Giving up catch-up attempt at a 60 s lag`; time-outs end too early | the guest clock is stepped by chrony after VirtualBox gives up catching up | `makestep 1.0 -1` in chrony; script time-outs count `/proc/uptime`, not the wall clock |
| the OS installer of gginfra stood still on "Checking storage configuration" | 1 GB RAM was too little | gginfra has 2 GB |
| `VBoxManage` fails with a session lock | a VM still held by another VBoxManage call | retries in `Invoke-VBox` |
| `chronyc sources` check never matched | `chronyc` printed a name instead of the address | `chronyc -n` |
| kernel lock in `%post` failed | no working DNS during the kickstart (gginfra not configured yet) | `dnf versionlock` with `--disablerepo='*'` |
| interconnect traffic blocked | `firewalld` zones | no firewall inside the VMs (host-only lab network) |
| the listener on ggtgt held the step lock, the next step waited | a daemon started by a step inherited the `flock` | `flock -o` in `run_step.sh` |
| a dropped SSH session killed `dbca` | `SIGPIPE` through `tee` | steps run detached (`setsid`, output to a file) |
| kickstart server answered but VMs did not install | the firewall rule of another lab on port 8000 did not allow this subnet | the rule must allow 192.168.58.0/24 |
| `python.exe` found but the kickstart server did not start | the Microsoft Store stub | the real Python 3.8+ is searched for |

## 📚 Where this is documented by Oracle

- Response files and silent installs: *Oracle Grid Infrastructure Installation and Upgrade Guide for Linux* and *Oracle
  Database Installation Guide for Linux* (26ai); the samples in `<home>/install/response/` are the reliable source.
- Transparent HugePages on UEK: the same installation guides, chapter on configuring the OS.
- ACFS and kernels: My Oracle Support document KB129209 (which kernels ACFS supports).
- GoldenGate password policy and `oggca` response files: *Oracle GoldenGate Microservices Documentation* (Deploy).
- XAG and GoldenGate on RAC: Oracle MAA, *Oracle GoldenGate Microservices Architecture on Oracle RAC*.
