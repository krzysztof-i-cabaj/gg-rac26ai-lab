#!/bin/bash
# ==============================================================================
# Tytul:        t10_ddl_steps.sh
# Opis:         Kroki testu T10 (DDL i typy 26ai) wywolywane pojedynczo przez automat testow:
#               na zrodle (wezel RAC z otwarta instancja, PDB SRCPDB) wstawienie wierszy z VECTOR,
#               BOOLEAN i JSON, ALTER TABLE ADD, sprzatanie z DROP COLUMN; na celu (ggtgt, TGTPDB)
#               sprawdzenie, czy zmiana juz doszla, i odczyt wiersza do porownania.
#               Kazde polecenie SQL w osobnej linii (26ai: ORA-03405 dla "stmt; stmt;").
#               Wynik jedna linia "T10 <akcja> <wartosc>"; blad: "T10 <akcja> error <opis>", rc 1.
# Description [EN]: Steps of test T10 (DDL and 26ai types) called one at a time by the test
#               automation: on the source (RAC node with an open instance, PDB SRCPDB) insert rows
#               with VECTOR, BOOLEAN and JSON, ALTER TABLE ADD, clean-up with DROP COLUMN; on the
#               target (ggtgt, TGTPDB) check whether the change has arrived and read a row to compare.
#               Every SQL statement on its own line (26ai: ORA-03405 for "stmt; stmt;").
#               Output one line "T10 <action> <value>"; error: "T10 <action> error <detail>", rc 1.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - 05_demo_schema.sql w PDB (SALES.TYPES26), DDL INCLUDE MAPPED w EXT1; root, sysdba lokalnie
# Requirements [EN]: - 05_demo_schema.sql in the PDB (SALES.TYPES26), DDL INCLUDE MAPPED in EXT1; root, local sysdba
#
# Uzycie [PL]:       bash /root/lab/shared/t10_ddl_steps.sh src ping|insert101|row101|ddl_add|insert102|row102|cleanup
#                    bash /root/lab/shared/t10_ddl_steps.sh tgt ping|has_row101|row101|has_note|has_row102|row102|no_note|no_rows
#                    DRY_RUN=1 ... tylko wypisuje SQL
# Usage [EN]:        bash /root/lab/shared/t10_ddl_steps.sh src|tgt <action>   (tests/run_test.ps1 -Test T10)
#                    DRY_RUN=1 ... only prints the SQL
# ==============================================================================
source /root/lab/lib.sh

side=${1:-}; act=${2:-}
# One row as text: id, vector, boolean, JSON (and note when asked); the same expression on both sides
ROW="select id || ' ' || from_vector(v) || ' ' || case when b then 'TRUE' else 'FALSE' end || ' ' || json_serialize(j)"

# t10_sql <side> <action> : the SQL of one action, one statement per line ("" = unknown action)
t10_sql() {
    case "$1:$2" in
        src:ping|tgt:ping) echo "select open_mode from v\$pdbs where name = sys_context('userenv', 'con_name');" ;;
        src:insert101)
            echo "insert into sales.types26 (id, v, b, j) values (101, to_vector('[1.5,2.5,3.5]', 3, FLOAT32), TRUE, json('{\"t\":\"T10\",\"n\":101}'));"
            echo "commit;" ;;
        src:row101|tgt:row101) echo "$ROW from sales.types26 where id = 101;" ;;
        src:ddl_add) echo "alter table sales.types26 add (note varchar2(30));" ;;
        src:insert102)
            echo "insert into sales.types26 (id, v, b, j, note) values (102, to_vector('[-1,0.25,4]', 3, FLOAT32), FALSE, json('{\"t\":\"T10\",\"n\":102,\"after\":\"ddl\"}'), 'after DDL');"
            echo "commit;" ;;
        src:row102|tgt:row102) echo "$ROW || ' ' || note from sales.types26 where id = 102;" ;;
        src:cleanup)
            echo "delete from sales.types26 where id in (101, 102);"
            echo "commit;"
            echo "alter table sales.types26 drop column note;" ;;
        tgt:has_row101) echo "select count(*) from sales.types26 where id = 101;" ;;
        tgt:has_note) echo "select count(*) from all_tab_columns where owner = 'SALES' and table_name = 'TYPES26' and column_name = 'NOTE';" ;;
        tgt:has_row102) echo "select count(*) from sales.types26 where id = 102;" ;;
        tgt:no_note) echo "select case when count(*) = 0 then 1 else 0 end from all_tab_columns where owner = 'SALES' and table_name = 'TYPES26' and column_name = 'NOTE';" ;;
        tgt:no_rows) echo "select case when count(*) = 0 then 1 else 0 end from sales.types26 where id in (101, 102);" ;;
        *) echo "" ;;
    esac
}

# t10_value <action> <sqlplus output> : the one value of the result line (DML / DDL print nothing: "done")
t10_value() {
    local v
    v=$(printf '%s\n' "$2" | sed -e '/^[[:space:]]*$/d' | tr '\n' ' ' | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')
    case "$1" in
        insert101|insert102|ddl_add|cleanup) echo "${v:-done}" ;;
        *) echo "${v:-none}" ;;
    esac
}

main() {
    local pdb sql out
    case "$side" in
        src) pdb=$SRC_PDB ;;
        tgt) pdb=$TGT_PDB ;;
        *) echo "T10 ${act:-?} error usage: t10_ddl_steps.sh src|tgt <action>"; exit 1 ;;
    esac
    sql=$(t10_sql "$side" "$act")
    [ -n "$sql" ] || { echo "T10 ${act:-?} error unknown action for $side"; exit 1; }
    if [ "$DRY_RUN" = "1" ]; then
        printf '%s\n' "$sql" | sed "s/^/  DRY  [oracle] $pdb: /"
        echo "T10 $act dry"; exit 0
    fi
    # whenever sqlerror exit 1 (sysdba_query): an ORA- error gives rc != 0 and its text
    if ! out=$(sysdba_query "alter session set container = $pdb;
$sql" 2>&1); then
        echo "T10 $act error $(printf '%s' "$out" | grep -m1 -E 'ORA-|SP2-' || printf '%s' "$out" | head -c 200)"; exit 1
    fi
    echo "T10 $act $(t10_value "$act" "$out")"
}

[ "${T10_NO_MAIN:-0}" = "1" ] || main
