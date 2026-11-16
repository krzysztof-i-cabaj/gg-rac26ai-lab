-- ==============================================================================
-- Tytul:        06_loadgen.sql
-- Opis:         Generator obciazenia w PDB zrodlowym: pakiet SALES.LOADGEN, procedura
--               RUN(p_rows_per_sec, p_seconds) wstawia do SALES.LOAD_EVENTS wiersze (SEQ z
--               sekwencji, INST = instancja, SVC = serwis, TS = czas) i zatwierdza kazdy wiersz
--               osobno, zeby testy liczyly straty co do wiersza. Uruchamiany przez serwisy
--               srv_load1 (ggcdb1) i srv_load2 (ggcdb2), jedna sesja na instancje.
-- Description [EN]: Load generator in the source PDB: package SALES.LOADGEN, procedure
--               RUN(p_rows_per_sec, p_seconds) inserts SALES.LOAD_EVENTS rows (SEQ from the
--               sequence, INST = instance, SVC = service, TS = time) and commits each row, so
--               tests count losses per row. Run through srv_load1 (ggcdb1) and srv_load2 (ggcdb2).
--
-- Autor:        KCB Kris
-- Data:         2026-11-15
-- Wersja:       1.1
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - 05_demo_schema.sql w tym PDB; SYSDBA; tylko zrodlo (na celu wiersze daje Replicat)
-- Requirements [EN]: - 05_demo_schema.sql in this PDB; SYSDBA; source only (the Replicat fills the target)
--
-- Uzycie [PL]:       sqlplus / as sysdba @06_loadgen.sql SRCPDB   (lab.cmd services)
--                    potem, przez serwis: EXEC sales.loadgen.run(10, 60)  -- 10 wierszy/s przez 60 s
-- Usage [EN]:        sqlplus / as sysdba @06_loadgen.sql SRCPDB
--                    then, through a service: EXEC sales.loadgen.run(10, 60)
-- ==============================================================================
WHENEVER SQLERROR EXIT FAILURE
SET LINESIZE 200 PAGESIZE 50 VERIFY OFF FEEDBACK OFF
COLUMN nazwa_obiektu FORMAT A20 HEADING "obiekt|object"
COLUMN typ_obiektu   FORMAT A14 HEADING "typ|type"
COLUMN stan          FORMAT A8  HEADING "stan|status"

ALTER SESSION SET CONTAINER = &1;

PROMPT == KROK 1: stan wyjsciowy / baseline
SELECT object_name AS nazwa_obiektu, object_type AS typ_obiektu, status AS stan
FROM   dba_objects WHERE owner = 'SALES' AND object_name = 'LOADGEN' ORDER BY 2;

PROMPT == KROK 2: pakiet / package
CREATE OR REPLACE PACKAGE sales.loadgen AUTHID DEFINER AS
    -- Inserts p_rows_per_sec rows per second for p_seconds; one commit per row.
    PROCEDURE run(p_rows_per_sec IN PLS_INTEGER, p_seconds IN PLS_INTEGER);
END loadgen;
/
CREATE OR REPLACE PACKAGE BODY sales.loadgen AS
    PROCEDURE run(p_rows_per_sec IN PLS_INTEGER, p_seconds IN PLS_INTEGER) IS
        v_end  TIMESTAMP := SYSTIMESTAMP + NUMTODSINTERVAL(p_seconds, 'SECOND');
        v_inst NUMBER    := TO_NUMBER(SYS_CONTEXT('USERENV', 'INSTANCE'));
        v_svc  VARCHAR2(64) := SYS_CONTEXT('USERENV', 'SERVICE_NAME');
        v_gap  NUMBER    := 1 / GREATEST(p_rows_per_sec, 1);
        v_rows PLS_INTEGER := 0;
    BEGIN
        IF p_rows_per_sec < 1 OR p_seconds < 1 THEN
            RAISE_APPLICATION_ERROR(-20010, 'loadgen.run: p_rows_per_sec and p_seconds must be >= 1');
        END IF;
        -- loadgen.sh stop finds the sessions by this module (kill session on every instance)
        DBMS_APPLICATION_INFO.SET_MODULE('LOADGEN', v_svc);
        WHILE SYSTIMESTAMP < v_end LOOP
            INSERT INTO sales.load_events (seq, inst, svc, ts)
            VALUES (sales.load_seq.NEXTVAL, v_inst, v_svc, SYSTIMESTAMP);
            COMMIT;
            v_rows := v_rows + 1;
            DBMS_SESSION.SLEEP(v_gap);
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('loadgen: ' || v_rows || ' rows, instance ' || v_inst || ', service ' || v_svc);
    END run;
END loadgen;
/
SHOW ERRORS PACKAGE BODY sales.loadgen

PROMPT == KROK 3: weryfikacja / verification
SELECT object_name AS nazwa_obiektu, object_type AS typ_obiektu, status AS stan
FROM   dba_objects WHERE owner = 'SALES' AND object_name = 'LOADGEN' ORDER BY 2;
DECLARE
    v_bad PLS_INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_bad FROM dba_objects WHERE owner = 'SALES' AND object_name = 'LOADGEN' AND status <> 'VALID';
    IF v_bad > 0 THEN RAISE_APPLICATION_ERROR(-20011, 'SALES.LOADGEN is INVALID'); END IF;
END;
/
EXIT
