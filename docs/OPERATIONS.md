# 🛠️ Operations — status, start, stop, baseline, troubleshooting

🇬🇧 English | 🇵🇱 [Polski](OPERATIONS_PL.md)

[![Verbs](https://img.shields.io/badge/lab.cmd-status_start_stop_baseline_validate-blue)]()
[![Base state](https://img.shields.io/badge/Base_state-stage_A-success)]()
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![GoldenGate](https://img.shields.io/badge/GoldenGate-23.26_+_XAG-blueviolet)]()

> 🎯 Daily use of a built lab: what each `lab.cmd` verb does, what the lab looks like after a full restart, how
> `baseline` puts it back into the base state, how to shut it down without GoldenGate jumping to the other node, and
> what to do when something does not come back.

## 🧭 The base state

All failure tests start from it and `validate` checks it ("stage A"):

- all four VMs running; both RAC instances `ggcdb1`, `ggcdb2` open, `SRCPDB` open on both;
- services on their **preferred** instances: `gg_srcpdb` and `srv_load1` on `ggcdb1`, `srv_load2` on `ggcdb2`;
- GoldenGate (XAG resource `xag.oggsource.goldengate`), VIP `oggvip` and ACFS `/u01/oggdeploy` **together on the node of
  `gg_srcpdb`** (ggrac1), ACFS mounted on that node only;
- EXT1 and DP1 RUNNING on the source, REP1 RUNNING on ggtgt, heartbeat lag below 30 s;
- ggtgt: `oracle-db.service` and `OracleGoldenGate.service` active.

## ⌨️ Verbs

| Verb | What it does |
|---|---|
| `lab.cmd status` | name, address and VirtualBox state of each VM. Reads only |
| `lab.cmd ssh <vm>` | interactive root shell on one VM (same key and options as the scripts) |
| `lab.cmd start [vm]` | starts powered-off VMs in config order (gginfra first: DNS and time). Without a VM name it then runs `baseline` |
| `lab.cmd stop [vm]` | presses the ACPI power button: ggtgt first, then the RAC nodes, gginfra last; waits until each VM is off |
| `lab.cmd baseline` | back to the base state after a restart or a failure test, data untouched (details below) |
| `lab.cmd validate` | every check on both sides, 60 s of load, source = target comparison; ends with `== VALID` |
| `lab.cmd destroy <vm\|all>` | removes VMs and their disks, only VMs tagged `vbox-lab:gg-rac26ai` |
| `lab.cmd plan` | read-only preview, also useful on a built lab (state column) |

`stop` and `start` do not care what runs inside the VMs. For the RAC side use the orderly shutdown below before `stop`.

## ♻️ `baseline` — what it restores

`baseline` first powers on any VM that is off (after tests T2, T3) and switches the interconnect NIC of both RAC nodes
back on (after test T7), waits for SSH on all VMs, then runs `guest/tgt/95_baseline.sh` and `guest/rac/95_baseline.sh`.
Phases, each printed as a `BASELINE <phase> <seconds> done|noop` line and written to `logs\baseline_steps.csv`:

| Node | Phase | What happens |
|---|---|---|
| ggtgt | `tgt_db` | starts `oracle-db.service` if needed, waits up to 600 s for `TGTPDB` READ WRITE |
| ggtgt | `tgt_ogg` | starts `OracleGoldenGate.service` if needed, waits up to 300 s for REP1 RUNNING (profile MAA starts it) |
| ggrac1 | `cluster` | waits up to 900 s until `crsctl check cluster -all` is online and both nodes are Active |
| ggrac1 | `instances` | gives CRS up to 300 s to start the instances itself, then `srvctl start instance` for any still down |
| ggrac1 | `services` | each service back on its preferred instance: `srvctl relocate service -oldinst -newinst` for the singleton, `srvctl start service -instance` for the others. CRS never moves a service back by itself |
| ggrac1 | `goldengate` | GoldenGate on the node of `gg_srcpdb`: `agctl relocate goldengate` if it runs elsewhere; if it is down, 120 s grace (CRS may be starting it), then up to three `agctl start goldengate --node` tries |
| ggrac1 | `acfs` | `srvctl stop filesystem -node <other>` where ACFS is mounted but GoldenGate does not run |
| ggrac1 | `processes` | waits up to 300 s for VIP, ACFS, service and Service Manager ONLINE on one node and EXT1 and DP1 RUNNING |

Then the same checks as `validate`, **without** the load and without the data comparison. The end:
`== BASELINE: lab in the base state (stage A) after N s`.

`baseline` does **not**: change data, delete or recreate GoldenGate objects, run load, compare data, reset the CRS
restart counters of the database resource, re-enable AHF/TFA. If a process stays ABENDED, `baseline` fails on the checks
and tells you so.

Measured on 16.11.2026 (38 runs, many of them right after failure tests): median 67 s, from 50 s (lab already in the base
state) to 640 s; after a full restart of all VMs 347 s (cluster 31 s, instances 78 s, services 66 s, ACFS 3 s,
processes 96 s). Details: [TIMINGS.md](TIMINGS.md).

## 🔁 What a full restart looks like

After `lab.cmd stop` and starting the VMs again (without `baseline`), the lab is **not** in the base state, and that is
normal Clusterware behaviour:

- CRS starts both instances by itself. An early manual `srvctl start instance` races it (PRCZ-4054): `baseline` waits first.
- Services start on whichever instance is up first, so `gg_srcpdb` or `srv_load2` may sit on their **available**
  instance. CRS does not move them back.
- ACFS has `AUTO_START=restore` and comes up mounted on **both** nodes.
- CRS tries to start GoldenGate through XAG. On a node still busy with its start-up checks, the XAG health check took
  longer than its 60 s script timeout and the resource stayed OFFLINE; a later `agctl start` worked.
- On ggtgt systemd starts the database (`oracle-db.service`) and the Service Manager (`OracleGoldenGate.service`), and
  the profile MAA starts REP1 about 60 s later.

`lab.cmd start` (without a VM name) ends with `baseline`, which fixes all of this. Measured: 365 s from powered off to
the base state.

## ⏻ Orderly shutdown (recommended)

```powershell
.\lab.cmd shutdown -DryRun   # shows every step and command, changes nothing
.\lab.cmd shutdown           # GoldenGate -> target -> RAC database -> CRS node by node -> VMs, report in logs\shutdown_<ts>.txt
```

`host/new_shutdown_shortcut.ps1` puts a desktop shortcut that shows the dry run first and shuts the lab down only after
you confirm. `shutdown` refuses to run while a failure test is running; a step that fails stops the sequence before the
VMs are powered off (`-Force` goes on). The steps below are what it does, for doing it by hand.

`lab.cmd stop` only presses the power button of each VM. On the RAC side that lets Clusterware decide what happens to
GoldenGate, and Clusterware does what it is built for: it keeps GoldenGate alive. In this lab, `crsctl stop cluster -all`
issued on ggrac1 stopped ggrac1 first, and CRS **moved GoldenGate, the VIP and ACFS to ggrac2** before ggrac2 received
its own stop. Stop the pieces in dependency order instead, so that nothing has a reason to move:

```bash
# 1. [oracle on the node that runs GoldenGate: agctl status goldengate oggsource]
/u01/app/xag/bin/agctl stop goldengate oggsource
agctl status goldengate oggsource                      # not running
# 2. [root@ggtgt] target GoldenGate, then the target database
#    as oracle: adminclient, CONNECT http://ggtgt.gg.lab.test:9100 DEPLOYMENT oggtarget AS oggadmin, then:
#    STOP REPLICAT *
systemctl stop OracleGoldenGate.service                # stops ONLY the Service Manager (KillMode=process)
pgrep -fa 'adminsrvr|distsrvr|pmsrvr|recvsrvr|replicat' # what is left: kill -TERM <pid> until the list is empty
systemctl stop oracle-db.service
# 3. [oracle@ggrac1] the RAC database
srvctl stop database -db ggcdb
# 4. [root@ggrac1], then [root@ggrac2]: Clusterware node by node (not "crsctl stop cluster -all")
/u01/app/23.26/grid/bin/crsctl stop crs
```

```powershell
# 5. on the host: power the VMs off
.\lab.cmd stop
```

Check after step 4 on each node: no `ohasd` / `crsd` processes, `/u01/oggdeploy` no longer mounted. Avoid `crsctl stop crs -f` unless a normal stop hangs.

**Target GoldenGate (step 2).** The `OracleGoldenGate.service` unit that the GoldenGate configuration assistant (`oggca`) registers has
`KillMode=process`: `systemctl stop` ends only the Service Manager, while the deployment servers and Replicat keep
running (a side effect: restarting the Service Manager does not interrupt replication). When shutting down,
`lab.cmd shutdown` therefore does three things: `STOP REPLICAT *` through adminclient (Replicat writes a clean
checkpoint), `systemctl stop`, then SIGTERM to the servers that are left. If the Service Manager is already down (for
example after an earlier interrupted shutdown), adminclient has nothing to connect to, so the step sends SIGTERM right
away; Replicat resumes from its checkpoint.

**Measured (laptop lab, from the base state):** the whole `lab.cmd shutdown` takes 352 s. The longest parts are
`crsctl stop crs` on the second node (about 205 s) and on the first (about 70 s); source GoldenGate about 24 s, target
GoldenGate about 18 s, the databases 6–10 s each.

## 🩺 Quick health check

```powershell
.\lab.cmd status
.\lab.cmd validate          # or, without load: .\lab.cmd baseline (it also repairs)
```

On a RAC node (root):

```bash
crsctl stat res -t                                   # overview
agctl status goldengate oggsource
crsctl stat res oggvip ora.data.oggvol.acfs ora.ggcdb.gg_srcpdb.svc -t
bash /root/lab/shared/probe.sh crs 1 --once           # one line per resource, the test runner's view
bash /root/lab/shared/probe.sh gg 1 --once            # GoldenGate processes and lag
```

## 🚧 Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `validate` fails on service placement or "ACFS ONLINE on exactly 1 node" after a restart | normal restart behaviour (section above) | `lab.cmd baseline` |
| GoldenGate OFFLINE after the cluster started | XAG health check longer than 60 s on a busy node | `lab.cmd baseline` (retries), or `agctl start goldengate oggsource --node <node of gg_srcpdb>` |
| GoldenGate stopped after the instance under it died, and does not come back | hard dependency on the service `gg_srcpdb` (see test T4 in [TESTS.md](../TESTS.md)) | `lab.cmd baseline`, or relocate by hand: `agctl relocate goldengate oggsource --node <other node>` |
| an instance does not restart after `kill -9` of PMON, CRS log says "restart attempt exhausted" | `ora.ggcdb.db` restarts an instance at most `RESTART_ATTEMPTS=2` times within `UPTIME_THRESHOLD=1h` (default after dbca) | `srvctl start instance -db ggcdb -instance ggcdb1` (a manual start also resets the counter); check with `crsctl stat res ora.ggcdb.db -v` |
| `agctl start` fails right after `oggca` | a Service Manager started by `oggca` still runs outside XAG | stop that process (`pgrep -af ServiceManager`), then `agctl start` |
| a process ABENDED | look at its report | adminclient: `INFO ALL`, `VIEW REPORT ext1` (or `rep1`); then `START EXTRACT ext1` |
| lag looks high right after a relocation | `ggadmin.gg_lag` has one row per path; the old path only ages | use the freshest path (query in [MANUAL.md](MANUAL.md#19--check-load-and-data-comparison)) |
| ggtgt database does not start at boot: `203/EXEC Permission denied` | SELinux and `dbstart` in the Oracle home | the unit must run `/usr/bin/bash .../dbstart` (it does since the fix, see [PITFALLS_26AI.md](PITFALLS_26AI.md)) |
| a node has load far above its vCPU, instance terminated with ORA-29770 | CPU starvation (AHF/TFA, 2 vCPU) | check `systemctl is-enabled oracle-tfa.service` (disabled), 3 vCPU per RAC node |
| XAG resource stuck in STOPPING, `crsctl stop crs` cannot unmount ACFS | GoldenGate processes still hold `/u01/oggdeploy` (seen once under CPU starvation) | find them with `lsof +D /u01/oggdeploy` or `pgrep -af /u01/app/ogg`, stop them; `crsctl stop crs -f` only as the last resort |
| a build step refuses: `logs\STOP exists` | the pause file | delete `logs\STOP` |
| everything is slow, clocks jump | Windows hypervisor on | [ENVIRONMENT.md](ENVIRONMENT.md#windows-hypervisor-off) |

More traps of this release: [PITFALLS_26AI.md](PITFALLS_26AI.md).

## 🧪 After a failure test

`tests/run_test.ps1` runs `lab.cmd baseline` after each run by itself. After your own experiments run it by hand, then
`lab.cmd validate` if you want the data comparison too. Test catalogue: [TESTS.md](../TESTS.md).
