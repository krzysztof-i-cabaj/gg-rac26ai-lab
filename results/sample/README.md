# 🧪 results/sample — synthetic example / przykład syntetyczny

[![Data](https://img.shields.io/badge/Data-synthetic-lightgrey)]()
[![Test](https://img.shields.io/badge/Test-T2-blueviolet)]()
[![Use](https://img.shields.io/badge/Use-static_tests,_film_blocks-blue)]()

> 🎯 **EN:** Invented numbers in the real file format of `tests/run_test.ps1`: for static tests and for building
> film blocks before the lab runs. `summary.json` carries `"synthetic": true`; never present these values as a measurement.
> **PL:** Zmyślone liczby w prawdziwym formacie plików `tests/run_test.ps1`: do testów statycznych i do budowy bloków
> filmu, zanim lab ruszy. `summary.json` ma `"synthetic": true`; tych wartości nie pokazujemy jako pomiaru.

## 📁 Files

- `T2-sample/events.csv` — state changes of the CRS/GoldenGate chain (only changes), `t_rel_s` from `t_fault`.
- `T2-sample/lag.csv` — heartbeat lag samples (shortened).
- `T2-sample/summary.json` — markers, segments, RTO computed from the two files by `host/Evidence.psm1`.
