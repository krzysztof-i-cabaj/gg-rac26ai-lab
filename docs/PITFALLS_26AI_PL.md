# 🪤 Pułapki — Oracle AI Database 26ai i GoldenGate 23.26

🇬🇧 [English](PITFALLS_26AI.md) | 🇵🇱 Polski

[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![GoldenGate](https://img.shields.io/badge/GoldenGate-23.26.4-blueviolet)]()
[![Źródło](https://img.shields.io/badge/Znalezione-przy_budowie_labu-orange)]()
[![Stan](https://img.shields.io/badge/Stan-poprawione_w_skryptach-success)]()

> 🎯 Co się psuło przy budowie tego labu na 26ai i GoldenGate 23.26 i co z tym robią skrypty. Jeśli przenosisz skrypty
> albo procedury z 19c na 26ai, większość tych rzeczy trafi także ciebie. Każdy wiersz: krok, objaw, przyczyna,
> poprawka. Osobna tabela zbiera to, co wynikało z VirtualBoxa i laptopa, a nie z wydania Oracle.

## 🔴 Związane z wydaniem (26ai / GI 23.26 / GoldenGate 23.26)

| Krok | Objaw | Przyczyna | Poprawka w skryptach |
|---|---|---|---|
| prereq | kontrola „Transparent HugePages = never” nie przechodzi | 26ai na UEK 7+ chce THP = `madvise`, ustawia to pakiet preinstall; stara zasada mówiła `never` | kontrole `madvise`, bez własnej usługi `disable-thp` |
| grid, db | kontrola pliku odpowiedzi zatrzymuje krok przed instalatorem | pliki odpowiedzi 26ai mają krótkie klucze (`installOption`, `scanName`, `clusterNodes` …); nazwy `oracle.install.*` z 19c zniknęły | `gridsetup.rsp` i `db_install.rsp` przepisane; każdy klucz porównywany ze wzorcem dostarczonym w wydaniu (`rsp_keys_check` w `guest/lib.sh`) |
| grid | świeżo rozpakowany Grid home uznany za przerwaną instalację | ZIP z obrazem GI 23.26 ma `root.sh` od początku | „przerwana” = home w inventory bez `CRS="true"` i bez znacznika instalacji |
| grid | walidacja: brak `ora.ctssd`, `crsctl check ctss` nie istnieje | GI 23.26 nie ma już CTSS | kontrola „brak CTSS albo Observer”; czas trzyma chrony |
| grid, po restarcie | instancja `ggcdb1` zakończona przez LMHB (ORA-29770, LMD0 nie odpowiada), obciążenie węzła dużo powyżej liczby vCPU | AHF/TFA instalowane razem z GI 23.26 (przeszukiwanie i skany ADR) zagłodziło węzeł z 2 vCPU | faza `ahf` zaraz po `root.sh`: `ahfctl stopahf -all`, `systemctl disable --now oracle-tfa.service` (ma `Restart=always`); węzły RAC dostały 3 vCPU; walidacja sprawdza, że TFA jest wyłączone |
| dbca | ORA-15001, baza nie widzi dysków ASM (instalator GI ostrzegał PRVF-9992) | baza 26ai działa z grupą `asmdba`; dyski miały `asmadmin` | reguła udev `grid:asmdba 0660` |
| services | kontrole serwisów padają, choć serwisy działają | `srvctl status service` w 26ai pisze „running on instances”, a nie „running on instance(s)” | kontrole przyjmują obie formy |
| services | ORA-01722 przy odczycie `streams_pool_size` | `gv$parameter` w 26ai zwraca wartość nieliczbową (`DISABLED`) | `to_number(value default null on conversion error)` |
| ogg | `oggca` odrzuca hasło administratora (INS-85080) | GoldenGate 23.26 wymusza silne hasło: 8–30 znaków, mała i wielka litera, cyfra i jeden z `- ! @ % & * . # _` | osobne hasło administratora GoldenGate = hasło labu plus brakujące klasy znaków (`ogg_admin_pass`) |
| ogg | `registerServiceManager.sh` nie działa | uruchamia ponownie `oggca.sh` z tym samym plikiem odpowiedzi (checkpoint) | plik odpowiedzi zostaje do końca kroku |
| ogg | wartości `INSTALL_OPTION` nie ma w dokumentacji online | strona dokumentacji wciąż podaje starsze wartości; dostarczony wzorzec ma `ORA23ai` | porównanie z dostarczonym wzorcem; niezgodność to tylko ostrzeżenie |
| xag | skrypt „widzi” zasób, którego nie ma | `crsctl status resource <brak>` zwraca 0 (CRS-2613), a `agctl config goldengate <brak>` zwraca 0 (XAG-212) | istnienie = wiersz `NAME=` i brak XAG-212 w tekście |
| xag | `--service_manager` zapisywane na dwa sposoby | szablon XAG pokazuje samą flagę, tekst MAA `--service_manager yes` | skrypt próbuje samej flagi, a `yes` tylko po błędzie składni |
| oggconf | `adminclient` kończy się kodem 2 | adminclient 23.26 zwraca 2 po każdym nieudanym poleceniu, np. usunięciu aliasu, którego jeszcze nie ma | usuwanie aliasów w osobnej sesji; wynik sprawdza `validate`, a nie kod wyjścia |
| oggconf | ORA-03405 „End of query reached; no additional text should follow” | serwer 26ai odrzuca komentarz `-- ...` po średniku w tej samej linii (nawyk z 19c) | komentarze w osobnych liniach; test statyczny zabrania tego wzorca |
| oggconf | `REGISTER EXTRACT` pada dla PDB z myślnikiem w nazwie | OGG-08221 / ORA-44004 | kontrola konfiguracji: nazwy PDB bez myślnika |
| tgt, po restarcie | baza celu nie wstaje przy starcie systemu: `203/EXEC Permission denied` na `dbstart` | SELinux w trybie Enforcing, katalog Oracle ma etykietę `default_t`, systemd nie może z niego uruchamiać plików | `ExecStart=/usr/bin/bash $ORACLE_HOME/bin/dbstart …` (bash czyta skrypt); walidacja sprawdza, że jednostka jest aktywna |

## 🟠 Zachowanie klastra, którego trzeba się spodziewać (to nie błędy)

| Sytuacja | Co się dzieje | Jak radzi sobie lab |
|---|---|---|
| pełny restart klastra | instancje startują same; serwisy startują na tej instancji, która była pierwsza (może to być *zapasowa*); ACFS z `AUTO_START=restore` jest zamontowany na obu węzłach | `lab.cmd baseline` przenosi serwisy i GoldenGate z powrotem i odmontowuje ACFS na drugim węźle |
| ręczny `srvctl start instance` zaraz po starcie klastra | PRCZ-4054: CRS uruchamia ją w tej samej chwili | `baseline` czeka do 300 s na autostart CRS; PRCZ-4054 liczy się jako uruchomiona |
| GoldenGate po starcie klastra | kontrola stanu XAG trwała dłużej niż limit skryptu 60 s na zajętym węźle; CRS sprzątnął zasób, choć GoldenGate wstał | `baseline` czeka 120 s, potem do trzech prób `agctl start` |
| `crsctl stop cluster -all` z jednego węzła | ten węzeł staje pierwszy, a CRS przenosi GoldenGate, VIP i ACFS na drugi węzeł, zanim i on stanie | uporządkowane wyłączenie: najpierw `agctl stop goldengate`, potem bazy, potem `crsctl stop crs` węzeł po węźle; robi to `lab.cmd shutdown` ([OPERATIONS_PL.md](OPERATIONS_PL.md#-uporządkowane-wyłączenie-zalecane)) |
| powtarzane awarie instancji | `ora.ggcdb.db` restartuje instancję najwyżej dwa razy na godzinę (`RESTART_ATTEMPTS=2`, `UPTIME_THRESHOLD=1h`, wartości domyślne); po trzeciej awarii instancja zostaje wyłączona | opisane w wynikach testów; ręczny `srvctl start instance` zeruje licznik |
| lag heartbeat po przeniesieniu | `ggadmin.gg_lag` trzyma wiersz na każdą ścieżkę; ścieżka ze starego węzła tylko się starzeje, więc `max()` rośnie bez końca | lag = lag + wiek **najświeższej** ścieżki (`probe.sh`, `tgt/90_validate.sh`) |
| ACFS po przeniesieniu | stary węzeł może nadal pokazywać system plików jako ONLINE | w sondzie wygrywa wpis z węzła, na którym jest VIP |

## 🟡 Nie od 26ai: VirtualBox, laptop, instalacja labu

| Objaw | Przyczyna | Poprawka |
|---|---|---|
| wszystko kilka razy wolniej, zegary maszyn skaczą, `VBox.log`: `fall back to NEM` | włączony hypervisor Windows (Hyper-V / VBS, Integralność pamięci) | lab działa z wyłączonym hypervisorem ([ENVIRONMENT_PL.md](ENVIRONMENT_PL.md#hypervisor-windows-wyłączony)) |
| `VBox.log`: `Giving up catch-up attempt at a 60 s lag`; limity czasu kończą się za wcześnie | chrony przestawia zegar maszyny, gdy VirtualBox przestaje go doganiać | `makestep 1.0 -1` w chrony; limity czasu w skryptach liczone z `/proc/uptime`, nie z zegara |
| instalator systemu na gginfra stał na „Checking storage configuration” | 1 GB RAM to za mało | gginfra ma 2 GB |
| `VBoxManage` pada z blokadą sesji | maszynę trzyma jeszcze inne wywołanie VBoxManage | ponowienia w `Invoke-VBox` |
| kontrola `chronyc sources` nigdy nie pasowała | `chronyc` wypisywał nazwę zamiast adresu | `chronyc -n` |
| blokada jądra w `%post` padała | brak działającego DNS w czasie kickstartu (gginfra jeszcze nieskonfigurowany) | `dnf versionlock` z `--disablerepo='*'` |
| ruch interconnectu zablokowany | strefy `firewalld` | bez zapory wewnątrz maszyn (sieć labu host-only) |
| listener na ggtgt trzymał blokadę kroku, następny krok czekał | demon uruchomiony przez krok dziedziczył `flock` | `flock -o` w `run_step.sh` |
| zerwana sesja SSH zabijała `dbca` | `SIGPIPE` przez `tee` | kroki działają odłączone (`setsid`, wyjście do pliku) |
| serwer kickstartów odpowiadał, ale maszyny się nie instalowały | reguła zapory innego labu na porcie 8000 nie wpuszczała tej podsieci | reguła musi wpuszczać 192.168.58.0/24 |
| `python.exe` znaleziony, ale serwer kickstartów nie startował | atrapa ze Sklepu Microsoft | szukany jest prawdziwy Python 3.8+ |

## 📚 Gdzie Oracle to opisuje

- Pliki odpowiedzi i instalacja cicha: *Oracle Grid Infrastructure Installation and Upgrade Guide for Linux* i *Oracle
  Database Installation Guide for Linux* (26ai); wzorce w `<home>/install/response/` są najpewniejszym źródłem.
- Transparent HugePages na UEK: te same przewodniki instalacji, rozdział o konfiguracji systemu.
- ACFS i jądra: dokument My Oracle Support KB129209 (które jądra obsługuje ACFS).
- Polityka haseł GoldenGate i pliki odpowiedzi `oggca`: *Oracle GoldenGate Microservices Documentation* (Deploy).
- XAG i GoldenGate na RAC: Oracle MAA, *Oracle GoldenGate Microservices Architecture on Oracle RAC*.
