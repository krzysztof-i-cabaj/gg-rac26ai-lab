-- ==============================================================================
-- Tytul:        03_tgt_prep_cdb.sql
-- Opis:         Przygotowanie CDB docelowej (ggtgt) wg bloku 3 raportu, czesc CDB$ROOT:
--               enable_goldengate_replication, FORCE LOGGING (MAA: zrodlo i cel), PDB otwarty
--               i zapamietany stan (start PDB po restarcie instancji). Uzytkownik ggadmin w PDB
--               powstaje w Task 8 (04_tgt_users_pdb.sql). Powtarzalny.
-- Description [EN]: Prepares the target CDB (ggtgt), report block 3, CDB$ROOT part:
--               enable_goldengate_replication, FORCE LOGGING (MAA: source and target), PDB open
--               with saved state (opens after an instance restart). The ggadmin PDB user comes
--               in Task 8 (04_tgt_users_pdb.sql). Re-runnable.
--
-- Autor:        KCB Kris
-- Data:         2026-11-15
-- Wersja:       1.1
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - CDB$ROOT, SYSDBA na ggtgt
-- Requirements [EN]: - CDB$ROOT, SYSDBA on ggtgt
--
-- Uzycie [PL]:       sqlplus / as sysdba @03_tgt_prep_cdb.sql <PDB>   (lab.cmd tgt: TGTPDB)
-- Usage [EN]:        sqlplus / as sysdba @03_tgt_prep_cdb.sql <PDB>
-- ==============================================================================
WHENEVER SQLERROR EXIT FAILURE
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200 PAGESIZE 50 VERIFY OFF FEEDBACK OFF
COLUMN force_logging   FORMAT A8  HEADING "force|logging"
COLUMN nazwa_parametru FORMAT A32 HEADING "parametr|parameter"
COLUMN wartosc         FORMAT A20 HEADING "wartosc|value"
COLUMN nazwa_pdb       FORMAT A12 HEADING "pdb"
COLUMN tryb_otwarcia   FORMAT A12 HEADING "tryb|open_mode"

PROMPT == KROK 1: stan wyjsciowy / baseline
SELECT log_mode, force_logging FROM v$database;
SELECT name AS nazwa_parametru, value AS wartosc FROM v$parameter WHERE name = 'enable_goldengate_replication';

PROMPT == KROK 2: zmiany (tylko brakujace) / changes (only what is missing)
DECLARE
    v_force VARCHAR2(8);
BEGIN
    EXECUTE IMMEDIATE 'ALTER SYSTEM SET enable_goldengate_replication=TRUE SCOPE=BOTH';
    SELECT force_logging INTO v_force FROM v$database;
    IF v_force <> 'YES' THEN
        EXECUTE IMMEDIATE 'ALTER DATABASE FORCE LOGGING';
        DBMS_OUTPUT.PUT_LINE('  FORCE LOGGING on');
    END IF;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'ALTER PLUGGABLE DATABASE &1 OPEN';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE <> -65019 THEN RAISE; END IF;   -- ORA-65019: already open
END;
/
-- Single instance without Grid Infrastructure: the saved state opens the PDB after a restart
ALTER PLUGGABLE DATABASE &1 SAVE STATE;

PROMPT == KROK 3: weryfikacja / verification
SELECT log_mode, force_logging FROM v$database;
SELECT name AS nazwa_parametru, value AS wartosc FROM v$parameter WHERE name = 'enable_goldengate_replication';
SELECT name AS nazwa_pdb, open_mode AS tryb_otwarcia FROM v$pdbs WHERE name = UPPER('&1');
EXIT
