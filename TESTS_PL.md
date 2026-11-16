# 🧪 Testy awarii T1–T10 i T4b: GoldenGate 26ai na RAC 26ai

🇬🇧 [English](TESTS.md) | 🇵🇱 Polski

[![Testy](https://img.shields.io/badge/Testy-T1--T10_+_T4b-blueviolet)]()
[![Pomiar](https://img.shields.io/badge/Pomiar-16.11.2026-success)](docs/RESULTS_PL.md)
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![HA](https://img.shields.io/badge/HA-XAG_10.2_+_ACFS-blue)]()

> 🎯 Co psuje każdy test awarii, dlaczego taka awaria ma znaczenie w prawdziwym życiu, czego się spodziewaliśmy i na
> jakiej podstawie, dokładne polecenie awarii (z automatu i ręcznie), co mierzymy, kiedy przebieg jest zaliczony i jak
> lab wraca do stanu bazowego. Oracle nie publikuje czasów failoveru XAG, więc lab mierzy, zamiast zakładać.
> Wyniki: [docs/RESULTS_PL.md](docs/RESULTS_PL.md).

Pojęcia takie jak XAG, singleton serwis, lag heartbeatu czy `oggvip` objaśnia [docs/CONCEPTS_PL.md](docs/CONCEPTS_PL.md).
Mapa, gdzie uderza każdy test: [docs/diagrams/04-failure-tests_pl.svg](docs/diagrams/04-failure-tests_pl.svg).

## 🧭 Jak działa każdy test

### Stan bazowy

Przebieg startuje tylko ze **stanu bazowego**, który sprawdza `Assert-Baseline` (`host/Tests.psm1`); w innym razie
odmawia startu i wypisuje odchylenia:

- zasób XAG (GoldenGate), serwis `gg_srcpdb`, ACFS `ora.data.oggvol.acfs` i VIP `oggvip` ONLINE na `ggrac1`;
- oba węzły Active, obie instancje ONLINE;
- `EXT1`, `DP1`, `REP1` RUNNING;
- lag poniżej 30 s.

`lab.cmd baseline` doprowadza lab do tego stanu (startuje wyłączone VM, przywraca łącze interconnect, startuje instancje,
przenosi serwisy i GoldenGate z powrotem na `ggrac1`). `run_test.ps1` uruchamia go sam po każdym przebiegu i zapisuje
jego czas jako `back_to_base_s`.

### Obciążenie

`guest/shared/loadgen.sh`, uruchamiany z `ggtgt` (przeżywa każdą awarię RAC), zapisuje 10 wierszy/s przez **obie**
instancje naraz: jedna sesja przez `srv_load1` (`ggcdb1`), druga przez `srv_load2` (`ggcdb2`), wiersze z `SEQ`, `INST`,
`TS` w `SALES.LOAD_EVENTS`. Dopiero wtedy zgodność źródła i celu dowodzi, że Extract przeczytał też wątek redo instancji,
która padła. Obciążenie jest zatrzymywane **w bazie** przed porównaniem.

### Przebieg w czasie

`PreSec` obciążenia (60 s) → awaria (`t_fault`) → czekanie na powrót (najwyżej `TimeoutSec`) → obserwacja `PostSec` →
zatrzymanie obciążenia → porównanie danych (powtarzane do zgodności, najwyżej 180 s) → zapis dowodów → `lab.cmd baseline`.

**Powrót** znaczy: po awarii widać zakłócenie (próbka inna niż stan bazowy), potem cały łańcuch (serwis, ACFS, VIP,
zasób XAG) ONLINE na jednym węźle, na oczekiwanym węźle, jeśli test go ma, `EXT1`, `DP1`, `REP1` RUNNING i lag poniżej 30 s.

### Co mierzymy

Próbniki na hoście odpytują węzły przez SSH (CRS co 1 s, procesy GoldenGate co 2 s, lag co 1 s) z jednym zegarem: host,
UTC, milisekundy. Zmiany stanu trafiają do `events.csv`; znaczniki liczy z niego `host/Evidence.psm1`, nikt ich nie
wpisuje ręcznie. Wszystkie znaczniki to sekundy od `t_fault`.

| Znacznik | Znaczenie |
|---|---|
| `t_fault` | czas hosta tuż przed poleceniem awarii (0) |
| `t_crs_detect` | pierwszy znak, że klaster zauważył: węzeł wypada z klastra; gdy tego nie ma (zabita instancja albo proces), pierwszy zasób łańcucha, który przestaje działać (instancja, serwis, ACFS, VIP, zasób XAG, `EXT1`, `DP1`) |
| `t_service_online` | serwis `gg_srcpdb` znów ONLINE albo ONLINE na innym węźle |
| `t_acfs_online` | ACFS znów ONLINE, na węźle z `oggvip` |
| `t_vip_online` | `oggvip` znów ONLINE albo na innym węźle |
| `t_sm_running` | **zasób XAG `xag.oggsource.goldengate` znów ONLINE** (stan w CRS, nie proces Service Managera) |
| `t_ext_running`, `t_dp_running`, `t_rep_running` | `EXT1`, `DP1`, `REP1` znów RUNNING po innym stanie |
| `t_lag_ok` | **pierwszy trwały powrót laga poniżej 30 s**: pierwsza próbka poniżej 30 s po pierwszej próbce ≥ 30 s, po której w ciągu 20 s nie ma kolejnej próbki ≥ 30 s. Późniejsze przekroczenia liczą się jako `lag_relapses`, nie jako powrót |
| `t_intervention_ready`, `t_intervention` | tylko T4b: kiedy ręczne przeniesienie zostało zaproponowane i kiedy ruszyło |

- **RTO** (`rto_s`, czas przywrócenia) = `t_rep_running − t_fault`, gdy Replicat miał przerwę; gdy `REP1` działał cały
  czas (każdy przebieg 16.11.2026), `t_lag_ok − t_fault`; gdy nie ma żadnego z nich, `t_ext_running − t_fault`.
  `summary.json` podaje podstawę w `rto_basis`. W praktyce: **czas, po którym cel znów jest mniej niż 30 s za źródłem.**
- **Lag** = `incoming_lag + incoming_heartbeat_age` z najświeższego wiersza ścieżki w `ggadmin.gg_lag` na celu (heartbeat
  co 5 s), `lag.csv`.
- **Dane** (`compare.json`): `sql/10_compare.sql` po obu stronach daje `COUNT(*)` i `SUM(ORA_HASH(...))` dla każdej
  tabeli (HR i SALES) oraz kontrolę `SEQ` per instancja: brakujące, nadmiarowe i zdublowane wiersze. `data_ok` wymaga
  równych wszystkich tabel, wierszy obciążenia naprawdę zapisanych na źródle i czystej kontroli `SEQ`.
- Zapisywane też: `final_node`, `evicted_node`, `service_moved`, `xag_action` (`restart_in_place`, `relocate`, `none`),
  `xag_restarts`, `lag_max_s`, `expected_check` (oczekiwanie kontra wynik), przesunięcia zegarów VM.

### Werdykty

- **Zaliczony:** powrót w `TimeoutSec`, dane zgodne, bez odmowy.
- **Odmowa:** lab nie był w stanie bazowym, awarii nie wywołano.
- **Błąd automatu** (`harness_error`): zawiódł skrypt testu (np. polecenie awarii zwróciło błąd); to nie jest wynik klastra.
- **Błąd pomiaru** (`measurement_error`, ustawiany potem z notatką): próbnik zmierzył źle; przebieg zostaje, ale liczby
  z niego nie są używane.
- Każdy przebieg, także nieudany, zostaje w `results/<test>-<yyyyMMdd-HHmmss>/`. Opublikowane kopie są w
  [results/runs/](results/runs/).

## 🚀 Jak uruchomić test samemu

Wymagania: lab po `lab.cmd validate` ([docs/INSTALL_AUTO_PL.md](docs/INSTALL_AUTO_PL.md)), PowerShell 7 na hoście
Windows, klucz SSH labu, `$env:LAB_PASS` ustawione w tym samym oknie (zob. [SETTINGS.md](SETTINGS.md)).

```powershell
cd D:\labs\gg-rac26ai-lab
$env:LAB_PASS = '<hasło labu>'                       # nigdy nie trafia do repozytorium
.\tests\run_test.ps1 -Test T2 -DryRun                # wypisuje plan, niczego nie zmienia
.\tests\run_test.ps1 -Test T2 -ApprovedBy <nazwa>    # jeden przebieg
.\tests\run_test.ps1 -Test T2 -ApprovedBy <nazwa> -Repeat 3
```

- `-ApprovedBy <nazwa>` jest **wymagane** przy wyłączeniu VM, przecięciu interconnectu, teście niszczącym (T6, T7)
  i interwencji w T4b; bez niego skrypt kończy się kodem 2. Nazwa trafia do `summary.json`.
- `-ManualStepDone` jest wymagane w T6 (najpierw ręcznie flaga, zob. T6).
- `-NoBaseline` pomija automatyczne `lab.cmd baseline` po przebiegu (wtedy przywróć lab sam).
- `-Back` to mierzony „powrót do stanu bazowego” (przeniesienie serwisu i GoldenGate z powrotem na `ggrac1`); skoro
  `lab.cmd baseline` idzie po każdym przebiegu, jest opcjonalny.
- Kod wyjścia: 0 = każdy przebieg zaliczony, 1 = przebieg nieudany albo odmowa, 2 = odmowa przed startem.
- Wynik: `results/<test>-<yyyyMMdd-HHmmss>/` z `events.csv`, `lag.csv`, `load.csv`, `compare.json`, `summary.json`,
  `commands.txt` (każde polecenie z czasem i wyjściem, hasła zamaskowane), wycinki logów; `results/summary_all.csv`.

## 📋 Przegląd

| Test | Awaria | Zgoda | Przebiegi 16.11.2026 |
|---|---|---|---|
| [T1](#t1--planowe-przeniesienie) | `agctl relocate` na `ggrac2` | nie | 5 (3 zaliczone) |
| [T2](#t2--twarde-wyłączenie-węzła-z-goldengate) | wyłączenie `ggrac1` | tak | 3 (3 zaliczone) |
| [T3](#t3--wyłączenie-drugiego-węzła) | wyłączenie `ggrac2` | tak | 3 (3 zaliczone) |
| [T4](#t4--awaria-instancji-kill--9-pmon) | `kill -9` PMON `ggcdb1` | nie | 6 (0 zaliczonych) |
| [T4b](#t4b--awaria-instancji--ręczne-przeniesienie-goldengate) | jak T4 + ręczne przeniesienie po 120 s | tak (na żywo) | 3 (3 zaliczone) |
| [T5](#t5--zabicie-service-managera) | `kill -9` Service Managera | nie | 3 (3 zaliczone) |
| [T6](#t6--extract-oznaczony-critical-to-deployment-health-) | flaga WŁ. + `kill -9` `EXT1` | tak ⚠️ | 3 (3 zaliczone) |
| [T7](#t7--przecięty-interconnect-) | interconnect `ggrac2` w dół | tak ⚠️ | 1 (1 zaliczony) |
| [T8](#t8--lag-pod-obciążeniem-bez-awarii) | brak (10 min obciążenia) | nie | 3 (1 zaliczony) |
| [T9](#t9--porównanie-danych) | brak | nie | 1 (1 zaliczony) |
| [T10](#t10--ddl-i-typy-danych-26ai) | brak (DDL i nowe typy) | nie | 2 (2 zaliczone, 1 bez DDL) |

⚠️ = może zostawić lab zepsuty do ręcznej naprawy.

---

### T1 — Planowe przeniesienie

**Po co ten test i co ma pokazać.** Każde okno serwisowe na węźle RAC (łatanie, sprzęt) zaczyna się od przeniesienia
z niego GoldenGate. Pytanie: czy łańcuch XAG przechodzi we właściwej kolejności (stop Service Managera → ACFS → VIP na
drugim węźle → start → procesy od checkpointów) i czy `agctl relocate` przenosi też singleton serwis `gg_srcpdb`, czy
potrzebny jest osobny `srvctl relocate service`? Oczekiwanie: GoldenGate na `ggrac2`, zero straconych danych, RTO
nieznane. Podstawa: MAA (`agctl relocate` to opisany sposób przenoszenia GoldenGate) i opis agctl w dokumentacji XAG.

- **Start:** stan bazowy. Zgoda niepotrzebna.
- **Awaria (automat):** jako `root` na `ggrac2`: `/u01/app/xag/bin/agctl relocate goldengate oggsource --node ggrac2`.
- **Ręcznie, bez automatu:** to samo polecenie, potem obserwacja `crsctl stat res -t` i `agctl status goldengate oggsource`.
- **Mierzymy:** wszystkie znaczniki, czy serwis się przeniósł (`service_moved`), krzywą laga, dane.
- **Zaliczenie:** GoldenGate na `ggrac2`, `EXT1`/`DP1`/`REP1` RUNNING, lag poniżej 30 s, dane zgodne, bez brakujących
  i zdublowanych `SEQ`.
- **Powrót do bazy:** `lab.cmd baseline` (przenosi serwis i GoldenGate z powrotem na `ggrac1`).
- **Ryzyka:** dla labu żadne; zły próbnik laga może sprawić, że dobry przebieg wygląda na nieudany (zdarzyło się raz, zob. RESULTS).
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T1 -Repeat 3` (PreSec 60, PostSec 120, TimeoutSec 600).

### T2 — Twarde wyłączenie węzła z GoldenGate

**Po co ten test i co ma pokazać.** Awaria zasilacza, płyty głównej albo hypervisora: węzeł z GoldenGate znika bez
czystego zamknięcia. Pytanie: czy wszystko wraca bez człowieka, ile to trwa i czy Extract doczytuje redo padniętej
instancji (wątek 1), żeby nic nie zginęło? Oczekiwanie: wykluczenie `ggrac1` → serwis na `ggcdb2` → ACFS → VIP →
Service Manager → Extract; GoldenGate na `ggrac2`; 0 straconych wierszy; RTO nieznane. Podstawa: MAA (GoldenGate idzie
za singleton serwisem PDB).

- **Start:** stan bazowy; zgoda na wyłączenie VM.
- **Awaria (automat):** na hoście: `VBoxManage controlvm ggrac1 poweroff`.
- **Ręcznie:** to samo polecenie; na serwerach fizycznych wyłączenie przez kartę zarządzającą (iLO, iDRAC, IPMI) albo
  wyjęcie kabli zasilania. Nie `shutdown`: to czyste zatrzymanie, inny test.
- **Mierzymy:** wszystkie znaczniki i odcinki między nimi, `evicted_node`, krzywą laga, wiersze `SEQ` z `INST=1` na celu.
- **Zaliczenie:** samodzielny powrót na `ggrac2`, dane zgodne; RTO zapisujemy, nie oceniamy.
- **Powrót do bazy:** `lab.cmd baseline` (startuje `ggrac1`, czeka na klaster, przenosi wszystko z powrotem).
- **Ryzyka:** `+FRA` się zapełnia, gdy Extract nie działa; po twardym wyłączeniu start węzła może trwać dłużej.
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T2 -ApprovedBy <nazwa> -Repeat 3` (PreSec 60, PostSec 120, TimeoutSec 900).

### T3 — Wyłączenie drugiego węzła

**Po co ten test i co ma pokazać.** Pada węzeł **bez** GoldenGate. Wygląda niegroźnie, ale Extract i tak musi przeczytać
każdą zatwierdzoną zmianę padniętej instancji (wątek 2) z jej redo i archiwów we wspólnym `+FRA`. Pytanie: czy GoldenGate
zostaje na miejscu, jak duży jest skok laga i czy każdy wiersz `INST=2` zatwierdzony przed awarią dociera na cel?
Oczekiwanie: GoldenGate zostaje na `ggrac1`; najwyżej krótki skok laga do zamknięcia wątku 2; 0 straconych wierszy.
Podstawa: działanie wątków redo RAC i integrated capture (zob. CONCEPTS); brak opublikowanej liczby.

- **Start:** stan bazowy; zgoda na wyłączenie VM.
- **Awaria (automat):** `VBoxManage controlvm ggrac2 poweroff`.
- **Ręcznie:** jak w T2, ale na węźle bez GoldenGate.
- **Mierzymy:** lag co 1 s, `t_crs_detect` (wykluczenie), `lag_relapses`, wiersze `SEQ` z `INST=2`.
- **Zaliczenie:** GoldenGate zostaje na `ggrac1`, lag wraca poniżej 30 s, dane zgodne.
- **Powrót do bazy:** `lab.cmd baseline` (startuje `ggrac2`, wraca `srv_load2`).
- **Ryzyka:** po starcie `ggrac2` ACFS może być zamontowany na obu węzłach; `lab.cmd baseline` to porządkuje.
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T3 -ApprovedBy <nazwa> -Repeat 3` (PreSec 60, PostSec 300, TimeoutSec 600).

### T4 — Awaria instancji (kill -9 PMON)

**Po co ten test i co ma pokazać.** Wiele runbooków nazywa „shutdown abort” testem awarii węzła, ale padnięta instancja
na żyjącym węźle to inna ścieżka: węzeł, ACFS i VIP działają, znika tylko instancja bazy. Pytanie: czy GoldenGate idzie
za serwisem na drugi węzeł? Oczekiwanie: GoldenGate na `ggrac2`, 0 straconych wierszy, RTO nieznane. Podstawa: MAA
i opis XAG dla `--use_local_services` (GoldenGate działa tam, gdzie serwis). Ryzyko nazwane przed przebiegiem: XAG
zostaje na `ggrac1` bez bazy.

- **Start:** stan bazowy.
- **Awaria (automat):** jako `root` na `ggrac1`:
  `p=$(pgrep -f '[o]ra_pmon_ggcdb1'); [ -n "$p" ] || { echo 'no pmon process'; exit 3; }; kill -9 $p`
  (brak procesu PMON = awaria nie zaszła, przebieg się przerywa).
  **Nie** używamy `srvctl stop instance -db ggcdb -instance ggcdb1 -stopoption abort`: to planowe zatrzymanie i CRS go
  odrzuca, póki działa tam singleton serwis (CRS-2974, serwis wymagałby `-force`). Trzy przebiegi z nim 16.11.2026
  skończyły się błędem automatu.
- **Ręcznie:** ten sam `kill -9` jako `root` na węźle `ggcdb1`.
- **Mierzymy:** te same znaczniki co w T2, żeby dało się je porównać, `service_moved`, `final_node`.
- **Zaliczenie:** łańcuch na `ggrac2`, choć węzeł 1 żyje, dane zgodne.
- **Powrót do bazy:** `lab.cmd baseline` (czeka na autostart `ggcdb1` przez CRS albo ją startuje, przenosi serwis
  z powrotem, potem XAG startuje na `ggrac1`).
- **Ryzyka:** CRS restartuje instancję lokalnie najwyżej `RESTART_ATTEMPTS` razy (2) w ciągu `UPTIME_THRESHOLD` (1 h).
  Trzecia awaria w ciągu godziny zostawia instancję wyłączoną ([analiza](docs/analysis/T4_INSTANCE_RESTART_PL.md)).
  Między przebiegami T4/T4b odczekaj godzinę albo zrestartuj instancję ręcznie, żeby wyzerować licznik.
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T4` (PreSec 60, PostSec 120, TimeoutSec 900).

### T4b — Awaria instancji + ręczne przeniesienie GoldenGate

**Po co ten test i co ma pokazać.** T4 pokazał, że po awarii instancji GoldenGate sam nie wraca. T4b mierzy, ile to
kosztuje, gdy reaguje dyżurny DBA: od awarii i od ręcznego przeniesienia do lag OK. Oczekiwanie: po przeniesieniu
GoldenGate startuje na `ggrac2` razem z serwisem, VIP i ACFS idą za nim, 0 straconych wierszy. Podstawa: wynik T4
(CRS-0222, brak ponowienia) i `agctl` jak w T1.

- **Start:** stan bazowy; zgoda na interwencję.
- **Awaria:** jak w T4.
- **Interwencja (automat, 120 s po awarii, jako `root` na `ggrac2`):**
  1. jeśli `agctl status goldengate oggsource` mówi „is running on”: `agctl relocate goldengate oggsource --node ggrac2`;
  2. w przeciwnym razie `agctl start goldengate oggsource --node ggrac2`;
  3. jeśli ten start zostanie odrzucony, bo `oggvip` działa na `ggrac1`: `crsctl relocate resource oggvip -n ggrac2 -f`,
     potem znowu start.
- **Zgoda na żywo:** po 120 s skrypt wypisuje `INTERVENTION READY` z całą gałęzią poleceń i czeka do 600 s na plik
  `approve_intervention` w katalogu przebiegu z treścią `approved_by=<nazwa>`. Brak pliku = brak przeniesienia
  (`intervention not approved`). `summary.json` zapisuje `t_intervention_ready`, `t_intervention`, `approval_wait_s`.
- **Ręcznie:** `kill -9` PMON jak w T4, odczekać ok. 2 minuty, sprawdzić `agctl status goldengate oggsource`, potem krok
  1 albo 2 (krok 3 tylko, gdy start zostanie odrzucony).
- **Mierzymy:** znaczniki T4 plus znaczniki interwencji; przydatna wartość pochodna: `t_lag_ok − t_intervention`
  (koszt samego ręcznego przeniesienia).
- **Zaliczenie:** łańcuch na `ggrac2`, dane zgodne. „Powrót bez człowieka” tu nie dotyczy.
- **Powrót do bazy:** `lab.cmd baseline`.
- **Ryzyka:** jak w T4 (limit restartów instancji).
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T4b -ApprovedBy <nazwa>`, a po `INTERVENTION READY` utworzyć plik:
  `Set-Content <katalog przebiegu>\approve_intervention 'approved_by=<nazwa>'`.

### T5 — Zabicie Service Managera

**Po co ten test i co ma pokazać.** Awaria procesu albo omyłkowy `kill`: węzeł i baza żyją, znika tylko Service Manager
GoldenGate. Pytanie: co robi XAG (restart na miejscu czy przeniesienie na drugi węzeł) i ile to trwa? Oczekiwanie:
XAG/CRS zauważa brak procesu i restartuje deployment na miejscu albo go przenosi; 0 straconych wierszy. Podstawa:
akcja sprawdzająca XAG; znany błąd 37468391 (XAG zabija wszystkie procesy GoldenGate na węźle) wymaga więcej niż
jednego Service Managera, a ten lab ma jeden.

- **Start:** stan bazowy.
- **Awaria (automat):** jako `root` na `ggrac1`:
  `p=$(pgrep -f '/u01/app/ogg/ogg26ai_ma/bin/[S]erviceManager'); [ -n "$p" ] || { echo 'no ServiceManager process'; exit 3; }; kill -9 $p`.
- **Ręcznie:** to samo polecenie.
- **Mierzymy:** `xag_action`, `xag_restarts`, znaczniki, lag.
- **Zaliczenie:** deployment i procesy znów RUNNING bez człowieka, dane zgodne.
- **Powrót do bazy:** `lab.cmd baseline` (potrzebny tylko, gdy XAG przeniósł GoldenGate).
- **Ryzyka:** niskie; jeśli XAG zamiast restartu na miejscu wybierze przeniesienie, GoldenGate skończy na `ggrac2`, a
  przebieg zmierzy przeniesienie (`xag_action` mówi, co się stało).
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T5 -Repeat 3` (PreSec 60, PostSec 120, TimeoutSec 600).

### T6 — Extract oznaczony „Critical to deployment health” ⚠️

**Po co ten test i co ma pokazać.** Jedna opcja w profilu zarządzanych procesów może zmienić reakcję klastra. MAA
ostrzega, że awaria procesu oznaczonego „Critical to deployment health” może przeszkodzić XAG w restarcie deploymentu.
Pytanie: co naprawdę dzieje się, gdy taki Extract padnie? Oczekiwanie: niczego nie zakładamy („może przeszkodzić” to nie
„blokuje”); zapisujemy faktyczny skutek. Podstawa: dokument MAA, część o profilu zarządzanych procesów.

- **Start:** stan bazowy; zgoda; ręcznie przed przebiegiem: w Web UI `oggsource` (przez `oggvip`) Extract `EXT1` →
  Managed Options → „Critical to deployment health” WŁ. Skrypt odmawia T6 bez `-ManualStepDone`.
- **Awaria (automat):** jako `root` na `ggrac1`:
  `p=$(pgrep -f '[e]xtract.*EXT1'); [ -n "$p" ] || { echo 'no extract process'; exit 3; }; kill -9 $p`.
- **Ręcznie:** ustawić flagę, potem ten sam `kill -9`.
- **Mierzymy:** znaczniki, stan zasobu XAG (INTERMEDIATE), `xag_action`, lag.
- **Zaliczenie:** zapisany faktyczny skutek; powrót i zgodne dane dają zaliczenie.
- **Powrót do bazy:** flaga WYŁ. w Web UI, `lab.cmd baseline`.
- **Ryzyka:** deployment leży do ręcznej naprawy (16.11.2026 się nie zdarzyło). Automat nie zapisuje: eksportu profilu
  przed przebiegiem ani liczby prób restartu `EXT1`.
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T6 -ApprovedBy <nazwa> -ManualStepDone -Repeat 3` (PreSec 60, PostSec 180, TimeoutSec 900).

### T7 — Przecięty interconnect ⚠️

**Po co ten test i co ma pokazać.** Oba węzły żyją, ale nie słyszą się w sieci prywatnej (przełącznik, kabel, karta
sieciowa). Klaster musi wybrać jeden węzeł, który zostaje, żeby uniknąć split brain (dwóch „mózgów” naraz). Pytanie:
który węzeł wypada, gdzie kończy GoldenGate i jak Extract znosi wątek redo, który ucichł? Oczekiwanie: dokładnie jeden
węzeł wypada z klastra (który, mierzymy), GoldenGate kończy na tym, który zostaje, replikacja wraca, 0 straconych
wierszy. Podstawa: wykluczanie węzłów przez Clusterware (`ocssd`), brak opublikowanej liczby dla GoldenGate.

- **Start:** stan bazowy; zgoda.
- **Awaria (automat):** na hoście: `VBoxManage controlvm ggrac2 setlinkstate3 off` (NIC3 = sieć wewnętrzna `ggrac-ic`).
- **Ręcznie:** to samo polecenie; na serwerach fizycznych wyjęcie kabla interconnectu albo wyłączenie portu przełącznika.
  Wyłączenie interfejsu w systemie (`ip link set <karta interconnectu> down` na `ggrac2`) jest podobne, ale nie identyczne
  (niesprawdzone).
- **Mierzymy:** `evicted_node`, `t_crs_detect`, `final_node`, lag, dane.
- **Zaliczenie:** wypada dokładnie jeden węzeł, replikacja wraca, dane zgodne.
- **Powrót do bazy:** `lab.cmd baseline` (przywraca łącze `setlinkstate3 on`, czeka, aż `ggrac2` wróci do klastra
  i wystartuje jego instancja).
- **Ryzyka:** restart obu węzłów; pliki voting na jednym dysku współdzielonym.
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T7 -ApprovedBy <nazwa>` (PreSec 60, PostSec 180, TimeoutSec 1200).

### T8 — Lag pod obciążeniem (bez awarii)

**Po co ten test i co ma pokazać.** „Replikacja działa” nic nie znaczy bez liczby. T8 mierzy normalny lag pod obciążeniem,
czyli punkt odniesienia dla każdej krzywej w T1–T7, i dowodzi, że czytane są oba wątki redo. Oczekiwanie: lag cały czas
poniżej 30 s; dochodzą wiersze `INST` 1 i 2. Podstawa: w tej konfiguracji `ADD EXTRACT` nie ma opcji `THREADS`, więc
dowodem jest pomiar.

- **Start:** stan bazowy. **Awaria:** brak (`Kind = none`).
- **Ręcznie:** `loadgen.sh 10 600` i odpytywanie `select incoming_lag + incoming_heartbeat_age from ggadmin.gg_lag` na celu.
- **Mierzymy:** `lag.csv` (10 minut), wiersze per instancja po obu stronach, dane.
- **Zaliczenie:** lag poniżej 30 s przez cały przebieg, dane zgodne, wiersze obu instancji na celu.
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T8` (PreSec 60, PostSec 600).

### T9 — Porównanie danych

**Po co ten test i co ma pokazać.** Procesy RUNNING nie dowodzą, że nic nie zginęło ani się nie zdublowało. T9 to
porównanie, którym kończy się każdy inny test, uruchomione osobno. Oczekiwanie: równe liczby i sumy, zero brakujących
i zdublowanych `SEQ`.

- **Start:** stan bazowy. **Awaria:** brak.
- **Ręcznie:** `bash /root/lab/shared/compare.sh` jako `root` na węźle RAC i na `ggtgt`, potem porównać wiersze `COMPARE`
  i `SEQ`. (Oracle GoldenGate Veridata robi to jako produkt; licencjonowany osobno, tu nieużywany.)
- **Zaliczenie:** identyczne liczby i sumy `ORA_HASH`, czysta kontrola `SEQ`.
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T9` (PreSec 0, PostSec 30).

### T10 — DDL i typy danych 26ai

**Po co ten test i co ma pokazać.** Nowe aplikacje trzymają wektory AI i używają natywnych `BOOLEAN` i `JSON`; schematy
się zmieniają. Pytanie: czy `VECTOR`, `BOOLEAN`, `JSON` i DDL przechodzą przez Extract i Replicat bez zmian? Oczekiwanie:
wiersze i DDL zreplikowane, wartości równe. Podstawa: Release Notes GoldenGate 23ai/26ai (te typy są obsługiwane);
`DDL INCLUDE MAPPED` w `ogg/ext1.prm`.

- **Start:** stan bazowy. **Awaria:** brak. Automat daje spokojne okno 120 s (`PostSec`); kroki DDL wykonuje się
  w nim ręcznie.
- **Kroki (jako `oracle`, `sqlplus / as sysdba`; jedno polecenie w linii, 26ai odrzuca dwa polecenia w jednej linii
  błędem ORA-03405):**
  ```sql
  -- źródło, SRCPDB
  insert into sales.types26 (id,v,b,j) values (101, to_vector('[1.5,2.5,3.5]',3,FLOAT32), TRUE, json('{"t":"T10","n":101}'));
  commit;
  -- cel, TGTPDB: poczekać na wiersz, potem porównać
  select id||' '||from_vector(v)||' '||case when b then 'TRUE' else 'FALSE' end||' '||json_serialize(j) from sales.types26 where id=101;
  -- źródło: DDL
  alter table sales.types26 add (note varchar2(30));
  -- cel: poczekać na kolumnę
  select count(*) from all_tab_columns where owner='SALES' and table_name='TYPES26' and column_name='NOTE';
  -- źródło: wiersz z nową kolumną, potem porównanie jak wyżej
  insert into sales.types26 (id,v,b,j,note) values (102, to_vector('[-1,0.25,4]',3,FLOAT32), FALSE, json('{"t":"T10","n":102}'), 'after DDL');
  commit;
  -- źródło: sprzątanie (też replikowane)
  delete from sales.types26 where id in (101,102);
  commit;
  alter table sales.types26 drop column note;
  ```
- **Mierzymy:** czas od commita / DDL na źródle do widoczności na celu, wartości po obu stronach, `compare.json`.
- **Zaliczenie:** wiersze i DDL zreplikowane, wartości równe.
- **Uruchomienie:** `.\tests\run_test.ps1 -Test T10` (PreSec 0, PostSec 120), potem kroki wyżej w ciągu 120 s.

## 🔗 Zobacz też

- [docs/RESULTS_PL.md](docs/RESULTS_PL.md): wyniki pomiarów z 16.11.2026 z wykresami.
- [results/README_PL.md](results/README_PL.md): opublikowane surowe dane i ich pola.
- [docs/CONCEPTS_PL.md](docs/CONCEPTS_PL.md), [docs/OPERATIONS_PL.md](docs/OPERATIONS_PL.md).
