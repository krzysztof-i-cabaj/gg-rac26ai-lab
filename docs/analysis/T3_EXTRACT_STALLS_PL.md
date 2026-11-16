# 🔍 Analiza: przestoje Extractu w T3 (wyłączenie ggrac2)

🇬🇧 [English](T3_EXTRACT_STALLS.md) | 🇵🇱 Polski

[![Status](https://img.shields.io/badge/Analiza-częściowo_wyjaśnione-yellow)]()
[![Oracle](https://img.shields.io/badge/Oracle-26ai_23.26-red)]()
[![GG](https://img.shields.io/badge/GoldenGate-23.26-blue)]()

> 🎯 Skąd liniowy narost laga (1 s na sekundę) w T3 nr 3 (do ok. 126 s) i w T3 nr 1 (nawrót ok. 343 s po awarii).
> Źródło: `GGADMIN.GG_HEARTBEAT_HISTORY` na celu (TGTPDB) zestawione z alert logiem ggcdb1, `ggserr.log`, `crsd.trc`
> i ASH. Pomiar 16.11.2026; wyniki w [RESULTS_PL.md](../RESULTS_PL.md#t3--wyłączenie-drugiego-węzła).

## 📏 Jak czytać miarę laga

Automat testów mierzy `incoming_lag + incoming_heartbeat_age` z `ggadmin.gg_lag`. Heartbeat powstaje na źródle co 5 s.
Gdy któreś ogniwo stoi (job heartbeatu, Extract, ścieżka, Replicat), wiek ostatniego heartbeatu rośnie o 1 s na sekundę
i lag rośnie liniowo. Historia heartbeatów pokazuje, które ogniwo stało (`incoming_heartbeat_ts` → `incoming_extract_ts`
→ `incoming_routing_ts` → `incoming_replicat_ts`).

## ⏱️ T3 nr 3 (`T3-20261116-162545`)

| Okno (sekundy od awarii) | Co stało | Dowód |
|---|---|---|
| 0 → 32 | **źródło nie tworzy heartbeatów**: zamrożenie klastra do wykluczenia ggrac2 i odzyskania wątku 2 | brak wierszy heartbeatu; job `j000` na ggcdb1: `ORA-04021 ... GG_UPDATE_HEARTBEATS`; alert log: rekonfiguracja, potem instance recovery zakończone ok. 32 s, `Redo thread 2 internally disabled at seq 33` |
| 32 → 65 | Extract: pierwszy heartbeat po awarii przechwycony 33 s po powstaniu | heartbeat utworzony po 31,9 s, przechwycony przez Extract po 65,5 s |
| 65 → 125 (ok. 60 s) | **Extract nic nie wydaje**; heartbeaty powstają normalnie co 5 s | heartbeaty utworzone mniej więcej od 34 do 94 s mają ten sam czas Extractu (ok. 125 s) |
| od ok. 126 s | normalnie (opóźnienie Extractu ok. 2–3 s) | |

Przez te 60 s baza jest bezczynna (ASH: pojedyncze próbki LGWR/CJQ0, brak aktywnych sesji GoldenGate, czyli czekają
w oczekiwaniach idle). `ggserr.log` i raport Extractu w tym oknie milczą. `EXT1` ma stan RUNNING.

## 🔁 Porównanie przebiegów T3 (największe opóźnienie Extractu, heartbeat → Extract)

| Przebieg | Największe opóźnienie | Uwagi |
|---|---|---|
| nr 1 (`160222`) | 7,3 s w oknie awarii; **21 s** ok. 321–343 s po awarii | to jest nawrót do laga 34 s; w logach bazy, GoldenGate i CRS brak wpisów z tej chwili |
| nr 2 (`161451`) | 33,8 s | |
| nr 3 (`162545`) | **90,9 s** | 33 s plus ok. 60 s przestoju opisanego wyżej |

## 🧭 Wnioski

1. Pierwsze ok. 32 s laga w każdym T3 to czas zamrożenia klastra: źródło w ogóle nie zatwierdza heartbeatów. To
   zachowanie RAC, nie GoldenGate, i jest powtarzalne (wykluczenie węzła ok. 31 s).
2. Dalsze przestoje są po stronie Extractu (integrated capture / LogMiner): ok. 60 s w nr 3 i ok. 21 s w nr 1 kilka
   minut po awarii, przy bezczynnej bazie i bez wpisów w logach. **Przyczyna nieustalona.** Hipoteza (niesprawdzona):
   LogMiner po wyłączeniu wątku 2 okresowo czeka na redo tego wątku, a długość czekania zależy od tego, w którym miejscu
   cyklu przesyłania (60 s, komunikat OGG-02339) zastała go awaria.
3. Spokojny liniowy narost laga z 17 do 34 s w nr 1 to ten sam mechanizm co w punkcie 2: krótki przestój Extractu przy
   działających heartbeatach, a nie przerwa w heartbeatach.

## 🔧 Następne kroki (niewdrożone)

- Żeby przy następnych T3 zebrać więcej danych, automat testów mógłby co 5 s zapisywać `v$goldengate_capture`
  i `v$logmnr_session` (stan, `capture_message_create_time`). To tylko odczyt, bez zmian w labie.
- Przy pokazywaniu T3 rozbijać lag na „baza zamrożona” (heartbeaty nie powstają) i „Extract nadrabia”. Historia
  heartbeatów daje oba odcinki dla każdego przebiegu.
