# 🔍 Analysis: Extract stalls in T3 (power-off of ggrac2)

🇬🇧 English | 🇵🇱 [Polski](T3_EXTRACT_STALLS_PL.md)

[![Status](https://img.shields.io/badge/Analysis-partly_explained-yellow)]()
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![GG](https://img.shields.io/badge/GoldenGate-23.26-blue)]()

> 🎯 Where the linear growth of the lag (1 s per second) comes from in T3 run 3 (up to about 126 s) and in T3 run 1 (the
> relapse at about 343 s). Source: `GGADMIN.GG_HEARTBEAT_HISTORY` on the target (TGTPDB) set against the alert log of
> ggcdb1, `ggserr.log`, `crsd.trc` and ASH. Measured 16.11.2026; results in [RESULTS.md](../RESULTS.md#t3--power-off-of-the-second-node).

## 📏 How to read the lag measure

The harness measures `incoming_lag + incoming_heartbeat_age` from `ggadmin.gg_lag`. A heartbeat is created on the source
every 5 s. When any link stands still (heartbeat job, Extract, path, Replicat), the age of the last heartbeat grows by
1 s per second and so does the lag. The heartbeat history shows which link stood still
(`incoming_heartbeat_ts` → `incoming_extract_ts` → `incoming_routing_ts` → `incoming_replicat_ts`).

## ⏱️ T3 run 3 (`T3-20261116-162545`)

| Window (seconds after the fault) | What stood still | Evidence |
|---|---|---|
| 0 → 32 | **the source creates no heartbeats**: the cluster is frozen until ggrac2 is evicted and thread 2 is recovered | no heartbeat rows; job `j000` on ggcdb1: `ORA-04021 ... GG_UPDATE_HEARTBEATS`; alert log: reconfiguration, then instance recovery finished at about 32 s, `Redo thread 2 internally disabled at seq 33` |
| 32 → 65 | Extract: the first heartbeat after the fault was captured 33 s after it was created | heartbeat created at 31.9 s, captured by the Extract at 65.5 s |
| 65 → 125 (about 60 s) | **the Extract emits nothing**; heartbeats are created normally every 5 s | heartbeats created between about 34 s and 94 s all carry the same Extract time (about 125 s) |
| from about 126 s | normal (Extract delay about 2–3 s) | |

During these 60 s the database is idle (ASH: single LGWR/CJQ0 samples, no active GoldenGate sessions, so they wait in
idle waits). `ggserr.log` and the Extract report are silent in that window. `EXT1` reports RUNNING.

## 🔁 Comparison of the T3 runs (largest Extract delay, heartbeat → Extract)

| Run | Largest delay | Notes |
|---|---|---|
| 1 (`160222`) | 7.3 s in the fault window; **21 s** at about 321–343 s after the fault | this is the relapse to lag 34 s; database, GoldenGate and CRS logs have no entries at that moment |
| 2 (`161451`) | 33.8 s | |
| 3 (`162545`) | **90.9 s** | 33 s plus the 60 s stall described above |

## 🧭 Conclusions

1. The first about 32 s of lag in every T3 run is the time the cluster is frozen: the source does not commit heartbeats
   at all. That is RAC behaviour, not GoldenGate, and it repeats (eviction at about 31 s).
2. Further stalls are on the Extract side (integrated capture / LogMiner): about 60 s in run 3 and about 21 s in run 1
   several minutes after the fault, with an idle database and nothing in the logs. **Cause not established.** Hypothesis
   (not checked): after thread 2 is disabled, LogMiner periodically waits for redo of that thread, and how long depends
   on where in its streaming cycle (60 s, message OGG-02339) the fault caught it.
3. The quiet linear growth of the lag from 17 to 34 s in run 1 is the same mechanism as point 2: a short Extract stall
   while heartbeats keep coming, not a gap in the heartbeats.

## 🔧 Next steps (not implemented)

- To collect more data in future T3 runs, the harness could record `v$goldengate_capture` and `v$logmnr_session` (state,
  `capture_message_create_time`) every 5 s. Read-only, no change to the lab.
- When presenting T3, split the lag into "database frozen" (no heartbeats created) and "Extract catching up". The
  heartbeat history gives both parts for every run.
