# 🗃️ results — opublikowane dane testów awarii

🇬🇧 [English](README.md) | 🇵🇱 Polski

[![Pomiar](https://img.shields.io/badge/Pomiar-16.11.2026-success)]()
[![Przebiegi](https://img.shields.io/badge/Przebiegi-33-blueviolet)]()
[![Format](https://img.shields.io/badge/Format-CSV_+_JSON-blue)]()
[![Dane konta](https://img.shields.io/badge/Dane_konta-usunięte-darkgreen)]()

> 🎯 Zmierzone dane, z których powstał [docs/RESULTS_PL.md](../docs/RESULTS_PL.md): jeden katalog na przebieg
> `tests/run_test.ps1`, także przebiegi nieudane i odrzucone. Co zawiera każdy plik, co znaczy każde pole i co usunięto
> albo zmieniono przed publikacją.

## 📁 Układ

| Ścieżka | Zawartość |
|---|---|
| `runs/<test>-<yyyyMMdd-HHmmss>/` | jeden przebieg; nazwa to test i czas startu przebiegu w UTC (metadane pomiaru) |
| `runs/T4-20261116-133519/crsd_excerpt.txt` | linie `crsd.trc` (węzeł główny CRS) z zasobem XAG i serwisem w czasie tego przebiegu T4: dowód CRS-0222 |
| `runs/crsd_restart_attempts_excerpt.txt` | dziesięć linii `crsd.trc` z lokalnymi restartami `ora.ggcdb.db` i „restart attempt exhausted” (T4/T4b) |
| `sample/` | przykład syntetyczny (zmyślone liczby, `"synthetic": true`) do testów statycznych; nigdy pomiar |

Znaczniki czasu w wyciągach `crsd.trc` są w czasie lokalnym labu (CET, UTC+1); każdy plik CSV i JSON używa UTC.

## 📄 Pliki jednego przebiegu

| Plik | Gdzie jest | Zawartość |
|---|---|---|
| `summary.json` | każdy przebieg | znaczniki, RTO, werdykty, oczekiwanie i porównanie z nim (pola niżej) |
| `events.csv` | każdy przebieg, który ruszył | tylko zmiany stanu: `ts_utc, t_rel_s, test_id, run_no, resource, node, state_from, state_to, source, raw`. `resource`: `svc`, `acfs`, `vip`, `sm` (zasób XAG), `inst:<instancja>`, `node:<węzeł>`, `EXT1`, `DP1`, `REP1`, `fault`. `node` `-` = nie działa nigdzie |
| `lag.csv` | każdy przebieg, który ruszył | `ts_utc, t_rel_s, lag_s, source`: lag = `incoming_lag + incoming_heartbeat_age` z najświeższego wiersza ścieżki w `ggadmin.gg_lag` (cel), co ok. 1 s |
| `compare.json` | przebiegi, które doszły do porównania | dla każdej tabeli `SourceRows`, `TargetRows`, `SourceHash`, `TargetHash` (`SUM(ORA_HASH)`, od połowy dnia), `Match`; `seq_check` per instancja: `missing`, `extra_target`, `duplicates_*`, min/max `SEQ`; `data_ok`, `reason` |
| `harness_note.txt` | 6 przebiegów | dlaczego przebieg to błąd automatu albo pomiaru, czemu przerwany albo jak czytać jego dane |

`t_rel_s` to zawsze sekundy od `t_fault` (ujemne = przed awarią). Jeden zegar: host Windows, UTC, milisekundy.

## 🔑 Pola summary.json

| Pole | Znaczenie |
|---|---|
| `test_id`, `run_no`, `attempt`, `title`, `fault_kind`, `fault_command`, `test_variant` | który test, który przebieg wywołania, ile katalogów przebiegów tego testu już było, awaria |
| `markers` | `t_fault`, `t_crs_detect`, `t_service_online`, `t_acfs_online`, `t_vip_online`, `t_sm_running` (zasób XAG ONLINE), `t_ext_running`, `t_dp_running`, `t_rep_running`, `t_lag_ok`; w T4b też `t_intervention_ready`, `t_intervention`. Definicje: [TESTS_PL.md](../TESTS_PL.md#co-mierzymy) |
| `segments`, `segments_out_of_order`, `segments_measured` | czasy między znacznikami: w kolejności łańcucha, pary łańcucha w odwrotnej kolejności i kolejne znaczniki w zmierzonej kolejności |
| `rto_s`, `rto_basis` | czas powrotu i znacznik, z którego go liczono (`rep_running`, potem `lag_ok`, potem `ext_running`) |
| `lag_max_s`, `lag_ok`, `lag_jump`, `lag_relapses`, `lag_relapse_first_s`, `t_lag_ok_rule` | maksimum laga po awarii, próg (30 s), czy został przekroczony, późniejsze przekroczenia, jak przeliczono `t_lag_ok` |
| `final_node`, `expected_gg_node`, `evicted_node`, `service_moved`, `xag_action`, `xag_restarts` | gdzie skończył GoldenGate, gdzie powinien, który węzeł wypadł z klastra, czy serwis się przeniósł, co zrobił XAG |
| `refused`, `disturbed`, `recovered`, `data_ok`, `data_checked`, `pass` | składniki werdyktu |
| `harness_error`, `measurement_error`, `measurement_note` | przebieg padł przez skrypt testu albo próbnik zmierzył źle (ustawiane potem) |
| `invoked_by`, `approved_by` | kto uruchomił przebieg (`agent` = agent AI sterujący automatem) i kto go zatwierdził (`operator`, zob. niżej) |
| `intervention_*`, `approval_wait_s` | T4b: polecenie, węzeł, kroki gałęzi, kod wyjścia, kto wykonał i zatwierdził, czas czekania na zgodę |
| `expected`, `expected_written_utc`, `expected_match`, `expected_check` | oczekiwanie zapisane na dysk **przed** awarią i porównanie z wynikiem pole po polu |
| `back_to_base_s`, `back_to_base_ok` | czas i powodzenie `lab.cmd baseline` po przebiegu |
| `observe_s`, `sample_interval_s`, `clock_offsets_ms`, `versions`, `stage`, `config_rev`, `synthetic`, `notes` | długość obserwacji, deklarowane i zmierzone odstępy próbek, przesunięcia zegarów VM wg chrony, wersje binariów, etap HA, rewizja konfiguracji, znacznik danych prawdziwych, uwagi |

Automat zyskiwał pola w trakcie dnia pomiarów; wcześniejsze przebiegi nie mają późniejszych pól (np. `lag_relapses`,
`config_rev`, `observe_s`).

### Polskie wartości w `expected`

Pola oczekiwania mają wartości, które porównuje automat (`host/Evidence.psm1`, `Get-ExpectedMatch`):

| Wartość | Znaczenie (EN) |
|---|---|
| `nie wiemy` | „we do not know”: nie zgadywaliśmy, pole nie jest porównywane |
| `nie dotyczy` | „not applicable” (np. `Recovers` w T4b, `RtoS` w T8–T10), nie jest porównywane |

## 🧹 Co zmieniono przed publikacją

Pliki skopiował skrypt z prywatnej kopii roboczej labu; poza tym nic nie było edytowane.

- **Usunięte z `summary.json`:** `session` (nazwa sesji agenta, który prowadził testy), `agent_notes` (wskazanie na
  nieopublikowany plik notatek), `harness_commit` (commit prywatnego repozytorium roboczego).
- **Zastąpione:** `approved_by` i `intervention_approved_by` mają wartość `operator` zamiast imienia osoby
  zatwierdzającej; ścieżki Windows kopii roboczej w `notes` zamieniono na `<repo>`; w `expected.Source` nazwy
  wewnętrznego raportu i notatek zamieniono na „lab verification report”, „film concept note” i „lab plan”.
- **Nieopublikowane** (tylko lokalnie): `commands.txt`, `transcript.txt`, surowe próbki `raw_*.txt`, `load.csv`, wyjście
  generatora obciążenia, wycinki logów węzłów `logs/`, notatki agenta z każdego przebiegu, momenty do synchronizacji
  nagrań ekranu. Zawierają szczegóły hosta albo są notatkami roboczymi; każda liczba w RESULTS pochodzi z opublikowanych
  plików albo ma oznaczone, że pochodzi z notatek przebiegu (czasy kroków T10, profil w T6).
- **Pliki `harness_note.txt`** przetłumaczono z polskich oryginałów albo napisano na podstawie notatek przebiegu tam,
  gdzie notatki nie było (`T4-20261116-133519`, `T4-20261116-135751`).
- Jeden komunikat błędu w `T8-20261116-105457/summary.json` zostaje po polsku, tak jak wypisał go host Windows.

## 🔄 Odbudowa wykresów

```powershell
python tools/make_charts.py            # czyta results/runs, zapisuje docs/img/results/*.svg (EN) i *_pl.svg (PL)
```

Tylko biblioteka standardowa (Python 3.8+). Wykresy: RTO wg testu (zaliczone przebiegi, mediana), lag wokół awarii dla
testów T1, T2, T3, T4b, T5, T6, T7 oraz oś stanów zasobów dla jednego reprezentatywnego przebiegu na test (przebieg
środkowy, a dla T4 pierwszy pełny przebieg).
