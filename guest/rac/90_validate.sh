#!/bin/bash
# ==============================================================================
# Tytul:        90_validate.sh
# Opis:         Kontrole wezla RAC (tylko odczyt) w sekcjach: grid (klaster, wezly, SCAN, grupy ASM,
#               czas z gginfra), db (instancje, watki, ARCHIVELOG, parametry GG, serwisy, demo);
#               acfs (sterowniki, zasob na jednym wezle), ogg (agctl z XAG_HOME, GG na wezle serwisu, SM na VIP),
#               repl (Extract i Distribution Path RUNNING, capture ENABLED).
#               Kazda kontrola to wiersz CHECK ok|FAIL; kod wyjscia 0 = wszystko ok.
# Description [EN]: RAC node checks (read-only) in sections: grid (cluster, nodes, SCAN, ASM disk
#               groups, time from gginfra), db (instances, threads, ARCHIVELOG, GG parameters,
#               services, demo), acfs (drivers, resource on one node), ogg (XAG agctl, GG on the
#               service node, Service Manager on the VIP), repl (Extract and path RUNNING, capture ENABLED).
#               Each check prints CHECK ok|FAIL; exit 0 = all ok.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.8 (grid: AHF/TFA wylaczone / AHF/TFA off)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - po lab.cmd grid (sekcja grid), lab.cmd services (sekcja db)
# Requirements [EN]: - after lab.cmd grid (grid section), lab.cmd services (db section)
#
# Uzycie [PL]:       bash 90_validate.sh [grid] [db] [acfs] [ogg] [repl]   (bez argumentu: wszystkie)
# Usage [EN]:        bash 90_validate.sh [grid] [db] [acfs] [ogg] [repl]   (no argument: all)
# ==============================================================================
source /root/lab/lib.sh

sections=${*:-grid db acfs ogg repl}
g() { as_user grid "$*"; }
n_rac=$(echo "$RAC_NODES" | wc -w)

validate_grid() {
    echo "== grid"
    check "crsctl check cluster -all: online, nothing offline" \
        sh -c "out=\$(runuser -l grid -c 'crsctl check cluster -all'); echo \"\$out\" | grep -q 'is online' && ! echo \"\$out\" | grep -qiE 'offline|not running|cannot communicate'"
    check_eq "olsnodes -n = $n_rac nodes"          "$n_rac" sh -c "runuser -l grid -c 'olsnodes -n' | wc -l"
    check_eq "srvctl status scan_listener: 3 running" "3" sh -c "runuser -l grid -c 'srvctl status scan_listener' | grep -c 'is running'"
    check "srvctl status scan: 3 VIPs"             sh -c "[ \"\$(runuser -l grid -c 'srvctl status scan' | grep -c 'is running')\" -eq 3 ]"
    for dg in DATA FRA; do
        check "asmcmd lsdg: $dg mounted"           sh -c "runuser -l grid -c 'asmcmd lsdg --suppressheader' | awk '{print \$NF}' | grep -qx '$dg/'"
    done
    check "chronyc -n sources: ^* $INFRA_IP"          sh -c "chronyc -n sources | grep -q '^\^\*.*${INFRA_IP}'"
    # GI 23.26: no ora.ctssd resource and no 'crsctl check ctss' (lab 15.11); older GI: CTSS must be Observer
    check "CTSS absent or Observer (chrony keeps time)" sh -c "! runuser -l grid -c 'crsctl stat res ora.ctssd -init' 2>/dev/null | grep -q '^NAME=ora.ctssd' || runuser -l grid -c 'crsctl check ctss' | grep -q 'Observer'"
    # AHF/TFA from GI 23.26 starved the 2-3 vCPU nodes (ORA-29770, 16.11); the lab runs without it (Kris)
    check "AHF/TFA off (oracle-tfa.service inactive, disabled)" sh -c "! systemctl is-active -q oracle-tfa.service && ! systemctl is-enabled -q oracle-tfa.service"
}

