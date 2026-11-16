-- ==============================================================================
-- Tytul:        05_demo_schema.sql
-- Opis:         Schematy demo w PDB (zrodlo i cel, ta sama struktura i te same wiersze startowe,
--               bo labu nie zaczyna initial load): HR (departments, employees), SALES (customers,
--               orders, load_events dla generatora obciazenia, types26 z typami 26ai: VECTOR,
--               BOOLEAN, JSON), sekwencja load_seq. Konta bez hasla (NO AUTHENTICATION). Kazda
--               tabela ma klucz glowny. Powtarzalny (IF NOT EXISTS, wiersze tylko gdy brak).
-- Description [EN]: Demo schemas in a PDB (source and target get the same structure and seed
--               rows: the lab has no initial load): HR (departments, employees), SALES (customers,
--               orders, load_events for the load generator, types26 with 26ai types VECTOR,
--               BOOLEAN, JSON), sequence load_seq. Schema-only accounts (NO AUTHENTICATION).
--               Every table has a primary key. Re-runnable (IF NOT EXISTS, seed rows only once).
--
-- Autor:        KCB Kris
-- Data:         2026-11-15
-- Wersja:       1.1
-- Konwencje:    <repo>/SETTINGS.md
--
-- Wymagania [PL]:    - Oracle 23.26 (IF NOT EXISTS, VECTOR, BOOLEAN, JSON), SYSDBA, PDB otwarty
-- Requirements [EN]: - Oracle 23.26 (IF NOT EXISTS, VECTOR, BOOLEAN, JSON), SYSDBA, PDB open
--
-- Uzycie [PL]:       sqlplus / as sysdba @05_demo_schema.sql <PDB>   (SRCPDB na ggrac1, TGTPDB na ggtgt)
-- Usage [EN]:        sqlplus / as sysdba @05_demo_schema.sql <PDB>
-- ==============================================================================
WHENEVER SQLERROR EXIT FAILURE
SET LINESIZE 200 PAGESIZE 50 VERIFY OFF FEEDBACK OFF
COLUMN wlasciciel   FORMAT A8  HEADING "schemat|owner"
COLUMN nazwa_tabeli FORMAT A16 HEADING "tabela|table"
COLUMN liczba_wierszy FORMAT 999999 HEADING "wiersze|rows"

ALTER SESSION SET CONTAINER = &1;

PROMPT == KROK 1: stan wyjsciowy / baseline
SELECT owner AS wlasciciel, table_name AS nazwa_tabeli FROM dba_tables WHERE owner IN ('HR', 'SALES') ORDER BY 1, 2;

PROMPT == KROK 2: schematy, tabele, wiersze startowe / schemas, tables, seed rows
CREATE USER IF NOT EXISTS hr NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
CREATE USER IF NOT EXISTS sales NO AUTHENTICATION DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;

CREATE TABLE IF NOT EXISTS hr.departments (
    department_id NUMBER       CONSTRAINT departments_pk PRIMARY KEY,
    name          VARCHAR2(40) NOT NULL
);
CREATE TABLE IF NOT EXISTS hr.employees (
    employee_id   NUMBER       CONSTRAINT employees_pk PRIMARY KEY,
    department_id NUMBER       NOT NULL CONSTRAINT employees_dept_fk REFERENCES hr.departments,
    last_name     VARCHAR2(40) NOT NULL,
    salary        NUMBER(10,2),
    hired         DATE
);
CREATE TABLE IF NOT EXISTS sales.customers (
    customer_id   NUMBER       CONSTRAINT customers_pk PRIMARY KEY,
    name          VARCHAR2(60) NOT NULL,
    country       VARCHAR2(2)
);
CREATE TABLE IF NOT EXISTS sales.orders (
    order_id      NUMBER       CONSTRAINT orders_pk PRIMARY KEY,
    customer_id   NUMBER       NOT NULL,
    amount        NUMBER(12,2),
    created_at    TIMESTAMP(6)
);
-- Load generator rows: SEQ from the sequence, INST = instance that committed, TS = commit time.
-- Tests read MAX(seq) per INST on both sides to count lost or late rows.
CREATE TABLE IF NOT EXISTS sales.load_events (
    seq           NUMBER       CONSTRAINT load_events_pk PRIMARY KEY,
    inst          NUMBER       NOT NULL,
    svc           VARCHAR2(64),
    ts            TIMESTAMP(6) NOT NULL
);
-- 26ai data types through the Extract and the Replicat (test T10)
CREATE TABLE IF NOT EXISTS sales.types26 (
    id            NUMBER       CONSTRAINT types26_pk PRIMARY KEY,
    v VECTOR(3, FLOAT32),
    b BOOLEAN,
    j JSON
);
-- NOORDER CACHE: RAC instances take their own ranges, no cross-instance wait per row
CREATE SEQUENCE IF NOT EXISTS sales.load_seq START WITH 1 CACHE 1000 NOORDER;

