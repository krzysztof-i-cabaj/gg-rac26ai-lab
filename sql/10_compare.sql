-- ==============================================================================
-- Tytul:        10_compare.sql
-- Opis:         Odcisk danych replikowanych tabel do porownania zrodla z celem: dla kazdej tabeli HR
--               i SALES wiersz "COMPARE <tabela> <liczba_wierszy> <suma ORA_HASH>". Kolumny typow 26ai
--               (VECTOR, BOOLEAN, JSON) serializowane do tekstu przed haszem. Tylko odczyt.
-- Description [EN]: Fingerprint of the replicated tables to compare source and target: for each HR
--               and SALES table one line "COMPARE <table> <row count> <sum of ORA_HASH>". 26ai type
--               columns (VECTOR, BOOLEAN, JSON) are serialized to text before hashing. Read-only.
--
-- Autor:        KCB Kris
-- Data:         2026-11-15
-- Wersja:       1.1
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - SYSDBA; 05_demo_schema.sql w PDB
-- Requirements [EN]: - SYSDBA; 05_demo_schema.sql in the PDB
--
-- Uzycie [PL]:       sqlplus -S / as sysdba @10_compare.sql <PDB>   (shared/compare.sh, lab.cmd validate)
-- Usage [EN]:        sqlplus -S / as sysdba @10_compare.sql <PDB>
-- ==============================================================================
WHENEVER SQLERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON TRIMOUT ON

ALTER SESSION SET CONTAINER = &1;

SELECT 'COMPARE HR.DEPARTMENTS ' || COUNT(*) || ' ' || NVL(SUM(ORA_HASH(department_id || '|' || name)), 0)
FROM   hr.departments;
SELECT 'COMPARE HR.EMPLOYEES ' || COUNT(*) || ' ' ||
       NVL(SUM(ORA_HASH(employee_id || '|' || department_id || '|' || last_name || '|' || salary || '|' || TO_CHAR(hired, 'YYYYMMDD'))), 0)
FROM   hr.employees;
SELECT 'COMPARE SALES.CUSTOMERS ' || COUNT(*) || ' ' || NVL(SUM(ORA_HASH(customer_id || '|' || name || '|' || country)), 0)
FROM   sales.customers;
SELECT 'COMPARE SALES.ORDERS ' || COUNT(*) || ' ' ||
       NVL(SUM(ORA_HASH(order_id || '|' || customer_id || '|' || amount || '|' || TO_CHAR(created_at, 'YYYYMMDDHH24MISSFF6'))), 0)
FROM   sales.orders;
SELECT 'COMPARE SALES.LOAD_EVENTS ' || COUNT(*) || ' ' ||
       NVL(SUM(ORA_HASH(seq || '|' || inst || '|' || svc || '|' || TO_CHAR(ts, 'YYYYMMDDHH24MISSFF6'))), 0)
FROM   sales.load_events;
SELECT 'COMPARE SALES.TYPES26 ' || COUNT(*) || ' ' ||
       NVL(SUM(ORA_HASH(id || '|' || VECTOR_SERIALIZE(v) || '|' || CASE WHEN b THEN 'T' WHEN NOT b THEN 'F' END
                        || '|' || JSON_SERIALIZE(j))), 0)
FROM   sales.types26;
EXIT
