-- ==============================================================================
-- Tytul:        99_reset_demo.sql
-- Opis:         Czyszczenie danych testowych przed kolejnym testem: usuwa wiersze generatora
--               (SALES.LOAD_EVENTS) i wiersze testu T10 z SALES.TYPES26 (id > 3), zostawia dane
--               startowe z 05_demo_schema.sql. DELETE, nie TRUNCATE: zmiana idzie przez Extract
--               na cel, wiec po resecie zrodlo i cel sa rowne. Podglad -> zmiana -> weryfikacja.
-- Description [EN]: Clears test data before the next test: deletes load generator rows
--               (SALES.LOAD_EVENTS) and test T10 rows from SALES.TYPES26 (id > 3), keeps the seed
--               rows from 05_demo_schema.sql. DELETE, not TRUNCATE: the change replicates, so
--               source and target match after a reset. Preview -> change -> verify.
--
-- Autor:        KCB Kris
-- Data:         2026-11-15
-- Wersja:       1.1
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - SYSDBA; zrodlo z dzialajaca replikacja (bez replikacji: uruchom tez na celu)
-- Requirements [EN]: - SYSDBA; source with replication running (without it: run on the target too)
--
-- Uzycie [PL]:       sqlplus / as sysdba @99_reset_demo.sql SRCPDB
-- Usage [EN]:        sqlplus / as sysdba @99_reset_demo.sql SRCPDB
-- ==============================================================================
WHENEVER SQLERROR EXIT FAILURE
SET LINESIZE 200 PAGESIZE 50 VERIFY OFF FEEDBACK ON
COLUMN nazwa_tabeli   FORMAT A16 HEADING "tabela|table"
COLUMN do_usuniecia   FORMAT 9999999 HEADING "do_usuniecia|to_delete"
COLUMN liczba_wierszy FORMAT 9999999 HEADING "wiersze|rows"

ALTER SESSION SET CONTAINER = &1;

PROMPT == KROK 1: podglad / preview
SELECT 'LOAD_EVENTS' AS nazwa_tabeli, COUNT(*) AS do_usuniecia FROM sales.load_events
UNION ALL SELECT 'TYPES26', COUNT(*) FROM sales.types26 WHERE id > 3;

PROMPT == KROK 2: zmiana / change
DELETE FROM sales.load_events;
DELETE FROM sales.types26 WHERE id > 3;
COMMIT;

PROMPT == KROK 3: weryfikacja / verification
SELECT 'LOAD_EVENTS' AS nazwa_tabeli, COUNT(*) AS liczba_wierszy FROM sales.load_events
UNION ALL SELECT 'TYPES26 (id > 3)', COUNT(*) FROM sales.types26 WHERE id > 3;
EXIT