INSERT INTO hr.departments (department_id, name)
SELECT d.id, d.name
FROM   (SELECT 10 AS id, 'Administration' AS name FROM dual UNION ALL
        SELECT 20, 'Sales' FROM dual UNION ALL
        SELECT 30, 'Operations' FROM dual UNION ALL
        SELECT 40, 'IT' FROM dual) d
WHERE  NOT EXISTS (SELECT 1 FROM hr.departments);

INSERT INTO hr.employees (employee_id, department_id, last_name, salary, hired)
SELECT 100 + LEVEL, 10 * (MOD(LEVEL, 4) + 1), 'Employee_' || LEVEL, 4000 + 100 * LEVEL, DATE '2026-01-01' + LEVEL
FROM   dual
WHERE  NOT EXISTS (SELECT 1 FROM hr.employees)
CONNECT BY LEVEL <= 20;

INSERT INTO sales.customers (customer_id, name, country)
SELECT LEVEL, 'Customer_' || LEVEL, CASE MOD(LEVEL, 3) WHEN 0 THEN 'PL' WHEN 1 THEN 'DE' ELSE 'US' END
FROM   dual
WHERE  NOT EXISTS (SELECT 1 FROM sales.customers)
CONNECT BY LEVEL <= 10;

INSERT INTO sales.orders (order_id, customer_id, amount, created_at)
SELECT LEVEL, MOD(LEVEL, 10) + 1, 10 * LEVEL, TIMESTAMP '2026-11-01 08:00:00' + NUMTODSINTERVAL(LEVEL, 'MINUTE')
FROM   dual
WHERE  NOT EXISTS (SELECT 1 FROM sales.orders)
CONNECT BY LEVEL <= 50;

INSERT INTO sales.types26 (id, v, b, j)
SELECT t.id, TO_VECTOR(t.v, 3, FLOAT32), t.b, JSON(t.j)
FROM   (SELECT 1 AS id, '[1,0,0]' AS v, TRUE AS b, '{"tag":"seed","n":1}' AS j FROM dual UNION ALL
        SELECT 2, '[0,1,0]', FALSE, '{"tag":"seed","n":2}' FROM dual UNION ALL
        SELECT 3, '[0,0,1]', TRUE, '{"tag":"seed","n":3}' FROM dual) t
WHERE  NOT EXISTS (SELECT 1 FROM sales.types26);
COMMIT;

PROMPT == KROK 3: weryfikacja / verification
SELECT 'HR' AS wlasciciel, 'DEPARTMENTS' AS nazwa_tabeli, COUNT(*) AS liczba_wierszy FROM hr.departments
UNION ALL SELECT 'HR', 'EMPLOYEES', COUNT(*) FROM hr.employees
UNION ALL SELECT 'SALES', 'CUSTOMERS', COUNT(*) FROM sales.customers
UNION ALL SELECT 'SALES', 'ORDERS', COUNT(*) FROM sales.orders
UNION ALL SELECT 'SALES', 'LOAD_EVENTS', COUNT(*) FROM sales.load_events
UNION ALL SELECT 'SALES', 'TYPES26', COUNT(*) FROM sales.types26;
EXIT
