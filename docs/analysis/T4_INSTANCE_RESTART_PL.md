# 🔍 Analiza: dlaczego CRS raz podnosi ggcdb1 po kill -9 PMON, a raz nie (T4 / T4b)

🇬🇧 [English](T4_INSTANCE_RESTART.md) | 🇵🇱 Polski

[![Status](https://img.shields.io/badge/Analiza-wyjaśnione-success)]()
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![CRS](https://img.shields.io/badge/CRS-RESTART__ATTEMPTS%3D2-blue)]()

> 🎯 Wniosek: to nie przypadek. W dwóch przebiegach bez restartu wyczerpał się limit lokalnych restartów zasobu
> `ora.ggcdb.db`: `RESTART_ATTEMPTS=2` w oknie `UPTIME_THRESHOLD=1h`. Trzecie zabicie PMON w ciągu godziny = brak
> restartu. Pomiar 16.11.2026; wyniki w [RESULTS_PL.md](../RESULTS_PL.md#t4--awaria-instancji-kill--9-pmon).

## 📋 Atrybuty zasobu (`crsctl stat res ora.ggcdb.db -f` na ggrac1, odczyt po serii testów)

| Atrybut | Wartość | Znaczenie |
|---|---|---|
| `RESTART_ATTEMPTS` | 2 | ile razy CRS restartuje instancję lokalnie, zanim się podda |
| `UPTIME_THRESHOLD` | 1h | licznik restartów zeruje się dopiero po godzinie pracy bez awarii (albo po ręcznym starcie) |
| `FAILURE_INTERVAL` / `FAILURE_THRESHOLD` | 60 / 1 | po wyczerpaniu restartów awaria trafia do `FAILURE_HISTORY` |
| `INSTANCE_FAILOVER` | 0 | instancji RAC nie przenosi się na inny węzeł, stąd „Failover cannot be completed” |
| `FAILURE_HISTORY` (`-v`) | dwa wpisy | 14:45:06 UTC i 15:44:09 UTC, czyli dokładnie przebiegi `T4-20261116-144352` i `T4b-20261116-154243` |

Wartości są domyślne po `dbca`; lab ich nie zmieniał. Opis atrybutów: *Oracle Clusterware Administration and Deployment
Guide*, dodatek „Oracle Clusterware Resource Reference”.

## ⏱️ Kolejność zdarzeń (UTC; `crsd.trc` na ggrac2 jest w CET, czyli +1 h)

| Przebieg | kill -9 PMON | Decyzja CRS (`crsd.trc` ggrac2) | Licznik |
|---|---|---|---|
| T4 `133519` | 13:36:25 | lokalny restart (14:36:29 CET) | 1 |
| T4 `135751` (przerwany) | ok. 13:58:59 | lokalny restart (14:58:59 CET) | 2 |
| `lab.cmd baseline` | 14:09 | instancja działała, nie było ręcznego startu: licznik bez zmian | 2 |
| T4 `144352` | 14:44:59 | **`No Local Restart of [ora.ggcdb.db 1 1], restart attempt exhausted`** (15:45:06 CET), zatrzymanie drzewa zasobów, CRSPE00198 | wyczerpany |
| `lab.cmd baseline` (start instancji) | 15:10 | ręczny start `ora.ggcdb.db` na ggrac1 (16:10 CET), licznik wyzerowany | 0 |
| T4b `152230` | 15:23:47 | lokalny restart (16:23:50 CET) | 1 |
| T4b `153428` | 15:35:35 | lokalny restart (16:35:59 CET) | 2 |
| T4b `154243` | 15:43:48 | **`restart attempt exhausted`** (16:44:09 CET) | wyczerpany |

Wyciąg z `crsd.trc`: [crsd_restart_attempts_excerpt.txt](../../results/runs/crsd_restart_attempts_excerpt.txt)
(10 linii). Przebieg `135751` nie ma `t_fault` w `summary.json` (przerwany przed końcowym podsumowaniem), ale notatki
przebiegu i `crsd.trc` potwierdzają, że awaria została wywołana.

## 🧭 Co to znaczy dla wyników

- T4 `144352` i T4b `154243` mierzą inny scenariusz: „trzecia awaria instancji w ciągu godziny”, a nie „pierwsza
  awaria”. CRS działa zgodnie z konfiguracją: po wyczerpaniu restartów zatrzymuje instancję i jej drzewo zasobów
  i czeka na człowieka.
- Zatrzymanie GoldenGate w T4 to osobna sprawa (twarda zależność XAG od serwisu, CRS-0222). Występuje też wtedy, gdy
  instancja wraca (`133519`).
- Jednym zdaniem: CRS restartuje padniętą instancję dwa razy w ciągu godziny, za trzecim razem się poddaje. Widać to
  w danych: dwie awarie z restartem, potem brak restartu.

## 🔧 Możliwe usprawnienia (niewdrożone)

1. Automat testów: przed T4/T4b zapisać `RESTART_COUNT` instancji 1 (`crsctl stat res ora.ggcdb.db -v`) do oczekiwania,
   do `summary.json` dodać pole `restart_budget_left` i ostrzegać, gdy `RESTART_COUNT >= RESTART_ATTEMPTS`.
2. Przed T4/T4b wyzerować licznik (`srvctl stop instance -db ggcdb -instance ggcdb1` + `srvctl start instance ...`)
   albo robić odstęp ponad godzinę między przebiegami. Pierwsze zmienia stan labu przed testem.
3. Zmiana `RESTART_ATTEMPTS`: nie. To wartość domyślna, a testy pokazują zachowanie domyślne.