q() { sysdba_query "$1"; }
validate_db() {
    echo "== db"
    check_eq "srvctl status database -db $SRC_DB: $n_rac instances running" "$n_rac" \
        sh -c "runuser -l oracle -c 'srvctl status database -db $SRC_DB' | grep -c 'is running'"
    check_eq "v\$thread: $n_rac threads OPEN"            "$n_rac" q "select count(*) from v\$thread where status = 'OPEN';"
    check_eq "log_mode ARCHIVELOG"                       "ARCHIVELOG" q "select log_mode from v\$database;"
    check_eq "force_logging YES"                         "YES" q "select force_logging from v\$database;"
    check_eq "supplemental_log_data_min YES"             "YES" q "select supplemental_log_data_min from v\$database;"
    check_eq "enable_goldengate_replication TRUE on $n_rac instances" "$n_rac" \
        q "select count(*) from gv\$parameter where name = 'enable_goldengate_replication' and upper(value) = 'TRUE';"
    check_eq "streams_pool_size >= ${STREAMS_POOL_MB}M on $n_rac instances" "$n_rac" \
        q "select count(*) from gv\$parameter where name = 'streams_pool_size' and to_number(value default null on conversion error) >= ${STREAMS_POOL_MB} * 1024 * 1024;"
    check_eq "$SRC_PDB READ WRITE on $n_rac instances"   "$n_rac" \
        q "select count(*) from gv\$pdbs where name = '$SRC_PDB' and open_mode = 'READ WRITE';"
    local cfg
    cfg=$(as_user oracle "srvctl config service -db $SRC_DB -service $GG_SERVICE" 2>/dev/null || true)
    check "$GG_SERVICE: Preferred instances: ${SRC_DB}1"  grep -q "^Preferred instances: ${SRC_DB}1\$" <<< "$cfg"
    check "$GG_SERVICE: Available instances: ${SRC_DB}2"  grep -q "^Available instances: ${SRC_DB}2\$" <<< "$cfg"
    check "$GG_SERVICE running on ${SRC_DB}1"             sh -c "runuser -l oracle -c 'srvctl status service -db $SRC_DB -service $GG_SERVICE' | grep -Eq 'running on (instance\(s\)|instances):? *${SRC_DB}1\$'"
    local i=1 svc
    for svc in $LOAD_SERVICES; do   # srv_load1 -> ggcdb1, srv_load2 -> ggcdb2
        check "$svc running on ${SRC_DB}$i"               sh -c "runuser -l oracle -c 'srvctl status service -db $SRC_DB -service $svc' | grep -Eq 'running on (instance\(s\)|instances):? *${SRC_DB}$i\$'"
        i=$((i + 1))
    done
    check_eq "demo tables HR + SALES = 6"                "6" q "alter session set container = $SRC_PDB;
select count(*) from dba_tables where owner in ('HR', 'SALES');"
    check_eq "sales.types26 seed rows = 3"               "3" q "alter session set container = $SRC_PDB;
select count(*) from sales.types26 where id <= 3;"
    check_eq "SALES.LOADGEN package + body VALID"        "2" q "alter session set container = $SRC_PDB;
select count(*) from dba_objects where owner = 'SALES' and object_name = 'LOADGEN' and status = 'VALID';"
}

