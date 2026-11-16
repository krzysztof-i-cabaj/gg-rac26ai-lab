# 🧪 Failure tests T1–T10 and T4b: GoldenGate 26ai on RAC 26ai

🇬🇧 English | 🇵🇱 [Polski](TESTS_PL.md)

[![Tests](https://img.shields.io/badge/Tests-T1--T10_+_T4b-blueviolet)]()
[![Measured](https://img.shields.io/badge/Measured-16.11.2026-success)](docs/RESULTS.md)
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![HA](https://img.shields.io/badge/HA-XAG_10.2_+_ACFS-blue)]()

> 🎯 What each failure test breaks, why that failure matters in real life, what we expected and on what basis, the exact
> fault command (automated and by hand), what is measured, when a run passes and how the lab goes back to its base
> state. Oracle publishes no XAG failover times, so the lab measures instead of assuming. Results: [docs/RESULTS.md](docs/RESULTS.md).

Words such as XAG, singleton service, heartbeat lag or `oggvip` are explained in [docs/CONCEPTS.md](docs/CONCEPTS.md).
Map of where each test hits: [docs/diagrams/04-failure-tests.svg](docs/diagrams/04-failure-tests.svg).

## 🧭 How every test works

### Base state

A run starts only from the **base state**, checked by `Assert-Baseline` (`host/Tests.psm1`); otherwise it refuses to
start and lists the deviations:

- the XAG resource (GoldenGate), service `gg_srcpdb`, ACFS `ora.data.oggvol.acfs` and VIP `oggvip` ONLINE on `ggrac1`;
- both nodes Active, both instances ONLINE;
- `EXT1`, `DP1`, `REP1` RUNNING;
- lag below 30 s.

`lab.cmd baseline` brings the lab into this state (it starts powered-off VMs, puts the interconnect link back, starts
instances, moves services and GoldenGate back to `ggrac1`). `run_test.ps1` runs it automatically after every run and
records its duration as `back_to_base_s`.

### Load

`guest/shared/loadgen.sh`, started from `ggtgt` (it survives every RAC failure), writes 10 rows/s through **both**
instances at once: one session on `srv_load1` (`ggcdb1`) and one on `srv_load2` (`ggcdb2`), rows with `SEQ`, `INST`,
`TS` in `SALES.LOAD_EVENTS`. Only then a source = target comparison proves that the Extract also read the redo thread of
the instance that failed. The load is stopped **in the database** before the comparison.

### Timeline of one run

`PreSec` of load (60 s) → fault (`t_fault`) → wait until recovered (at most `TimeoutSec`) → observe `PostSec` →
stop the load → compare data (repeated until equal, at most 180 s) → write the evidence → `lab.cmd baseline`.

**Recovered** means: a disturbance was seen after the fault (a sample that differs from the base state), then the whole
chain (service, ACFS, VIP, XAG resource) ONLINE on one node, on the expected node if the test has one, `EXT1`, `DP1`,
`REP1` RUNNING and lag below 30 s.

### What is measured

Samplers on the host poll the nodes over SSH (CRS every 1 s, GoldenGate processes every 2 s, lag every 1 s) with one
clock: the host, UTC, milliseconds. State changes go to `events.csv`; markers are computed from it by
`host/Evidence.psm1`, never typed by hand. All markers are seconds after `t_fault`.

| Marker | Meaning |
|---|---|
| `t_fault` | host time right before the fault command (0) |
| `t_crs_detect` | first sign that the cluster noticed: a node leaving the cluster; without one (instance or process kill), the first chain resource going down (instance, service, ACFS, VIP, XAG resource, `EXT1`, `DP1`) |
| `t_service_online` | service `gg_srcpdb` ONLINE again or ONLINE on another node |
| `t_acfs_online` | ACFS ONLINE again, on the node of `oggvip` |
| `t_vip_online` | `oggvip` ONLINE again or on another node |
| `t_sm_running` | **the XAG resource `xag.oggsource.goldengate` ONLINE again** (CRS state, not the Service Manager process) |
| `t_ext_running`, `t_dp_running`, `t_rep_running` | `EXT1`, `DP1`, `REP1` RUNNING again after another state |
| `t_lag_ok` | **first lasting return of the lag below 30 s**: the first sample below 30 s after the first sample at or above 30 s that is not followed by another sample at or above 30 s within 20 s. Later crossings are counted as `lag_relapses`, not as the recovery |
| `t_intervention_ready`, `t_intervention` | T4b only: when the manual move was offered and when it ran |

- **RTO** (`rto_s`) = `t_rep_running − t_fault` when the Replicat had an outage; when `REP1` kept running (every run on
  16.11.2026), `t_lag_ok − t_fault`; when neither exists, `t_ext_running − t_fault`. `summary.json` names the basis in
  `rto_basis`. In practice: **the time until the target is again less than 30 s behind the source.**
- **Lag** = `incoming_lag + incoming_heartbeat_age` of the freshest path row in `ggadmin.gg_lag` on the target
  (heartbeat every 5 s), `lag.csv`.
- **Data** (`compare.json`): `sql/10_compare.sql` on both sides gives `COUNT(*)` and `SUM(ORA_HASH(...))` per table
  (HR and SALES), plus a `SEQ` check per instance: missing, extra and duplicate rows. `data_ok` needs every table equal,
  load rows really written on the source and a clean `SEQ` check.
- Also recorded: `final_node`, `evicted_node`, `service_moved`, `xag_action` (`restart_in_place`, `relocate`, `none`),
  `xag_restarts`, `lag_max_s`, `expected_check` (expectation vs result), clock offsets of the VMs.

### Verdicts

- **Pass:** recovered within `TimeoutSec`, data equal, not refused.
- **Refused:** the lab was not in the base state, no fault was injected.
- **Harness error** (`harness_error`): the test script failed (for example the fault command returned an error); this is
  not a cluster result.
- **Measurement error** (`measurement_error`, set afterwards with a note): a probe measured wrong; the run is kept but
  not used for numbers.
- Every run, failed ones included, stays in `results/<test>-<yyyyMMdd-HHmmss>/`. The published copies are in
  [results/runs/](results/runs/).

## 🚀 How to run a test yourself

Prerequisites: the lab after `lab.cmd validate` ([docs/INSTALL_AUTO.md](docs/INSTALL_AUTO.md)), PowerShell 7 on the
Windows host, the lab SSH key, `$env:LAB_PASS` set in the same window (see [SETTINGS.md](SETTINGS.md)).

```powershell
cd D:\labs\gg-rac26ai-lab
$env:LAB_PASS = '<lab password>'                      # never stored in the repository
.\tests\run_test.ps1 -Test T2 -DryRun                # prints the plan, changes nothing
.\tests\run_test.ps1 -Test T2 -ApprovedBy <name>     # one run
.\tests\run_test.ps1 -Test T2 -ApprovedBy <name> -Repeat 3
```

- `-ApprovedBy <name>` is **required** for a VM power-off, the interconnect cut, a destructive test (T6, T7) and the T4b
  intervention; without it the script stops with exit code 2. The name is written to `summary.json`.
- `-ManualStepDone` is required for T6 (flag set by hand first, see T6).
- `-NoBaseline` skips the automatic `lab.cmd baseline` after each run (then put the lab back yourself).
- `-Back` runs a measured "back to the base state" (relocate the service and GoldenGate back to `ggrac1`); since
  `lab.cmd baseline` runs after every run, it is optional.
- Exit code: 0 = every run passed, 1 = a run failed or was refused, 2 = refused before the start.
- Output: `results/<test>-<yyyyMMdd-HHmmss>/` with `events.csv`, `lag.csv`, `load.csv`, `compare.json`, `summary.json`,
  `commands.txt` (every command with its time and output, passwords masked), log excerpts; `results/summary_all.csv`.

## 📋 Overview

| Test | Fault | Approval | Runs on 16.11.2026 |
|---|---|---|---|
| [T1](#t1--planned-relocation) | `agctl relocate` to `ggrac2` | no | 5 (3 passed) |
| [T2](#t2--hard-power-off-of-the-goldengate-node) | power-off `ggrac1` | yes | 3 (3 passed) |
| [T3](#t3--power-off-of-the-second-node) | power-off `ggrac2` | yes | 3 (3 passed) |
| [T4](#t4--instance-crash-kill--9-of-pmon) | `kill -9` PMON `ggcdb1` | no | 6 (0 passed) |
| [T4b](#t4b--instance-crash--manual-goldengate-move) | as T4 + manual move after 120 s | yes (live) | 3 (3 passed) |
| [T5](#t5--kill-the-service-manager) | `kill -9` Service Manager | no | 3 (3 passed) |
| [T6](#t6--extract-marked-critical-to-deployment-health-) | flag ON + `kill -9` `EXT1` | yes ⚠️ | 3 (3 passed) |
| [T7](#t7--interconnect-cut-) | interconnect of `ggrac2` down | yes ⚠️ | 1 (1 passed) |
| [T8](#t8--lag-under-load-no-fault) | none (10 min of load) | no | 3 (1 passed) |
| [T9](#t9--data-comparison) | none | no | 1 (1 passed) |
| [T10](#t10--ddl-and-26ai-data-types) | none (DDL and new types) | no | 2 (2 passed, 1 without DDL) |

⚠️ = can leave the lab broken until a manual fix.

---

### T1 — Planned relocation

**Why this test and what it should show.** Every maintenance window on a RAC node (patching, hardware) starts by moving
GoldenGate away from it. The question: does the XAG chain move in the right order (stop Service Manager → ACFS → VIP on
the other node → start → processes from checkpoints), and does `agctl relocate` also move the singleton service
`gg_srcpdb`, or is a separate `srvctl relocate service` needed? Expectation: GoldenGate on `ggrac2`, no data lost, RTO
unknown. Basis: MAA (agctl relocate is the documented way to move GoldenGate) and the XAG agctl reference.

- **Start:** base state. No approval needed.
- **Fault (automated):** as `root` on `ggrac2`: `/u01/app/xag/bin/agctl relocate goldengate oggsource --node ggrac2`.
- **By hand, without the harness:** the same command, then watch `crsctl stat res -t` and `agctl status goldengate oggsource`.
- **Measured:** all markers, whether the service moved (`service_moved`), lag curve, data.
- **Pass:** GoldenGate on `ggrac2`, `EXT1`/`DP1`/`REP1` RUNNING, lag below 30 s, data equal, no missing or duplicate `SEQ`.
- **Back to base:** `lab.cmd baseline` (moves service and GoldenGate back to `ggrac1`).
- **Risks:** none for the lab; a wrong lag probe can make a good run look failed (it happened once, see RESULTS).
- **Run it:** `.\tests\run_test.ps1 -Test T1 -Repeat 3` (PreSec 60, PostSec 120, TimeoutSec 600).

### T2 — Hard power-off of the GoldenGate node

**Why this test and what it should show.** A power supply, mainboard or hypervisor failure: the node with GoldenGate
disappears without a clean shutdown. The question: does everything come back without a human, how long does it take,
and does the Extract read the redo of the dead instance (thread 1) so that nothing is lost? Expectation: eviction of
`ggrac1` → service on `ggcdb2` → ACFS → VIP → Service Manager → Extract; GoldenGate on `ggrac2`; 0 rows lost; RTO
unknown. Basis: MAA (GoldenGate follows the singleton PDB service).

- **Start:** base state; approval for a power-off.
- **Fault (automated):** on the host: `VBoxManage controlvm ggrac1 poweroff`.
- **By hand:** the same command; on physical servers a power-off through the management board (iLO, iDRAC, IPMI) or
  pulling the power cables. Do not use `shutdown`: that is a clean stop, a different test.
- **Measured:** all markers and the segments between them, `evicted_node`, lag curve, `SEQ` rows of `INST=1` on the target.
- **Pass:** automatic recovery on `ggrac2`, data equal; RTO is recorded, not judged.
- **Back to base:** `lab.cmd baseline` (starts `ggrac1`, waits for the cluster, moves everything back).
- **Risks:** `+FRA` fills while the Extract does not run; a hard power-off can need a longer boot.
- **Run it:** `.\tests\run_test.ps1 -Test T2 -ApprovedBy <name> -Repeat 3` (PreSec 60, PostSec 120, TimeoutSec 900).

### T3 — Power-off of the second node

**Why this test and what it should show.** The node that dies is the one **without** GoldenGate. It looks harmless, but
the Extract must still read every committed change of the dead instance (thread 2) from its online and archived redo in
the shared `+FRA`. The question: does GoldenGate stay put, how big is the lag jump, and does every `INST=2` row committed
before the fault reach the target? Expectation: GoldenGate stays on `ggrac1`; at most a short lag jump until thread 2 is
closed; 0 rows lost. Basis: how RAC redo threads and integrated capture work (see CONCEPTS); no published number.

- **Start:** base state; approval for a power-off.
- **Fault (automated):** `VBoxManage controlvm ggrac2 poweroff`.
- **By hand:** as T2 but on the node without GoldenGate.
- **Measured:** lag at 1 s, `t_crs_detect` (eviction), `lag_relapses`, `SEQ` rows of `INST=2`.
- **Pass:** GoldenGate stays on `ggrac1`, lag back below 30 s, data equal.
- **Back to base:** `lab.cmd baseline` (starts `ggrac2`, moves `srv_load2` back).
- **Risks:** after `ggrac2` boots, ACFS can be mounted on both nodes; `lab.cmd baseline` fixes it.
- **Run it:** `.\tests\run_test.ps1 -Test T3 -ApprovedBy <name> -Repeat 3` (PreSec 60, PostSec 300, TimeoutSec 600).

### T4 — Instance crash (kill -9 of PMON)

**Why this test and what it should show.** Many runbooks call "shutdown abort" a node failure test, but a crashed
instance on a living node is a different path: node, ACFS and VIP stay up, only the database instance is gone. The
question: does GoldenGate follow the service to the other node? Expectation: GoldenGate on `ggrac2`, 0 rows lost, RTO
unknown. Basis: MAA and the XAG reference for `--use_local_services` (GoldenGate runs where the service runs). Risk named
before the run: XAG stays on `ggrac1` without a database.

- **Start:** base state.
- **Fault (automated):** as `root` on `ggrac1`:
  `p=$(pgrep -f '[o]ra_pmon_ggcdb1'); [ -n "$p" ] || { echo 'no pmon process'; exit 3; }; kill -9 $p`
  (no PMON process = the fault did not happen, the run stops).
  `srvctl stop instance -db ggcdb -instance ggcdb1 -stopoption abort` is **not** used: it is a planned stop and CRS
  refuses it while the singleton service runs there (CRS-2974, the service would need `-force`). Three runs with it on
  16.11.2026 ended as harness errors.
- **By hand:** the same `kill -9` as `root` on the node of `ggcdb1`.
- **Measured:** the same markers as T2 so that both can be compared, `service_moved`, `final_node`.
- **Pass:** chain on `ggrac2` although node 1 is alive, data equal.
- **Back to base:** `lab.cmd baseline` (waits for the CRS autostart of `ggcdb1` or starts it, moves the service back,
  then XAG starts on `ggrac1`).
- **Risks:** CRS restarts an instance locally at most `RESTART_ATTEMPTS` times (2) within `UPTIME_THRESHOLD` (1 h). A third
  crash within the hour leaves the instance down ([analysis](docs/analysis/T4_INSTANCE_RESTART.md)). Leave an hour
  between T4/T4b runs or restart the instance by hand to reset the counter.
- **Run it:** `.\tests\run_test.ps1 -Test T4` (PreSec 60, PostSec 120, TimeoutSec 900).

### T4b — Instance crash + manual GoldenGate move

**Why this test and what it should show.** T4 showed that GoldenGate does not come back by itself after an instance crash.
T4b measures what it costs when the on-call DBA reacts: from the fault and from the manual move to lag OK. Expectation:
after the move GoldenGate starts on `ggrac2` with the service, VIP and ACFS follow it, 0 rows lost. Basis: the T4 result
(CRS-0222, no retry) and `agctl` as in T1.

- **Start:** base state; approval for the intervention.
- **Fault:** as T4.
- **Intervention (automated, 120 s after the fault, as `root` on `ggrac2`):**
  1. if `agctl status goldengate oggsource` says "is running on": `agctl relocate goldengate oggsource --node ggrac2`;
  2. else `agctl start goldengate oggsource --node ggrac2`;
  3. if that start is refused because `oggvip` runs on `ggrac1`: `crsctl relocate resource oggvip -n ggrac2 -f`, then the
     start again.
- **Live approval:** at 120 s the script prints `INTERVENTION READY` with the whole command branch and waits up to 600 s
  for a file `approve_intervention` in the run directory containing `approved_by=<name>`. No file = no move
  (`intervention not approved`). `summary.json` records `t_intervention_ready`, `t_intervention`, `approval_wait_s`.
- **By hand:** `kill -9` PMON as in T4, wait about 2 minutes, check `agctl status goldengate oggsource`, then step 1 or 2
  above (step 3 only if the start is refused).
- **Measured:** T4 markers plus the intervention markers; useful derived value: `t_lag_ok − t_intervention` (the cost of
  the manual move alone).
- **Pass:** chain on `ggrac2`, data equal. "Recovers without a human" is not applicable here.
- **Back to base:** `lab.cmd baseline`.
- **Risks:** as T4 (restart budget of the instance).
- **Run it:** `.\tests\run_test.ps1 -Test T4b -ApprovedBy <name>`, then, after `INTERVENTION READY`, create the file:
  `Set-Content <run dir>\approve_intervention 'approved_by=<name>'`.

### T5 — Kill the Service Manager

**Why this test and what it should show.** A process crash or a mistaken `kill`: the node and the database live, only the
GoldenGate Service Manager is gone. The question: what does XAG do (restart in place or move to the other node) and how
long does it take? Expectation: XAG/CRS notices and restarts the deployment in place or moves it; 0 rows lost. Basis:
XAG check action; known bug 37468391 (XAG kills every GoldenGate process of the node) needs more than one Service Manager,
this lab has one.

- **Start:** base state.
- **Fault (automated):** as `root` on `ggrac1`:
  `p=$(pgrep -f '/u01/app/ogg/ogg26ai_ma/bin/[S]erviceManager'); [ -n "$p" ] || { echo 'no ServiceManager process'; exit 3; }; kill -9 $p`.
- **By hand:** the same command.
- **Measured:** `xag_action`, `xag_restarts`, markers, lag.
- **Pass:** deployment and processes RUNNING again without a human, data equal.
- **Back to base:** `lab.cmd baseline` (only needed if XAG relocated).
- **Risks:** low; if XAG decides to relocate instead of restarting in place, GoldenGate ends on `ggrac2` and the run
  measures a relocation (`xag_action` says which one happened).
- **Run it:** `.\tests\run_test.ps1 -Test T5 -Repeat 3` (PreSec 60, PostSec 120, TimeoutSec 600).

### T6 — Extract marked "Critical to deployment health" ⚠️

**Why this test and what it should show.** One option in the managed process profile can change how the cluster reacts.
MAA warns that a failure of a process marked "Critical to deployment health" can interfere with XAG restarting the
deployment. The question: what really happens when such an Extract dies? Expectation: none assumed ("can interfere" is
not "blocks"); the effect is recorded. Basis: MAA paper, section on the managed process profile.

- **Start:** base state; approval; by hand before the run: in the Web UI of `oggsource` (through `oggvip`), Extract
  `EXT1` → Managed Options → "Critical to deployment health" ON. The script refuses T6 without `-ManualStepDone`.
- **Fault (automated):** as `root` on `ggrac1`:
  `p=$(pgrep -f '[e]xtract.*EXT1'); [ -n "$p" ] || { echo 'no extract process'; exit 3; }; kill -9 $p`.
- **By hand:** set the flag, then the same `kill -9`.
- **Measured:** markers, the state of the XAG resource (INTERMEDIATE), `xag_action`, lag.
- **Pass:** the real effect is recorded; recovery and equal data make the run pass.
- **Back to base:** set the flag OFF in the Web UI, `lab.cmd baseline`.
- **Risks:** deployment left down until a manual fix (did not happen on 16.11.2026). Not recorded by the harness: the
  profile export before the run and the number of restart attempts of `EXT1`.
- **Run it:** `.\tests\run_test.ps1 -Test T6 -ApprovedBy <name> -ManualStepDone -Repeat 3` (PreSec 60, PostSec 180, TimeoutSec 900).

### T7 — Interconnect cut ⚠️

**Why this test and what it should show.** Both nodes live but cannot hear each other on the private network (switch,
cable, NIC). The cluster must choose one survivor to avoid split brain. The question: which node is evicted, where does
GoldenGate end, and how does the Extract cope while one redo thread goes silent? Expectation: exactly one node leaves the
cluster (which one is measured), GoldenGate ends on the survivor, replication recovers, 0 rows lost. Basis: Clusterware
node eviction (`ocssd`), no published GoldenGate number.

- **Start:** base state; approval.
- **Fault (automated):** on the host: `VBoxManage controlvm ggrac2 setlinkstate3 off` (NIC3 = internal network `ggrac-ic`).
- **By hand:** the same command; on physical servers unplug the interconnect cable or disable the switch port. Taking the
  interface down inside the OS (`ip link set <interconnect NIC> down` on `ggrac2`) is close but not the same (not checked).
- **Measured:** `evicted_node`, `t_crs_detect`, `final_node`, lag, data.
- **Pass:** exactly one node leaves, replication recovers, data equal.
- **Back to base:** `lab.cmd baseline` (puts the link back with `setlinkstate3 on`, waits for `ggrac2` to rejoin and its
  instance to start).
- **Risks:** both nodes rebooting; the voting files are on one shared disk.
- **Run it:** `.\tests\run_test.ps1 -Test T7 -ApprovedBy <name>` (PreSec 60, PostSec 180, TimeoutSec 1200).

### T8 — Lag under load (no fault)

**Why this test and what it should show.** "Replication works" means nothing without a number. T8 measures the normal lag
under load, which is the baseline for every curve in T1–T7, and proves that both redo threads are read. Expectation: lag
below 30 s all the time; rows of `INST` 1 and 2 arrive. Basis: there is no `THREADS` option in `ADD EXTRACT` for this
setup, so the proof is the measurement.

- **Start:** base state. **Fault:** none (`Kind = none`).
- **By hand:** run `loadgen.sh 10 600` and poll `select incoming_lag + incoming_heartbeat_age from ggadmin.gg_lag` on the target.
- **Measured:** `lag.csv` (10 minutes), rows per instance on both sides, data.
- **Pass:** lag below 30 s for the whole run, data equal, rows of both instances on the target.
- **Run it:** `.\tests\run_test.ps1 -Test T8` (PreSec 60, PostSec 600).

### T9 — Data comparison

**Why this test and what it should show.** RUNNING processes do not prove that nothing was lost or doubled. T9 is the
comparison every other test ends with, run on its own. Expectation: equal counts and sums, no missing and no duplicate
`SEQ`.

- **Start:** base state. **Fault:** none.
- **By hand:** `bash /root/lab/shared/compare.sh` as `root` on a RAC node and on `ggtgt`, then compare the `COMPARE` and
  `SEQ` lines. (Oracle GoldenGate Veridata does this as a product; it is licensed separately and not used here.)
- **Pass:** identical counts and `ORA_HASH` sums, clean `SEQ` check.
- **Run it:** `.\tests\run_test.ps1 -Test T9` (PreSec 0, PostSec 30).

### T10 — DDL and 26ai data types

**Why this test and what it should show.** New applications store AI vectors and use native `BOOLEAN` and `JSON`; schemas
change. The question: do `VECTOR`, `BOOLEAN`, `JSON` and DDL go through Extract and Replicat unchanged? Expectation: rows
and DDL replicated, values equal. Basis: GoldenGate 23ai/26ai Release Notes (these types are supported); `DDL INCLUDE
MAPPED` in `ogg/ext1.prm`.

- **Start:** base state. **Fault:** none. The harness provides a quiet 120 s window (`PostSec`); the DDL steps are run by
  hand inside it.
- **Steps (as `oracle`, `sqlplus / as sysdba`; one statement per line, 26ai rejects two statements on one line with
  ORA-03405):**
  ```sql
  -- source, SRCPDB
  insert into sales.types26 (id,v,b,j) values (101, to_vector('[1.5,2.5,3.5]',3,FLOAT32), TRUE, json('{"t":"T10","n":101}'));
  commit;
  -- target, TGTPDB: wait for the row, then compare
  select id||' '||from_vector(v)||' '||case when b then 'TRUE' else 'FALSE' end||' '||json_serialize(j) from sales.types26 where id=101;
  -- source: DDL
  alter table sales.types26 add (note varchar2(30));
  -- target: wait for the column
  select count(*) from all_tab_columns where owner='SALES' and table_name='TYPES26' and column_name='NOTE';
  -- source: a row using the new column, then compare as above
  insert into sales.types26 (id,v,b,j,note) values (102, to_vector('[-1,0.25,4]',3,FLOAT32), FALSE, json('{"t":"T10","n":102}'), 'after DDL');
  commit;
  -- source: clean up (replicated too)
  delete from sales.types26 where id in (101,102);
  commit;
  alter table sales.types26 drop column note;
  ```
- **Measured:** time from commit / DDL on the source to visibility on the target, values on both sides, `compare.json`.
- **Pass:** rows and DDL replicated, values equal.
- **Run it:** `.\tests\run_test.ps1 -Test T10` (PreSec 0, PostSec 120), then the steps above within 120 s.

## 🔗 See also

- [docs/RESULTS.md](docs/RESULTS.md): measured results of 16.11.2026 with charts.
- [results/README.md](results/README.md): the published raw data and its fields.
- [docs/CONCEPTS.md](docs/CONCEPTS.md), [docs/OPERATIONS.md](docs/OPERATIONS.md).
