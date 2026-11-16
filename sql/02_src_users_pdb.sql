-- ==============================================================================
-- Tytul:        02_src_users_pdb.sql
-- Opis:         Lokalny uzytkownik GoldenGate w PDB zrodlowym wg bloku 2 raportu: ggadmin z rola
--               OGG_CAPTURE (per-PDB Extract), CONNECT, RESOURCE, CREATE VIEW i CREATE PROCEDURE
--               (tabela heartbeat), CREATE JOB (zadanie heartbeat). Bez wspolnego uzytkownika CDB i bez roli DBA.
--               Haslo @@LAB_PASS@@ wstawia render_secret na VM (kopia 600, potem usuwana).
-- Description [EN]: Local GoldenGate user in the source PDB (report block 2): ggadmin with role
--               OGG_CAPTURE (per-PDB Extract), CONNECT, RESOURCE, CREATE VIEW and CREATE PROCEDURE
--               (heartbeat table), CREATE JOB (heartbeat job). No common CDB user, no DBA role. The
--               password placeholder is filled on the VM by render_secret (600 copy, then removed).
--
-- Autor:        KCB Kris
-- Data:         2026-11-16
-- Wersja:       1.2 (komentarze nie po srednikach: ORA-03405 w 26ai)
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - SYSDBA; PDB otwarty; plik wyrenderowany przez 88_oggconf_source.sh
-- Requirements [EN]: - SYSDBA; PDB open; file rendered by 88_oggconf_source.sh
--
-- Uzycie [PL]:       automatycznie: lab.cmd oggconf (parametr: SRCPDB)
-- Usage [EN]:        automatic: lab.cmd oggconf (argument: SRCPDB)
-- ==============================================================================
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF VERIFY OFF FEEDBACK OFF
SET LINESIZE 200 PAGESIZE 50
COLUMN uprawnienie FORMAT A30 HEADING "uprawnienie|privilege"

ALTER SESSION SET CONTAINER = &1;

PROMPT == KROK 1: stan wyjsciowy / baseline
SELECT username, account_status FROM dba_users WHERE username = 'GGADMIN';

PROMPT == KROK 2: uzytkownik i uprawnienia / user and privileges
CREATE USER IF NOT EXISTS ggadmin IDENTIFIED BY "@@LAB_PASS@@"
  DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
-- Same password as the credential store alias ggsource (re-run after a LAB_PASS change)
ALTER USER ggadmin IDENTIFIED BY "@@LAB_PASS@@" ACCOUNT UNLOCK;
GRANT CONNECT, RESOURCE TO ggadmin;
GRANT OGG_CAPTURE TO ggadmin;
-- heartbeat table
GRANT CREATE VIEW, CREATE PROCEDURE TO ggadmin;
-- heartbeat scheduler job; OGG_CAPTURE in 23.26 already holds CREATE JOB (lab 16.11), kept explicit
GRANT CREATE JOB TO ggadmin;

PROMPT == KROK 3: weryfikacja / verification
SELECT granted_role AS uprawnienie FROM dba_role_privs WHERE grantee = 'GGADMIN'
UNION ALL
SELECT privilege FROM dba_sys_privs WHERE grantee = 'GGADMIN'
ORDER BY 1;
-- LAB: what OGG_CAPTURE contains
SELECT privilege AS uprawnienie FROM role_sys_privs WHERE role = 'OGG_CAPTURE' ORDER BY 1;
EXIT