# Node that runs the GoldenGate service now (ggcdbN -> N-th RAC node)
# Node of the GG service: "running on instance(s) ggcdb2" or "running on nodes: ggrac2" (12.1 doc example;
# 23ai/26ai document no output, colon optional: LAB); empty when it is down
# (no sed 0p: under set -euo pipefail that aborted the whole validate instead of printing FAIL lines)
gg_node() {
    local inst num n
    inst=$(runuser -l oracle -c "srvctl status service -db $SRC_DB -service $GG_SERVICE" 2>/dev/null |
           sed -n 's/.*running on \(instance(s)\|instances\|nodes\):\{0,1\} *//p' || true)
    inst=${inst%%,*}
    for n in $RAC_NODES; do [ "$inst" = "$n" ] && { echo "$n"; return 0; }; done
    num=${inst#"$SRC_DB"}
    case "$num" in ''|*[!0-9]*) return 0 ;; esac
    echo "$RAC_NODES" | tr ' ' '\n' | sed -n "${num}p"
}
validate_acfs() {
    echo "== acfs"
    check "acfsdriverstate supported: ACFS-9200"   sh -c "$GRID_HOME/bin/acfsdriverstate supported | grep -q 'ACFS-9200'"
    check "acfsdriverstate loaded"                 "$GRID_HOME/bin/acfsdriverstate" loaded
    check_eq "$OGG_ACFS_RES ONLINE on exactly 1 node" "1" \
        sh -c "$GRID_HOME/bin/crsctl status resource $OGG_ACFS_RES | sed -n 's/^STATE=//p' | grep -o 'ONLINE' | wc -l"
    if mountpoint -q "$OGG_DEPLOY_ROOT"; then
        check_eq "$OGG_DEPLOY_ROOT owner oracle:oinstall" "oracle:oinstall" stat -c '%U:%G' "$OGG_DEPLOY_ROOT"
    fi
}
validate_ogg() {
    echo "== ogg"
    local node; node=$(gg_node)
    check_eq "root: command -v agctl = $XAG_HOME/bin/agctl" "$XAG_HOME/bin/agctl" runuser -l root -c 'command -v agctl'
    check "agctl status goldengate $OGG_SRC_DEPLOY: running on ${node:-?} (node of $GG_SERVICE)" \
        sh -c "$XAG_HOME/bin/agctl status goldengate $OGG_SRC_DEPLOY | grep -qi 'running on ${node:-none}'"
    check "$OGG_ACFS_RES ONLINE on ${node:-?}"     sh -c "$GRID_HOME/bin/crsctl status resource $OGG_ACFS_RES | grep -q 'ONLINE on ${node:-none}'"
    check "$OGG_VIP_NAME ONLINE on ${node:-?}"     sh -c "$GRID_HOME/bin/crsctl status resource $OGG_VIP_NAME | grep -q 'ONLINE on ${node:-none}'"
    # Unauthenticated REST call: 200 or 401 = the Service Manager answers on the VIP
    check "Service Manager answers on $OGG_VIP_NAME:$OGG_SM_PORT (HTTP 200/401)" \
        sh -c "curl -s -o /dev/null -m 10 -w '%{http_code}' http://$OGG_VIP_NAME.$LAB_DOMAIN:$OGG_SM_PORT/services/v2/deployments | grep -qE '^(200|401)$'"
}

validate_repl() {
    echo "== repl"
    local out
    out=$(adminclient_run "$OGG_SRC_URL" "$OGG_SRC_DEPLOY" <(printf 'INFO ALL\nINFO DISTPATH %s\nINFO PROFILE MAA\n' "$OGG_PATH") 2>&1 || true)
    check "INFO ALL: EXTRACT $OGG_EXTRACT RUNNING"      grep -qiE "EXTRACT[[:space:]]+RUNNING[[:space:]]+${OGG_EXTRACT}([[:space:]]|$)" <<< "$out"
    check "INFO DISTPATH $OGG_PATH: running"            grep -qiE "(status|state)[^a-z]*running" <<< "$out"
    check "no ABENDED process on $OGG_SRC_DEPLOY"       bash -c '! grep -qi ABENDED <<< "$1"' _ "$out"
    # LAB: INFO PROFILE output; printed for the log, not a hard check
    grep -iA3 'profile' <<< "$out" | head -8 || true
    check "LogMiner capture ENABLED in $SRC_PDB (dba_capture)" sh -c "[ \"\$0\" -ge 1 ]" \
        "$(q "alter session set container = $SRC_PDB;
select count(*) from dba_capture where status = 'ENABLED';" 2>/dev/null || echo 0)"
}

for s in $sections; do
    case "$s" in
        grid) validate_grid ;;
        db)   validate_db ;;
        acfs) validate_acfs ;;
        ogg)  validate_ogg ;;
        repl) validate_repl ;;
        *) die "unknown section: $s" ;;
    esac
done
finish_checks
