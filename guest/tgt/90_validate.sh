#!/bin/bash
# ==============================================================================
# Tytul:        90_validate.sh
# Opis:         Kontrole ggtgt (tylko odczyt) w sekcjach: db (instancja OPEN, PDB READ WRITE,
#               FORCE LOGGING, parametr GG, listener z serwisem PDB, schemat demo, autostart);
#               ogg (Service Manager jako usluga systemd, REST, Receiver), repl (Replicat RUNNING,
#               tabela checkpoint, lag heartbeat < 30 s). Kazda kontrola: CHECK ok|FAIL.
# Description [EN]: ggtgt checks (read-only) in sections: db (instance OPEN, PDB READ WRITE,
#               FORCE LOGGING, GG parameter, listener with the PDB service, demo schema,
#               autostart), ogg (Service Manager as a systemd service, REST, Receiver), repl (Replicat
#               RUNNING, checkpoint table, heartbeat lag < 30 s). CHECK ok|FAIL.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.4 (lag jak probe.sh: najswiezsza sciezka gg_lag; 1.3: oracle-db.service active)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - po lab.cmd tgt (sekcja db), lab.cmd ogg (sekcja ogg)
# Requirements [EN]: - after lab.cmd tgt (db section), lab.cmd ogg (ogg section)
#
# Uzycie [PL]:       bash 90_validate.sh [db] [ogg] [repl]   (bez argumentu: wszystkie sekcje)
# Usage [EN]:        bash 90_validate.sh [db] [ogg] [repl]   (no argument: all sections)
# ==============================================================================
source /root/lab/lib.sh

sections=${*:-db ogg repl}
q() { sysdba_query "$1"; }

validate_db() {
    echo "== db"
    check_eq "v\$database: $TGT_DB OPEN (v\$instance)"  "OPEN" q "select status from v\$instance;"
    check_eq "$TGT_PDB READ WRITE"                     "READ WRITE" q "select open_mode from v\$pdbs where name = '$TGT_PDB';"
    check_eq "force_logging YES"                       "YES" q "select force_logging from v\$database;"
    check_eq "enable_goldengate_replication TRUE"      "TRUE" q "select upper(value) from v\$parameter where name = 'enable_goldengate_replication';"
    check_eq "$TGT_PDB state saved (opens after restart)" "1" q "select count(*) from dba_pdb_saved_states where con_name = '$TGT_PDB';"
    check "lsnrctl status: service of $TGT_PDB"        sh -c "runuser -l oracle -c 'lsnrctl status' | grep -qi 'Service \"${TGT_PDB}'"
    check_eq "demo tables HR + SALES = 6"              "6" q "alter session set container = $TGT_PDB;
select count(*) from dba_tables where owner in ('HR', 'SALES');"
    check_eq "sales.types26 seed rows = 3"             "3" q "alter session set container = $TGT_PDB;
select count(*) from sales.types26 where id <= 3;"
    check "oratab: $TGT_DB autostart Y"                grep -q "^${TGT_DB}:.*:Y$" /etc/oratab
    check "systemd: oracle-db.service enabled"         systemctl is-enabled --quiet oracle-db.service
    check "systemd: oracle-db.service active"          systemctl is-active --quiet oracle-db.service
}

validate_ogg() {
    echo "== ogg"
    check "systemd: OracleGoldenGate active"        systemctl is-active --quiet OracleGoldenGate.service
    check "systemd: OracleGoldenGate enabled"       systemctl is-enabled --quiet OracleGoldenGate.service
    check "Service Manager answers on $NODE_NAME:$OGG_SM_PORT (HTTP 200/401)" \
        sh -c "curl -s -o /dev/null -m 10 -w '%{http_code}' http://$NODE_NAME.$LAB_DOMAIN:$OGG_SM_PORT/services/v2/deployments | grep -qE '^(200|401)$'"
    check "Receiver Service listens on $OGG_PORT_RECV" sh -c "ss -ltn | grep -q ':$OGG_PORT_RECV '"
    check "deployment $OGG_TGT_DEPLOY in $OGG_TGT_HOME" test -d "$OGG_TGT_HOME/etc/conf"
}

validate_repl() {
    echo "== repl"
    local out lag
    out=$(adminclient_run "$OGG_TGT_URL" "$OGG_TGT_DEPLOY" <(printf 'INFO ALL\n') 2>&1 || true)
    check "INFO ALL: REPLICAT $OGG_REPLICAT RUNNING"    grep -qiE "REPLICAT[[:space:]]+RUNNING[[:space:]]+${OGG_REPLICAT}([[:space:]]|$)" <<< "$out"
    check "no ABENDED process on $OGG_TGT_DEPLOY"       bash -c '! grep -qi ABENDED <<< "$1"' _ "$out"
    check_eq "checkpoint table $OGG_CKPT_TABLE exists"  "1" q "alter session set container = $TGT_PDB;
select count(*) from dba_tables where owner || '.' || table_name = upper('$OGG_CKPT_TABLE');"
    # Heartbeat views of ADD HEARTBEATTABLE (LAB: view and column names in 23.26); the same lag as probe.sh:
    # lag + age of the freshest path (one row per path, an old path after a relocate only ages)
    lag=$(q "alter session set container = $TGT_PDB;
select nvl(round(min(incoming_lag + nvl(incoming_heartbeat_age, 0)) keep (dense_rank first order by incoming_heartbeat_age nulls last)), 999) from ggadmin.gg_lag;" 2>/dev/null || echo 999)
    check "heartbeat lag < 30 s (now: ${lag:-?} s)"     awk "BEGIN { exit !(${lag:-999} + 0 < 30) }"
}

for s in $sections; do
    case "$s" in
        db)  validate_db ;;
        ogg) validate_ogg ;;
        repl) validate_repl ;;
        *) die "unknown section: $s" ;;
    esac
done
finish_checks
