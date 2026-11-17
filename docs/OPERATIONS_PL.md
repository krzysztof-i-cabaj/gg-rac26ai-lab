# 🛠️ Obsługa — status, start, stop, baseline, rozwiązywanie problemów

🇬🇧 [English](OPERATIONS.md) | 🇵🇱 Polski

[![Polecenia](https://img.shields.io/badge/lab.cmd-status_start_stop_baseline_validate-blue)]()
[![Stan bazowy](https://img.shields.io/badge/Stan_bazowy-etap_A-success)]()
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![GoldenGate](https://img.shields.io/badge/GoldenGate-23.26_+_XAG-blueviolet)]()

> 🎯 Codzienna praca ze zbudowanym labem: co robi każde polecenie `lab.cmd`, jak wygląda lab po pełnym restarcie, jak
> `baseline` przywraca stan bazowy, jak wyłączyć lab tak, żeby GoldenGate nie przeskoczył na drugi węzeł, i co zrobić,
> gdy coś nie wraca.

## 🧭 Stan bazowy

Od niego zaczynają się wszystkie testy awarii i jego pilnuje `validate` („etap A”):

- wszystkie cztery maszyny działają; obie instancje RAC `ggcdb1`, `ggcdb2` otwarte, `SRCPDB` otwarta na obu;
- serwisy na swoich instancjach **preferowanych**: `gg_srcpdb` i `srv_load1` na `ggcdb1`, `srv_load2` na `ggcdb2`;
- GoldenGate (zasób XAG `xag.oggsource.goldengate`), VIP `oggvip` i ACFS `/u01/oggdeploy` **razem na węźle serwisu
  `gg_srcpdb`** (ggrac1), ACFS zamontowany tylko na tym węźle;
- EXT1 i DP1 RUNNING w źródle, REP1 RUNNING na ggtgt, lag heartbeat poniżej 30 s;
- ggtgt: `oracle-db.service` i `OracleGoldenGate.service` aktywne.

## ⌨️ Polecenia

| Polecenie | Co robi |
|---|---|
| `lab.cmd status` | nazwa, adres i stan każdej maszyny w VirtualBoxie. Tylko odczyt |
| `lab.cmd ssh <vm>` | interaktywna powłoka roota na jednej maszynie (ten sam klucz i opcje co w skryptach) |
| `lab.cmd start [vm]` | uruchamia wyłączone maszyny w kolejności z konfiguracji (najpierw gginfra: DNS i czas). Bez nazwy maszyny potem uruchamia `baseline` |
| `lab.cmd stop [vm]` | naciska przycisk zasilania ACPI: najpierw ggtgt, potem węzły RAC, na końcu gginfra; czeka, aż każda maszyna się wyłączy |
| `lab.cmd baseline` | powrót do stanu bazowego po restarcie albo teście awarii, bez zmian w danych (szczegóły niżej) |
| `lab.cmd validate` | wszystkie kontrole po obu stronach, 60 s obciążenia, porównanie źródło = cel; kończy się `== VALID` |
| `lab.cmd destroy <vm\|all>` | usuwa maszyny i ich dyski, tylko te ze znacznikiem `vbox-lab:gg-rac26ai` |
| `lab.cmd plan` | podgląd bez zmian, przydatny też przy zbudowanym labie (kolumna stanu) |

`stop` i `start` nie patrzą, co działa wewnątrz maszyn. Dla strony RAC użyj przed `stop` uporządkowanego wyłączenia
opisanego niżej.

## ♻️ `baseline` — co przywraca

`baseline` najpierw włącza wyłączone maszyny (po testach T2, T3) i z powrotem podnosi kartę interconnectu obu węzłów RAC
(po teście T7), czeka na SSH wszystkich maszyn, potem uruchamia `guest/tgt/95_baseline.sh` i `guest/rac/95_baseline.sh`.
Fazy, każda jako wiersz `BASELINE <faza> <sekundy> done|noop`, zapisywane też do `logs\baseline_steps.csv`:

| Węzeł | Faza | Co się dzieje |
|---|---|---|
| ggtgt | `tgt_db` | uruchamia `oracle-db.service`, jeśli trzeba, czeka do 600 s na `TGTPDB` READ WRITE |
| ggtgt | `tgt_ogg` | uruchamia `OracleGoldenGate.service`, jeśli trzeba, czeka do 300 s na REP1 RUNNING (startuje go profil MAA) |
| ggrac1 | `cluster` | czeka do 900 s, aż `crsctl check cluster -all` pokaże online i oba węzły będą Active |
| ggrac1 | `instances` | daje CRS do 300 s na samodzielne uruchomienie instancji, potem `srvctl start instance` dla tych, które wciąż leżą |
| ggrac1 | `services` | każdy serwis wraca na swoją instancję preferowaną: `srvctl relocate service -oldinst -newinst` dla singletonu, `srvctl start service -instance` dla pozostałych. CRS nigdy sam nie przenosi serwisu z powrotem |
| ggrac1 | `goldengate` | GoldenGate na węźle serwisu `gg_srcpdb`: `agctl relocate goldengate`, jeśli działa gdzie indziej; jeśli nie działa, 120 s czekania (CRS może go właśnie uruchamiać), potem do trzech prób `agctl start goldengate --node` |
| ggrac1 | `acfs` | `srvctl stop filesystem -node <drugi>` tam, gdzie ACFS jest zamontowany, a GoldenGate nie działa |
| ggrac1 | `processes` | czeka do 300 s, aż VIP, ACFS, serwis i Service Manager będą ONLINE na jednym węźle, a EXT1 i DP1 RUNNING |

Potem te same kontrole co `validate`, ale **bez** obciążenia i bez porównania danych. Koniec:
`== BASELINE: lab in the base state (stage A) after N s`.

`baseline` **nie**: zmienia danych, nie usuwa ani nie tworzy od nowa obiektów GoldenGate, nie generuje obciążenia, nie
porównuje danych, nie zeruje liczników restartów zasobu bazy w CRS, nie włącza z powrotem AHF/TFA. Jeśli proces zostaje
w stanie ABENDED, `baseline` pada na kontrolach i to mówi.

Pomiar z 16.11.2026 (38 przebiegów, wiele zaraz po testach awarii): mediana 67 s, od 50 s (lab już w stanie bazowym) do
640 s; po pełnym restarcie wszystkich maszyn 347 s (klaster 31 s, instancje 78 s, serwisy 66 s, ACFS 3 s, procesy 96 s).
Szczegóły: [TIMINGS_PL.md](TIMINGS_PL.md).

## 🔁 Jak wygląda pełny restart

Po `lab.cmd stop` i ponownym włączeniu maszyn (bez `baseline`) lab **nie jest** w stanie bazowym i to normalne
zachowanie Clusterware:

- CRS sam uruchamia obie instancje. Wczesny ręczny `srvctl start instance` ściga się z nim (PRCZ-4054): `baseline` najpierw czeka.
- Serwisy startują na tej instancji, która wstała pierwsza, więc `gg_srcpdb` albo `srv_load2` mogą stać na swojej
  instancji **zapasowej**. CRS nie przenosi ich z powrotem.
- ACFS ma `AUTO_START=restore` i wstaje zamontowany na **obu** węzłach.
- CRS próbuje uruchomić GoldenGate przez XAG. Na węźle, który był jeszcze zajęty kontrolami startowymi, kontrola stanu XAG
  trwała dłużej niż limit skryptu 60 s i zasób zostawał OFFLINE; późniejszy `agctl start` działał.
- Na ggtgt systemd uruchamia bazę (`oracle-db.service`) i Service Manager (`OracleGoldenGate.service`), a profil MAA
  uruchamia REP1 ok. 60 s później.

`lab.cmd start` (bez nazwy maszyny) kończy się `baseline`, który to wszystko porządkuje. Pomiar: 365 s od wyłączonych
maszyn do stanu bazowego.

## ⏻ Uporządkowane wyłączenie (zalecane)

```powershell
.\lab.cmd shutdown -DryRun   # pokazuje każdy krok i polecenie, niczego nie zmienia
.\lab.cmd shutdown           # GoldenGate -> cel -> baza RAC -> CRS węzeł po węźle -> maszyny, raport w logs\shutdown_<ts>.txt
```

`host/new_shutdown_shortcut.ps1` tworzy skrót na pulpicie: najpierw pokazuje podgląd, a lab wyłącza dopiero po
potwierdzeniu. `shutdown` odmawia, gdy trwa test awarii; nieudany krok zatrzymuje sekwencję przed wyłączeniem maszyn
(`-Force` idzie dalej). Kroki poniżej to dokładnie to, co robi, do wykonania ręcznie.

`lab.cmd stop` tylko naciska przycisk zasilania każdej maszyny. Po stronie RAC zostawia to decyzję o GoldenGate
Clusterware'owi, a Clusterware robi to, do czego jest zbudowany: utrzymuje GoldenGate przy życiu. W tym labie
`crsctl stop cluster -all` wydane na ggrac1 najpierw zatrzymało ggrac1, a CRS **przeniósł GoldenGate, VIP i ACFS na
ggrac2**, zanim ggrac2 dostał własne polecenie zatrzymania. Zatrzymuj elementy w kolejności zależności, wtedy nic nie
ma powodu się przenosić:

```bash
# 1. [oracle na węźle, na którym działa GoldenGate: agctl status goldengate oggsource]
/u01/app/xag/bin/agctl stop goldengate oggsource
agctl status goldengate oggsource                      # not running
# 2. [root@ggtgt] GoldenGate celu, potem baza celu
#    jako oracle: adminclient, CONNECT http://ggtgt.gg.lab.test:9100 DEPLOYMENT oggtarget AS oggadmin, potem:
#    STOP REPLICAT *
systemctl stop OracleGoldenGate.service                # zatrzymuje TYLKO Service Manager (KillMode=process)
pgrep -fa 'adminsrvr|distsrvr|pmsrvr|recvsrvr|replicat' # to, co zostało: kill -TERM <pid>, aż lista będzie pusta
systemctl stop oracle-db.service
# 3. [oracle@ggrac1] baza RAC
srvctl stop database -db ggcdb
# 4. [root@ggrac1], potem [root@ggrac2]: Clusterware węzeł po węźle (nie „crsctl stop cluster -all”)
/u01/app/23.26/grid/bin/crsctl stop crs
```

```powershell
# 5. na hoście: wyłączenie maszyn
.\lab.cmd stop
```

Kontrola po kroku 4 na każdym węźle: brak procesów `ohasd` / `crsd`, `/u01/oggdeploy` już niezamontowany. Unikaj `crsctl stop crs -f`, chyba że zwykłe zatrzymanie wisi.

**GoldenGate celu (krok 2).** Jednostka `OracleGoldenGate.service`, którą rejestruje asystent konfiguracji GoldenGate (`oggca`), ma
`KillMode=process`: `systemctl stop` kończy tylko Service Manager, a serwery wdrożenia i Replicat działają dalej (skutek
uboczny: restart Service Managera nie przerywa replikacji). Przy wyłączaniu `lab.cmd shutdown` robi więc trzy
rzeczy: `STOP REPLICAT *` przez adminclient (Replicat zapisuje czysty punkt kontrolny), `systemctl stop`, a na koniec
SIGTERM dla serwerów, które zostały. Gdy Service Manager już nie działa (np. po przerwanym wcześniej wyłączaniu),
adminclient nie ma się z czym połączyć, więc krok od razu wysyła SIGTERM; Replicat wznowi się z punktu kontrolnego.

**Zmierzone (lab na laptopie, od stanu bazowego):** cały `lab.cmd shutdown` 352 s. Najdłużej trwa `crsctl stop crs` na
drugim węźle (ok. 205 s) i na pierwszym (ok. 70 s); GoldenGate źródła ok. 24 s, GoldenGate celu ok. 18 s, bazy po 6–10 s.

## 🩺 Szybka kontrola zdrowia

```powershell
.\lab.cmd status
.\lab.cmd validate          # albo bez obciążenia: .\lab.cmd baseline (on też naprawia)
```

Na węźle RAC (root):

```bash
crsctl stat res -t                                   # przegląd
agctl status goldengate oggsource
crsctl stat res oggvip ora.data.oggvol.acfs ora.ggcdb.gg_srcpdb.svc -t
bash /root/lab/shared/probe.sh crs 1 --once           # wiersz na zasób, tak widzi to automat testów
bash /root/lab/shared/probe.sh gg 1 --once            # procesy GoldenGate i lag
```

## 🚧 Rozwiązywanie problemów

| Objaw | Prawdopodobna przyczyna | Co zrobić |
|---|---|---|
| `validate` pada na rozmieszczeniu serwisów albo „ACFS ONLINE on exactly 1 node” po restarcie | normalne zachowanie po restarcie (sekcja wyżej) | `lab.cmd baseline` |
| GoldenGate OFFLINE po starcie klastra | kontrola stanu XAG dłuższa niż 60 s na zajętym węźle | `lab.cmd baseline` (ponawia), albo `agctl start goldengate oggsource --node <węzeł gg_srcpdb>` |
| GoldenGate zatrzymał się, gdy padła instancja pod nim, i nie wraca | twarda zależność od serwisu `gg_srcpdb` (patrz test T4 w [TESTS_PL.md](../TESTS_PL.md)) | `lab.cmd baseline` albo ręczne przeniesienie: `agctl relocate goldengate oggsource --node <drugi węzeł>` |
| instancja nie wstaje po `kill -9` procesu PMON, log CRS mówi „restart attempt exhausted” | `ora.ggcdb.db` restartuje instancję najwyżej `RESTART_ATTEMPTS=2` razy w oknie `UPTIME_THRESHOLD=1h` (wartość domyślna po dbca) | `srvctl start instance -db ggcdb -instance ggcdb1` (ręczny start zeruje też licznik); sprawdzenie: `crsctl stat res ora.ggcdb.db -v` |
| `agctl start` pada zaraz po `oggca` | Service Manager uruchomiony przez `oggca` działa poza XAG | zatrzymaj ten proces (`pgrep -af ServiceManager`), potem `agctl start` |
| proces ABENDED | przeczytaj jego raport | adminclient: `INFO ALL`, `VIEW REPORT ext1` (albo `rep1`); potem `START EXTRACT ext1` |
| lag wydaje się wysoki zaraz po przeniesieniu | `ggadmin.gg_lag` ma wiersz na każdą ścieżkę; stara ścieżka tylko się starzeje | bierz najświeższą ścieżkę (zapytanie w [MANUAL_PL.md](MANUAL_PL.md#19--sprawdzenie-obciążenie-i-porównanie-danych)) |
| baza ggtgt nie wstaje przy starcie: `203/EXEC Permission denied` | SELinux i `dbstart` w katalogu Oracle | jednostka musi uruchamiać `/usr/bin/bash .../dbstart` (tak jest od poprawki, patrz [PITFALLS_26AI_PL.md](PITFALLS_26AI_PL.md)) |
| obciążenie węzła dużo powyżej liczby vCPU, instancja zakończona z ORA-29770 | brak CPU (AHF/TFA, 2 vCPU) | sprawdź `systemctl is-enabled oracle-tfa.service` (disabled), 3 vCPU na węzeł RAC |
| zasób XAG wisi w STOPPING, `crsctl stop crs` nie może odmontować ACFS | procesy GoldenGate wciąż trzymają `/u01/oggdeploy` (widziane raz przy braku CPU) | znajdź je (`lsof +D /u01/oggdeploy` albo `pgrep -af /u01/app/ogg`), zatrzymaj; `crsctl stop crs -f` tylko w ostateczności |
| krok budowy odmawia: `logs\STOP exists` | plik wstrzymania | usuń `logs\STOP` |
| wszystko wolne, zegary skaczą | włączony hypervisor Windows | [ENVIRONMENT_PL.md](ENVIRONMENT_PL.md#hypervisor-windows-wyłączony) |

Więcej pułapek tego wydania: [PITFALLS_26AI_PL.md](PITFALLS_26AI_PL.md).

## 🧪 Po teście awarii

`tests/run_test.ps1` sam uruchamia `lab.cmd baseline` po każdym przebiegu. Po własnych eksperymentach uruchom go ręcznie,
a potem `lab.cmd validate`, jeśli chcesz też porównania danych. Katalog testów: [TESTS_PL.md](../TESTS_PL.md).
