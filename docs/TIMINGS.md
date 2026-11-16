# ⏱️ Timings — how long each step takes

🇬🇧 English | 🇵🇱 [Polski](TIMINGS_PL.md)

[![Build](https://img.shields.io/badge/Clean_build-about_4_h_04_min-blue)]()
[![Measured](https://img.shields.io/badge/Measured-VirtualBox_laptop-orange)]()
[![Baseline](https://img.shields.io/badge/baseline-median_67_s-success)]()
[![Status](https://img.shields.io/badge/Build_table-to_be_remeasured-yellow)]()

> 🎯 Clean durations of every build step, and of the daily verbs, measured on this lab. "Clean" means: the time a step
> needs when nothing fails, without the fixes and repeated attempts of the first build. Use them to plan your own
> build, not as a benchmark: they come from VirtualBox on a laptop.

## 📏 Measurement conditions

- Host: Windows 11 laptop, 64 GB RAM, VirtualBox 7, Windows hypervisor **off**. Measured in November 2026.
- Durations come from the lab's step log `logs/steps.csv` (kept locally, not in the repository; start and end of every `lab.cmd` step, UTC) and, where a step had to be repeated,
  from the Oracle logs of the successful part (installer, `root.sh`, dbca, asmca, oggca logs).
- **All build steps ran with 2 vCPU per RAC node**; the RAC nodes had **10 GB RAM** during `grid` and `db`, 14 GB from
  `dbca` on. Today's configuration is 3 vCPU / 14 GB (see [ENVIRONMENT.md](ENVIRONMENT.md)), so `grid` and especially
  `db` (the nodes swapped) are upper values. The daily verbs (`baseline`, `start`, `stop`) were measured with 3 vCPU / 14 GB.
- `build` downloads the OS packages from yum.oracle.com: your internet speed changes it.
- A full build from scratch on the current settings is still to be done; this table will be replaced by it.

## 🏗️ Build steps (`lab.cmd all`)

| Step | Clean time | What is inside | Note |
|---|---|---|---|
| `build` | 9 min 57 s | 4 VMs, OS install from kickstarts | full build after `destroy` |
| `infra` | 13 s | dnsmasq, chrony, checks | |
| `prereq` | 2 min 03 s | resolver, time, OS checks on 2 nodes | fresh VMs |
| `shared` | 50 s | udev, SSH equivalence | |
| `grid` | **1 h 28 min** | see below | 2 vCPU, 10 GB |
| `db` | **1 h 35 min** | stage 37 min 37 s (copy and unzip DB, RU, OPatch), applying the RU 51 min 08 s, install 5 min 58 s, `root.sh` a few seconds on each node | inflated: the nodes swapped with 10 GB |
| `dbca` | 7 min 00 s | RAC CDB with one PDB, prep SQL | full run from zero |
| `services` | 28 s | 3 services, demo schema, load generator | |
| `tgt` | about 30 min (± 30 s) | stage 13 min 16 s, DB install 11 min 32 s, `root.sh` 1 s, dbca 4 min 38 s, demo schema | |
| `acfs` | 43 s | volume, file system, resource | |
| `ogg` | 5 min 40 s | copy of the ZIP and three installs of about 20 s each (304 s together), target `oggca` 13 s, registration and checks 23 s | |
| `xag` | 1 min 30 s | XAG install 10–19 s; VIP, source `oggca` (35 s), `agctl add`, checks | |
| `oggconf` | about 35 s | source about 8 s, path about 10 s, target 17 s | approximate |
| `validate` | 1 min 40 s | checks, 60 s load, data comparison | |
| **Total** | **about 4 h 04 min** (14 625 s) | `build` … `validate` | without fixes and retries |

### Inside `grid`

| Phase | Clean time |
|---|---|
| copy the ZIPs, unzip GI / OPatch / RU, `cvuqdisk` (stage) | 10 min 18 s (upper bound) |
| `gridSetup.sh -silent` with `-applyRU` (software) | 29 min 28 s |
| `root.sh` on ggrac1 | 8 min 09 s |
| `root.sh` on ggrac2 (after node 1) | 17 min 50 s |
| `gridSetup.sh -executeConfigTools` | 15 min 30 s |
| `asmca` for `+FRA` | 3 min 08 s |
| validation | 3 min 47 s |
| **grid together** | **1 h 28 min 10 s** |

The installer messages in the scripts give rough expectations ("30–40 min" for `gridSetup.sh`, "10–20 min" for
`root.sh`, "40–70 min" for the RAC `dbca`); the measured values are in the tables above.

## 🔁 Daily verbs (measured with 3 vCPU / 14 GB)

| Verb | Measured | Runs |
|---|---|---|
| `lab.cmd baseline` | median 67 s; 50 s when the lab is already in the base state; up to 640 s right after a destructive test | 38 |
| `baseline` after a full restart of all VMs | 347 s: cluster 31 s, instances 78 s, services 66 s, ACFS 3 s, processes 96 s | 1 |
| `lab.cmd start` (all VMs off → base state) | 365 s (it ends with `baseline`) | 1 full cold start |
| `lab.cmd stop` (whole lab, ACPI) | 111–198 s | 3 |
| `lab.cmd validate` | 100 s | built lab |
| `lab.cmd iso` with the ISO present | 2–3 s | 9 |

Why `baseline` varies: after a power-off test the VM must boot and Clusterware must rejoin the node before services and
GoldenGate can move back; in the base state every phase only checks (`noop`).

Failure test durations (RTO, lag, time back to the base state) are in [RESULTS.md](RESULTS.md).
