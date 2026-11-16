#!/bin/bash
# ==============================================================================
# Tytul:        loadgen.sh
# Opis:         Obciazenie testowe na RAC: dwie rownolegle sesje SYSTEM przez SCAN, po jednej na
#               serwis srv_load1 (ggcdb1) i srv_load2 (ggcdb2), kazda wywoluje
#               SALES.LOADGEN.RUN(<wierszy/s>, <sekund>). Haslo idzie do SQL*Plus potokiem (/nolog
#               + CONNECT ze stdin), nie w argv. Konczy sie po obu sesjach; kod != 0 = blad sesji.
#               Sesja liczy sie jako udana tylko z wierszem "loadgen: N rows" (albo ORA-00028 po stop):
#               SQL*Plus zwraca 0 takze po nieudanym CONNECT. Tryb stop zabija sesje LOADGEN w bazie
#               (zabicie klienta ssh ich nie zatrzymuje) i czeka, az znikna.
# Description [EN]: Test load on the RAC: two parallel SYSTEM sessions through the SCAN, one per
#               service srv_load1 (ggcdb1) and srv_load2 (ggcdb2), each calling
#               SALES.LOADGEN.RUN(<rows/s>, <seconds>). The password reaches SQL*Plus through the
#               pipe (/nolog + CONNECT on stdin), not argv. Ends after both; rc != 0 = a session failed.
#               A session counts only with its "loadgen: N rows" line (or ORA-00028 after stop): SQL*Plus
#               returns 0 after a failed CONNECT too. Mode stop kills the LOADGEN sessions in the database
#               (killing the ssh client does not stop them) and waits until they are gone.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.3 (znacznik stop: ORA-03113/03114 po stop = planowe zatrzymanie / stop mark; 1.2: stop, ocena wyniku sesji)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - wezel RAC albo ggtgt (klient SQL*Plus, SCAN z DNS); pakiet LOADGEN, serwisy srv_load1/2
# Requirements [EN]: - a RAC node or ggtgt (SQL*Plus client, SCAN in DNS); LOADGEN package, services srv_load1/2
#
# Uzycie [PL]:       bash /root/lab/shared/loadgen.sh <wierszy_na_s> <sekund>   (np. 10 60)
#                    bash /root/lab/shared/loadgen.sh stop                     (zatrzymanie obciazenia)
# Usage [EN]:        bash /root/lab/shared/loadgen.sh <rows_per_sec> <seconds> | stop
# ==============================================================================
source /root/lab/lib.sh
# Left by "stop" (load and stop run on the same host): a session cut after it is a planned stop, not a failure
STOP_MARK=${STOP_MARK:-/tmp/loadgen.stop}

# SQL*Plus as SYSTEM through the SCAN; the password goes to stdin, never argv
system_sql() {
    local svc=$1 body=$2
    printf 'whenever sqlerror exit 1\nconnect system/"%s"@//%s.%s:1521/%s\nset heading off feedback off pagesize 0 serveroutput on\n%s\nexit\n' \
        "$LAB_PASS" "$SCAN_NAME" "$LAB_DOMAIN" "$svc" "$body" |
        runuser -l oracle -c 'sqlplus -S -L /nolog' 2>&1
}

one_session() {
    local svc=$1 out rc=0
    out=$(system_sql "$svc" "exec sales.loadgen.run($rate, $secs)") || rc=$?
    echo "$out" | sed "s/^/[$svc] /"
    case "$out" in
        *"loadgen: "*" rows"*) return 0 ;;
        *ORA-00028*) echo "[$svc] stopped (loadgen.sh stop)"; return 0 ;;
        # kill session immediate may leave the client with ORA-03113/03114; a fault (instance down) leaves no mark
        *ORA-0311[34]*) if [ -f "$STOP_MARK" ]; then echo "[$svc] stopped (loadgen.sh stop)"; return 0; fi ;;
    esac
    [ "$rc" -ne 0 ] || rc=1
    return "$rc"
}

[ "$NODE_ROLE" != "infra" ] || die "loadgen needs a database client (RAC node or ggtgt)"

if [ "${1:-}" = "stop" ]; then
    if [ "$DRY_RUN" = "1" ]; then echo "  DRY  loadgen stop: alter system kill session for module LOADGEN (gv\$session)"; exit 0; fi
    need_lab_pass
    touch "$STOP_MARK"
    svc=${LOAD_SERVICES%% *}
    stop_sql=$(cat <<'SQL'
begin
  for s in (select inst_id, sid, serial# from gv$session where module = 'LOADGEN' and status <> 'KILLED') loop
    begin
      execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ',@' || s.inst_id || ''' immediate';
    exception when others then null;  -- already gone
    end;
  end loop;
end;
/
select 'LEFT ' || count(*) from gv$session where module = 'LOADGEN' and status <> 'KILLED';
SQL
)
    for i in $(seq 1 12); do
        left=$(system_sql "$svc" "$stop_sql" | sed -n 's/^LEFT \([0-9]*\)$/\1/p' | tail -1)
        if [ "${left:-x}" = "0" ]; then ok "loadgen stopped (no LOADGEN session left)"; exit 0; fi
        log "loadgen stop: ${left:-?} LOADGEN session(s) left, try $i/12"
        sleep 5
    done
    die "LOADGEN sessions still running after 60 s: check gv\$session where module = 'LOADGEN'"
fi

rate=${1:-10}; secs=${2:-60}
if [ "$DRY_RUN" = "1" ]; then echo "  DRY  loadgen $rate rows/s x ${secs}s on: $LOAD_SERVICES"; exit 0; fi
need_lab_pass
rm -f "$STOP_MARK"

log "loadgen: $rate rows/s for ${secs}s on each of: $LOAD_SERVICES"
pids=()
for svc in $LOAD_SERVICES; do one_session "$svc" & pids+=($!); done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ] || die "a loadgen session failed (see the lines above)"
ok "loadgen finished"
