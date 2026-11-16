-- ==============================================================================
-- Tytul:        04_tgt_users_pdb.sql
-- Opis:         Lokalny uzytkownik GoldenGate w PDB docelowym wg bloku 3 raportu: ggadmin z rolami
--               CONNECT, RESOURCE, OGG_APPLY, DML na kazdej tabeli HR i SALES, CREATE VIEW, CREATE
--               PROCEDURE i CREATE JOB (heartbeat), uprawnienia DDL tylko na potrzeby testu T10.
--               Haslo @@LAB_PASS@@ wstawia render_secret na VM.
-- Description [EN]: Local GoldenGate user in the target PDB (report block 3): ggadmin with CONNECT,
--               RESOURCE, OGG_APPLY, DML on every HR and SALES table, CREATE VIEW, CREATE PROCEDURE
--               and CREATE JOB (heartbeat), DDL privileges only for test T10. The password
--               placeholder is filled on the VM by render_secret.
--
-- Autor:        KCB Kris
-- Data:         2026-11-16
-- Wersja:       1.2 (komentarze nie po srednikach: ORA-03405 w 26ai)
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - SYSDBA na ggtgt; 05_demo_schema.sql w tym PDB; plik wyrenderowany przez 88_oggconf_target.sh
-- Requirements [EN]: - SYSDBA on ggtgt; 05_demo_schema.sql in this PDB; file rendered by 88_oggconf_target.sh
--
-- Uzycie [PL]:       automatycznie: lab.cmd oggconf (parametr: TGTPDB)
-- Usage [EN]:        automatic: lab.cmd oggconf (argument: TGTPDB)
-- ==============================================================================
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF VERIFY OFF FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200 PAGESIZE 50
COLUMN uprawnienie FORMAT A30 HEADING "uprawnienie|privilege"

ALTER SESSION SET CONTAINER = &1;

PROMPT == KROK 1: stan wyjsciowy / baseline
SELECT username, account_status FROM dba_users WHERE username = 'GGADMIN';

PROMPT == KROK 2: uzytkownik i uprawnienia / user and privileges
CREATE USER IF NOT EXISTS ggadmin IDENTIFIED BY "@@LAB_PASS@@"
  DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
ALTER USER ggadmin IDENTIFIED BY "@@LAB_PASS@@" ACCOUNT UNLOCK;
GRANT CONNECT, RESOURCE, OGG_APPLY TO ggadmin;
-- heartbeat on the target side
GRANT CREATE VIEW, CREATE PROCEDURE TO ggadmin;
-- heartbeat scheduler job (LAB: confirm it is needed)
GRANT CREATE JOB TO ggadmin;
-- DDL replication (ext1: DDL INCLUDE MAPPED, test T10): ANY privileges, lab only
GRANT CREATE ANY TABLE, ALTER ANY TABLE, DROP ANY TABLE, CREATE ANY INDEX, DROP ANY INDEX TO ggadmin;
-- DML per table of the replicated schemas (new tables from DDL get it from the DDL privileges)
BEGIN
    FOR t IN (SELECT owner, table_name FROM dba_tables WHERE owner IN ('HR', 'SALES') ORDER BY 1, 2) LOOP
        EXECUTE IMMEDIATE 'GRANT SELECT, INSERT, UPDATE, DELETE ON ' || t.owner || '.' || t.table_name || ' TO ggadmin';
        DBMS_OUTPUT.PUT_LINE('  DML on ' || t.owner || '.' || t.table_name);
    END LOOP;
END;
/

PROMPT == KROK 3: weryfikacja / verification
SELECT granted_role AS uprawnienie FROM dba_role_privs WHERE grantee = 'GGADMIN'
UNION ALL
SELECT privilege FROM dba_sys_privs WHERE grantee = 'GGADMIN'
ORDER BY 1;
SELECT COUNT(*) AS tabele_z_dml FROM dba_tab_privs WHERE grantee = 'GGADMIN' AND privilege = 'INSERT' AND owner IN ('HR', 'SALES');
EXIT
