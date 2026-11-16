# 🗃️ results — published data of the failure tests

🇬🇧 English | 🇵🇱 [Polski](README_PL.md)

[![Measured](https://img.shields.io/badge/Measured-16.11.2026-success)]()
[![Runs](https://img.shields.io/badge/Runs-33-blueviolet)]()
[![Format](https://img.shields.io/badge/Format-CSV_+_JSON-blue)]()
[![Sanitized](https://img.shields.io/badge/Account_data-removed-darkgreen)]()

> 🎯 The measured data behind [docs/RESULTS.md](../docs/RESULTS.md): one directory per run of `tests/run_test.ps1`,
> failed and refused runs included. What each file holds, what each field means, and what was removed or changed for
> publication.

## 📁 Layout

| Path | Content |
|---|---|
| `runs/<test>-<yyyyMMdd-HHmmss>/` | one run; the name is the test and the UTC start time of the run (metadata of the measurement) |
| `runs/T4-20261116-133519/crsd_excerpt.txt` | lines of `crsd.trc` (CRS master node) naming the XAG resource and the service during that T4 run: the CRS-0222 evidence |
| `runs/crsd_restart_attempts_excerpt.txt` | ten `crsd.trc` lines showing the local restarts of `ora.ggcdb.db` and "restart attempt exhausted" (T4/T4b) |
| `sample/` | synthetic example (invented numbers, `"synthetic": true`) for static tests; never a measurement |

Timestamps inside the `crsd.trc` excerpts are the lab's local time (CET, UTC+1); every CSV and JSON file uses UTC.

## 📄 Files of one run

| File | Present in | Content |
|---|---|---|
| `summary.json` | every run | markers, RTO, verdicts, expectation and comparison with it (fields below) |
| `events.csv` | every run that started | state changes only: `ts_utc, t_rel_s, test_id, run_no, resource, node, state_from, state_to, source, raw`. `resource`: `svc`, `acfs`, `vip`, `sm` (XAG resource), `inst:<instance>`, `node:<node>`, `EXT1`, `DP1`, `REP1`, `fault`. `node` `-` = running nowhere |
| `lag.csv` | every run that started | `ts_utc, t_rel_s, lag_s, source`: lag = `incoming_lag + incoming_heartbeat_age` of the freshest path row of `ggadmin.gg_lag` (target), every ~1 s |
| `compare.json` | runs that reached the comparison | per table `SourceRows`, `TargetRows`, `SourceHash`, `TargetHash` (`SUM(ORA_HASH)`, from mid-day on), `Match`; `seq_check` per instance: `missing`, `extra_target`, `duplicates_*`, min/max `SEQ`; `data_ok`, `reason` |
| `harness_note.txt` | 6 runs | why a run is a harness or measurement error, interrupted, or how to read its data |

`t_rel_s` is always seconds after `t_fault` (negative = before the fault). One clock: the Windows host, UTC, milliseconds.

## 🔑 Fields of summary.json

| Field | Meaning |
|---|---|
| `test_id`, `run_no`, `attempt`, `title`, `fault_kind`, `fault_command`, `test_variant` | which test, which run of the invocation, how many run directories of this test existed, the fault |
| `markers` | `t_fault`, `t_crs_detect`, `t_service_online`, `t_acfs_online`, `t_vip_online`, `t_sm_running` (XAG resource ONLINE), `t_ext_running`, `t_dp_running`, `t_rep_running`, `t_lag_ok`; T4b also `t_intervention_ready`, `t_intervention`. Definitions: [TESTS.md](../TESTS.md#what-is-measured) |
| `segments`, `segments_out_of_order`, `segments_measured` | durations between markers: in chain order, the chain pairs that came in reverse order, and consecutive markers in the measured order |
| `rto_s`, `rto_basis` | recovery time and which marker it uses (`rep_running`, else `lag_ok`, else `ext_running`) |
| `lag_max_s`, `lag_ok`, `lag_jump`, `lag_relapses`, `lag_relapse_first_s`, `t_lag_ok_rule` | lag maximum after the fault, threshold (30 s), whether it was crossed, later crossings, how `t_lag_ok` was recomputed |
| `final_node`, `expected_gg_node`, `evicted_node`, `service_moved`, `xag_action`, `xag_restarts` | where GoldenGate ended, where it should end, which node left the cluster, whether the service moved, what XAG did |
| `refused`, `disturbed`, `recovered`, `data_ok`, `data_checked`, `pass` | verdict parts |
| `harness_error`, `measurement_error`, `measurement_note` | the run failed because of the test script, or a probe measured wrong (set afterwards) |
| `invoked_by`, `approved_by` | who started the run (`agent` = an AI agent driving the harness) and who approved it (`operator`, see below) |
| `intervention_*`, `approval_wait_s` | T4b: command, node, branch steps, exit code, who ran and approved it, approval wait |
| `expected`, `expected_written_utc`, `expected_match`, `expected_check` | the expectation, written to disk **before** the fault, and the field-by-field comparison with the result |
| `back_to_base_s`, `back_to_base_ok` | duration and success of `lab.cmd baseline` after the run |
| `observe_s`, `sample_interval_s`, `clock_offsets_ms`, `versions`, `stage`, `config_rev`, `synthetic`, `notes` | observation length, declared and measured sample intervals, chrony offsets of the VMs, binary versions, HA stage, configuration revision, real data flag, notes |

The harness gained fields during the measurement day; earlier runs lack the later fields (for example `lag_relapses`,
`config_rev`, `observe_s`).

### Polish values in `expected`

The expectation fields keep the values the harness compares (`host/Evidence.psm1`, `Get-ExpectedMatch`):

| Value | Meaning |
|---|---|
| `nie wiemy` | "we do not know": no guess was made, the field is not compared |
| `nie dotyczy` | "not applicable" (for example `Recovers` in T4b, `RtoS` in T8–T10), not compared |

## 🧹 What was changed for publication

The files were copied from the private working copy of the lab by a script; nothing else was edited.

- **Removed from `summary.json`:** `session` (name of the agent session that ran the tests), `agent_notes` (pointer to an
  unpublished notes file), `harness_commit` (commit of the private working repository).
- **Replaced:** `approved_by` and `intervention_approved_by` contain `operator` instead of the name of the approving
  person; Windows paths of the working copy in `notes` became `<repo>`; in `expected.Source` the internal report and
  note names became "lab verification report", "film concept note" and "lab plan".
- **Not published** (local only): `commands.txt`, `transcript.txt`, raw sampler output `raw_*.txt`, `load.csv`, load
  generator output, node log excerpts `logs/`, the agent's notes per run, the moments used to sync screen recordings.
  They contain host details or are working notes; every number in RESULTS comes from the published files or is marked
  as coming from the run notes (T10 step times, T6 profile).
- **`harness_note.txt`** files were translated from the Polish originals, or written from the run notes where no note
  existed (`T4-20261116-133519`, `T4-20261116-135751`).
- One error message in `T8-20261116-105457/summary.json` stays in Polish as the Windows host printed it.

## 🔄 Rebuild the charts

```powershell
python tools/make_charts.py            # reads results/runs, writes docs/img/results/*.svg (EN) and *_pl.svg (PL)
```

Standard library only (Python 3.8+). Charts: RTO per test (passed runs, median), lag around the fault per test (T1, T2,
T3, T4b, T5, T6, T7), and a resource-state timeline for one representative run per test (the median run, or for T4 the
first complete run).
