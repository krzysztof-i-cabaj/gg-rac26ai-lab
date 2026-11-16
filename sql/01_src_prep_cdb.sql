-- ==============================================================================
-- Tytul:        01_src_prep_cdb.sql
-- Opis:         Przygotowanie CDB zrodlowej (RAC) pod GoldenGate wg bloku 1 raportu: parametr
--               enable_goldengate_replication i streams_pool_size na wszystkich instancjach
--               (SID='*'), FORCE LOGGING, minimalne supplemental logging (wariant A), przelaczenie
--               logow wszystkich watkow, otwarcie PDB na wszystkich instancjach. Powtarzalny.
-- Description [EN]: Prepares the source RAC CDB for GoldenGate (report block 1): parameters
--               enable_goldengate_replication and streams_pool_size on all instances (SID='*'),
--               FORCE LOGGING, minimal supplemental logging (variant A), log switch on all
--               threads, PDB open on all instances. Re-runnable.
--
-- Autor:        KCB Kris
-- Data:         2026-11-15
-- Wersja:       1.1
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - CDB$ROOT, SYSDBA; baza w ARCHIVELOG (dbca -enableArchive true)
-- Requirements [EN]: - CDB$ROOT, SYSDBA; database in ARCHIVELOG (dbca -enableArchive true)
--
-- Uzycie [PL]:       sqlplus / as sysdba @01_src_prep_cdb.sql <streams_pool_MB> <PDB>
--                    (automatycznie: lab.cmd dbca -> 60_create_db.sh: 1280 SRCPDB)
-- Usage [EN]:        sqlplus / as sysdba @01_src_prep_cdb.sql <streams_pool_MB> <PDB>
-- ==============================================================================
WHENEVER SQLERROR EXIT FAILURE
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200 PAGESIZE 50 VERIFY OFF FEEDBACK OFF
COLUMN log_mode            FORMAT A12 HEADING "tryb_logow|log_mode"
COLUMN force_logging       FORMAT A8  HEADING "force|logging"
COLUMN supplemental_min    FORMAT A8  HEADING "suppl|min"
COLUMN inst_id             FORMAT 99  HEADING "inst"
COLUMN nazwa_parametru     FORMAT A32 HEADING "parametr|parameter"
COLUMN wartosc             FORMAT A20 HEADING "wartosc|value"

PROMPT == KROK 1: stan wyjsciowy / baseline
SELECT log_mode, force_logging, supplemental_log_data_min AS supplemental_min FROM v$database;
SELECT thread#, status, enabled FROM v$thread ORDER BY thread#;
SELECT inst_id, name AS nazwa_parametru, value AS wartosc
FROM   gv$parameter
WHERE  name IN ('enable_goldengate_replication', 'streams_pool_size')
ORDER  BY name, inst_id;

PROMPT == KROK 2: zmiany (tylko brakujace) / changes (only what is missing)
DECLARE
    v_log_mode VARCHAR2(12);
    v_force    VARCHAR2(8);
    v_suppl    VARCHAR2(8);
BEGIN
    SELECT log_mode, force_logging, supplemental_log_data_min INTO v_log_mode, v_force, v_suppl FROM v$database;
    IF v_log_mode <> 'ARCHIVELOG' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Database is in ' || v_log_mode || ': dbca must run with -enableArchive true');
    END IF;
    -- GG parameter only in CDB$ROOT, the same on all instances
    EXECUTE IMMEDIATE 'ALTER SYSTEM SET enable_goldengate_replication=TRUE SCOPE=BOTH SID=''*''';
    -- LogMiner pool for the Extract: MAA formula (1 Extract x 1 GB) x 1.25
    EXECUTE IMMEDIATE 'ALTER SYSTEM SET streams_pool_size=' || &1 || 'M SCOPE=BOTH SID=''*''';
    DBMS_OUTPUT.PUT_LINE('  enable_goldengate_replication=TRUE, streams_pool_size=&1.M (SID=*)');
    IF v_force <> 'YES' THEN
        EXECUTE IMMEDIATE 'ALTER DATABASE FORCE LOGGING';
        DBMS_OUTPUT.PUT_LINE('  FORCE LOGGING on');
    END IF;
    -- Variant A (documented minimum). Variant B (LAB to confirm, two forms in the docs):
    -- ALTER PLUGGABLE DATABASE <PDB> ADD SUPPLEMENTAL LOG DATA SUBSET DATABASE REPLICATION
    IF v_suppl <> 'YES' THEN
        EXECUTE IMMEDIATE 'ALTER DATABASE ADD SUPPLEMENTAL LOG DATA';
        DBMS_OUTPUT.PUT_LINE('  minimal supplemental logging on');
    END IF;
END;
/
-- Switches the current log of every thread (all RAC instances)
ALTER SYSTEM ARCHIVE LOG CURRENT;
BEGIN
    EXECUTE IMMEDIATE 'ALTER PLUGGABLE DATABASE &2 OPEN INSTANCES=ALL';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE <> -65019 THEN RAISE; END IF;   -- ORA-65019: already open
END;
/

PROMPT == KROK 3: weryfikacja / verification
SELECT log_mode, force_logging, supplemental_log_data_min AS supplemental_min FROM v$database;
SELECT inst_id, name AS nazwa_parametru, value AS wartosc
FROM   gv$parameter
WHERE  name IN ('enable_goldengate_replication', 'streams_pool_size')
ORDER  BY name, inst_id;
SELECT inst_id, name, open_mode FROM gv$pdbs WHERE name = UPPER('&2') ORDER BY inst_id;
EXIT
