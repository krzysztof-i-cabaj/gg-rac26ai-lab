# ⏱️ Czasy — ile trwa każdy krok

🇬🇧 [English](TIMINGS.md) | 🇵🇱 Polski

[![Budowa](https://img.shields.io/badge/Czysta_budowa-ok._4_h_04_min-blue)]()
[![Pomiar](https://img.shields.io/badge/Pomiar-VirtualBox_na_laptopie-orange)]()
[![Baseline](https://img.shields.io/badge/baseline-mediana_67_s-success)]()
[![Stan](https://img.shields.io/badge/Tabela_budowy-do_ponownego_pomiaru-yellow)]()

> 🎯 Czyste czasy każdego kroku budowy i codziennych poleceń, zmierzone na tym labie. „Czysty” znaczy: tyle, ile krok
> potrzebuje, gdy nic się nie psuje, bez poprawek i powtórzeń z pierwszej budowy. Korzystaj z nich, planując własną
> budowę, a nie jako z testu wydajności: pochodzą z VirtualBoxa na laptopie.

## 📏 Warunki pomiaru

- Host: laptop z Windows 11, 64 GB RAM, VirtualBox 7, hypervisor Windows **wyłączony**. Pomiar z listopada 2026.
- Czasy pochodzą z dziennika kroków `logs/steps.csv` (zostaje lokalnie, nie ma go w repozytorium; początek i koniec każdego kroku `lab.cmd`, UTC), a tam, gdzie krok trzeba było
  powtórzyć, z logów Oracle udanej części (instalator, `root.sh`, dbca, asmca, oggca).
- **Wszystkie kroki budowy szły przy 2 vCPU na węzeł RAC**; węzły RAC miały **10 GB RAM** w krokach `grid` i `db`,
  14 GB od `dbca`. Obecna konfiguracja to 3 vCPU / 14 GB (patrz [ENVIRONMENT_PL.md](ENVIRONMENT_PL.md)), więc `grid`, a
  zwłaszcza `db` (węzły używały swapu) to wartości górne. Codzienne polecenia (`baseline`, `start`, `stop`) mierzono przy
  3 vCPU / 14 GB.
- `build` pobiera pakiety systemu z yum.oracle.com: szybkość łącza zmienia jego czas.
- Pełna budowa od zera na obecnych ustawieniach jest jeszcze do zrobienia; ta tabela zostanie nią zastąpiona.

## 🏗️ Kroki budowy (`lab.cmd all`)

| Krok | Czysty czas | Co jest w środku | Uwaga |
|---|---|---|---|
| `build` | 9 min 57 s | 4 maszyny, instalacja systemu z kickstartów | pełna budowa po `destroy` |
| `infra` | 13 s | dnsmasq, chrony, kontrole | |
| `prereq` | 2 min 03 s | resolver, czas, kontrole systemu na 2 węzłach | świeże maszyny |
| `shared` | 50 s | udev, zaufanie SSH | |
| `grid` | **1 h 28 min** | patrz niżej | 2 vCPU, 10 GB |
| `db` | **1 h 35 min** | stage 37 min 37 s (kopia i rozpakowanie DB, RU, OPatch), nakładanie RU 51 min 08 s, instalacja 5 min 58 s, `root.sh` po kilka sekund na węzeł | zawyżone: węzły z 10 GB używały swapu |
| `dbca` | 7 min 00 s | CDB RAC z jedną PDB, SQL przygotowujący | pełny przebieg od zera |
| `services` | 28 s | 3 serwisy, schemat demo, generator obciążenia | |
| `tgt` | ok. 30 min (± 30 s) | stage 13 min 16 s, instalacja DB 11 min 32 s, `root.sh` 1 s, dbca 4 min 38 s, schemat demo | |
| `acfs` | 43 s | wolumen, system plików, zasób | |
| `ogg` | 5 min 40 s | kopia ZIP-a i trzy instalacje po ok. 20 s (razem 304 s), `oggca` celu 13 s, rejestracja i kontrole 23 s | |
| `xag` | 1 min 30 s | instalacja XAG 10–19 s; VIP, `oggca` źródła (35 s), `agctl add`, kontrole | |
| `oggconf` | ok. 35 s | źródło ok. 8 s, ścieżka ok. 10 s, cel 17 s | przybliżone |
| `validate` | 1 min 40 s | kontrole, 60 s obciążenia, porównanie danych | |
| **Razem** | **ok. 4 h 04 min** (14 625 s) | `build` … `validate` | bez poprawek i powtórzeń |

### Wewnątrz `grid`

| Faza | Czysty czas |
|---|---|
| kopia ZIP-ów, rozpakowanie GI / OPatch / RU, `cvuqdisk` (stage) | 10 min 18 s (górna granica) |
| `gridSetup.sh -silent` z `-applyRU` (oprogramowanie) | 29 min 28 s |
| `root.sh` na ggrac1 | 8 min 09 s |
| `root.sh` na ggrac2 (po węźle 1) | 17 min 50 s |
| `gridSetup.sh -executeConfigTools` | 15 min 30 s |
| `asmca` dla `+FRA` | 3 min 08 s |
| walidacja | 3 min 47 s |
| **grid razem** | **1 h 28 min 10 s** |

Komunikaty w skryptach podają zgrubne oczekiwania („30–40 min” dla `gridSetup.sh`, „10–20 min” dla `root.sh`,
„40–70 min” dla `dbca` na RAC); zmierzone wartości są w tabelach powyżej.

## 🔁 Codzienne polecenia (pomiar przy 3 vCPU / 14 GB)

| Polecenie | Pomiar | Przebiegi |
|---|---|---|
| `lab.cmd baseline` | mediana 67 s; 50 s, gdy lab już jest w stanie bazowym; do 640 s zaraz po teście niszczącym | 38 |
| `baseline` po pełnym restarcie wszystkich maszyn | 347 s: klaster 31 s, instancje 78 s, serwisy 66 s, ACFS 3 s, procesy 96 s | 1 |
| `lab.cmd start` (wszystkie maszyny wyłączone → stan bazowy) | 365 s (kończy się `baseline`) | 1 pełny zimny start |
| `lab.cmd stop` (cały lab, ACPI) | 111–198 s | 3 |
| `lab.cmd validate` | 100 s | zbudowany lab |
| `lab.cmd iso`, gdy ISO już jest | 2–3 s | 9 |

Dlaczego `baseline` trwa różnie długo: po teście z wyłączeniem maszyny ta musi się uruchomić, a Clusterware musi
przyjąć węzeł z powrotem, zanim serwisy i GoldenGate mogą wrócić na miejsce; w stanie bazowym każda faza tylko sprawdza
(`noop`).

Czasy testów awarii (RTO, lag, czas powrotu do stanu bazowego) są w [RESULTS_PL.md](RESULTS_PL.md).
