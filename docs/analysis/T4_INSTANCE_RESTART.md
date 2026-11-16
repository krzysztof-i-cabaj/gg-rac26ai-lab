# 🔍 Analysis: why CRS once restarts ggcdb1 after kill -9 of PMON and once does not (T4 / T4b)

🇬🇧 English | 🇵🇱 [Polski](T4_INSTANCE_RESTART_PL.md)

[![Status](https://img.shields.io/badge/Analysis-explained-success)]()
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![CRS](https://img.shields.io/badge/CRS-RESTART__ATTEMPTS%3D2-blue)]()

> 🎯 Conclusion: not a coincidence. In the two runs without a restart the local restart budget of resource
> `ora.ggcdb.db` was used up: `RESTART_ATTEMPTS=2` within `UPTIME_THRESHOLD=1h`. The third PMON kill within an hour =
> no restart. Measured 16.11.2026; results in [RESULTS.md](../RESULTS.md#t4--instance-crash-kill--9-of-pmon).

## 📋 Resource attributes (`crsctl stat res ora.ggcdb.db -f` on ggrac1, read after the test series)

| Attribute | Value | Meaning |
|---|---|---|
| `RESTART_ATTEMPTS` | 2 | how many times CRS restarts the instance locally before it gives up |
| `UPTIME_THRESHOLD` | 1h | the restart counter resets only after one hour without a failure (or after a manual start) |
| `FAILURE_INTERVAL` / `FAILURE_THRESHOLD` | 60 / 1 | after the restarts are used up, the failure goes to `FAILURE_HISTORY` |
| `INSTANCE_FAILOVER` | 0 | a RAC instance is not moved to another node, hence "Failover cannot be completed" |
| `FAILURE_HISTORY` (`-v`) | two entries | 14:45:06 UTC and 15:44:09 UTC, exactly runs `T4-20261116-144352` and `T4b-20261116-154243` |

The values are the defaults after `dbca`; the lab did not change them. Attribute reference: *Oracle Clusterware
Administration and Deployment Guide*, appendix "Oracle Clusterware Resource Reference".

## ⏱️ Sequence (UTC; `crsd.trc` on ggrac2 is in CET, +1 h)

| Run | kill -9 PMON | CRS decision (`crsd.trc` ggrac2) | Counter |
|---|---|---|---|
| T4 `133519` | 13:36:25 | local restart (14:36:29 CET) | 1 |
| T4 `135751` (interrupted) | about 13:58:59 | local restart (14:58:59 CET) | 2 |
| `lab.cmd baseline` | 14:09 | instance was running, no manual start: counter unchanged | 2 |
| T4 `144352` | 14:44:59 | **`No Local Restart of [ora.ggcdb.db 1 1], restart attempt exhausted`** (15:45:06 CET), stop of the resource tree, CRSPE00198 | exhausted |
| `lab.cmd baseline` (instance start) | 15:10 | manual start of `ora.ggcdb.db` on ggrac1 (16:10 CET), counter reset | 0 |
| T4b `152230` | 15:23:47 | local restart (16:23:50 CET) | 1 |
| T4b `153428` | 15:35:35 | local restart (16:35:59 CET) | 2 |
| T4b `154243` | 15:43:48 | **`restart attempt exhausted`** (16:44:09 CET) | exhausted |

Excerpt of `crsd.trc`: [crsd_restart_attempts_excerpt.txt](../../results/runs/crsd_restart_attempts_excerpt.txt)
(10 lines). Run `135751` has no `t_fault` in its `summary.json` (interrupted before the final summary), but its run
notes and `crsd.trc` confirm that the fault was injected.

## 🧭 What it means for the results

- T4 `144352` and T4b `154243` measure another scenario: "third instance failure within an hour", not "first failure".
  CRS behaves as configured: after the restarts are used up it stops the instance and its resource tree and waits for
  a human.
- The stop of GoldenGate in T4 is a separate matter (hard dependency of XAG on the service, CRS-0222). It happens also
  when the instance comes back (`133519`).
- In one sentence: CRS restarts a crashed instance twice within an hour; the third time it gives up. The data show it:
  two failures with a restart, then none.

## 🔧 Possible improvements (not implemented)

1. Test harness: before T4/T4b record `RESTART_COUNT` of instance 1 (`crsctl stat res ora.ggcdb.db -v`) in the
   expectation, add `restart_budget_left` to `summary.json` and warn when `RESTART_COUNT >= RESTART_ATTEMPTS`.
2. Before T4/T4b reset the counter (`srvctl stop instance -db ggcdb -instance ggcdb1` + `srvctl start instance ...`) or
   leave more than one hour between runs. The first changes the lab state before the test.
3. Changing `RESTART_ATTEMPTS`: no. It is the default, and the tests show the default behaviour.
