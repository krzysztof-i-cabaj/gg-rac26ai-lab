#!/bin/bash
# ==============================================================================
# Tytul:        probe.sh
# Opis:         Probnik stanu do testow awarii: w petli co <interwal> s wypisuje wiersze stanu, a host
#               nadaje im czas w chwili odbioru (jeden zegar). Tryby: crs (wezel RAC: zasoby lancucha,
#               instancje, wezly, wiersze LOADGEN per instancja, v$thread, lag capture), gg (procesy GG
#               z adminclient: src = EXT1 i DP1 przez VIP, tgt = REP1), lag (ggtgt: lag heartbeat i wiersze
#               dojechane per instancja). Tylko odczyt; konczy sie, gdy host zerwie polaczenie.
# Description [EN]: State probe for the failure tests: every <interval> s it prints state lines and
#               the host stamps them on receipt (one clock). Modes: crs (RAC node: chain resources,
#               instances, nodes, LOADGEN rows per instance, v$thread, capture lag), gg (GG processes from
#               adminclient: src = EXT1 and DP1 through the VIP, tgt = REP1), lag (ggtgt: heartbeat lag
#               and arrived rows per instance). Read-only; ends when the host drops the connection.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.2 (lag z najswiezszej sciezki gg_lag, ACFS na wezle VIP / lag of the freshest path, ACFS on the VIP node)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab po lab.cmd validate; uruchamia go tests/sampler.ps1 przez SSH
# Requirements [EN]: - lab after lab.cmd validate; started by tests/sampler.ps1 over SSH
#
# Uzycie [PL]:       bash /root/lab/shared/probe.sh crs|gg|lag [interwal_s] [--once]
# Usage [EN]:        bash /root/lab/shared/probe.sh crs|gg|lag [interval_s] [--once]
# ==============================================================================
source /root/lab/lib.sh
set +e   # a probe keeps going when one query fails

mode=${1:-crs}; interval=${2:-1}; once=${3:-}
G=$GRID_HOME/bin
SVC_RES=ora.${SRC_DB}.${GG_SERVICE}.svc
XAG_RES=xag.${OGG_SRC_DEPLOY}.goldengate     # LAB: XAG resource name in 10.2
DB_RES=ora.${SRC_DB}.db

# STATE=ONLINE on ggrac1  ->  "<node> ONLINE";  STATE=OFFLINE -> "- OFFLINE"
# A local resource (the ACFS filesystem) has one entry per node: "ONLINE on ggrac1, OFFLINE" -> "ggrac1 ONLINE".
# The ONLINE entry wins, then the first entry with a node, then the first state.
state_of() {
    local s=$1 e first="" hit="" IFS=','
    [ -n "$s" ] || { echo "- UNKNOWN"; return; }
    for e in $s; do
        e="${e#"${e%%[! ]*}"}"
        [ -n "$first" ] || first=$e
        case "$e" in
            "ONLINE on "*) echo "${e##* on } ONLINE"; return ;;
            *" on "*) [ -n "$hit" ] || hit="${e##* on } ${e%% *}" ;;
        esac
    done
    if [ -n "$hit" ]; then echo "$hit"; else echo "- ${first%% *}"; fi
}

# ACFS is a local resource: after a relocate it stays ONLINE on the old node too. The entry on the VIP node
# (VIP, ACFS and GoldenGate move together under XAG) wins, else state_of
acfs_state() {
    local v=$1 vipnode=$2
    case ", $v," in *", ONLINE on $vipnode,"*) [ "$vipnode" != "-" ] && { echo "$vipnode ONLINE"; return; } ;; esac
    state_of "$v"
}

probe_crs() {
    local out name st n i=1 acfs_v="" acfs_seen="" vip_st="- UNKNOWN"
    out=$("$G/crsctl" status resource "$SVC_RES" "$OGG_ACFS_RES" "$OGG_VIP_NAME" "$XAG_RES" "$DB_RES" 2>/dev/null)
    while IFS='=' read -r k v; do
        case "$k" in
            NAME) name=$v ;;
            STATE)
                case "$name" in
                    "$SVC_RES") echo "RES svc $(state_of "$v")" ;;
                    "$OGG_ACFS_RES") acfs_v=$v; acfs_seen=1 ;;
                    "$OGG_VIP_NAME") vip_st=$(state_of "$v"); echo "RES vip $vip_st" ;;
                    "$XAG_RES") echo "RES sm $(state_of "$v")" ;;
                    "$DB_RES")
                        i=1
                        for n in $RAC_NODES; do
                            st=$(echo "$v" | tr ',' '\n' | sed -n "s/^ *\([A-Z]*\) on $n\$/\1/p" | head -1)
                            echo "INST ${SRC_DB}$i $n ${st:-OFFLINE}"; i=$((i + 1))
                        done ;;
                esac ;;
        esac
    done <<< "$out"
    [ -z "$acfs_seen" ] || echo "RES acfs $(acfs_state "$acfs_v" "${vip_st%% *}")"
    "$G/olsnodes" -s 2>/dev/null | awk '{print "NODE " $1 " " $2}'
    sysdba_query "alter session set container = $SRC_PDB;
select 'SRCLOAD ' || inst || ' ' || count(*) from sales.load_events group by inst;
select 'CAPLAG ' || nvl(round((max(available_message_create_time) - max(capture_message_create_time)) * 86400), -1) || ' ' || nvl(max(replace(state, ' ', '_')), 'NONE') from v\$goldengate_capture;
alter session set container = CDB\$ROOT;
select 'THREAD ' || thread# || ' ' || status || ' ' || checkpoint_change# from v\$thread;" 2>/dev/null
}

# Node XAG runs the source deployment on ("-" when the XAG resource is not ONLINE anywhere).
# The gg sampler reaches GG through the VIP, so its own node says nothing (film E5).
xag_node() {
    local st
    st=$("$G/crsctl" status resource "$XAG_RES" 2>/dev/null | sed -n 's/^STATE=//p')
    st=$(state_of "$st"); echo "${st%% *}"
}

probe_gg() {
    local side=$1 out url dep node
    if [ "$side" = "tgt" ]; then url=$OGG_TGT_URL; dep=$OGG_TGT_DEPLOY; node=$NODE_NAME
    else url=$OGG_SRC_URL; dep=$OGG_SRC_DEPLOY; node=$(xag_node); fi
    # The log keeps only the last call (one call every 2 s would grow it without end)
    mkdir -p /tmp/probe_gg; : > "/tmp/probe_gg/adminclient_$dep.log"
    out=$(LOG_DIR=/tmp/probe_gg adminclient_run "$url" "$dep" <(printf 'INFO ALL\nINFO DISTPATH %s\n' "$OGG_PATH") 2>&1)
    if ! echo "$out" | grep -qiE 'EXTRACT|REPLICAT|DISTPATH|Path Name'; then
        if [ "$side" = "tgt" ]; then echo "PROC REP1 - UNREACHABLE"; else echo "PROC EXT1 - UNREACHABLE"; echo "PROC DP1 - UNREACHABLE"; fi
        return
    fi
    echo "$out" | awk -v node="$node" 'toupper($1) ~ /^(EXTRACT|REPLICAT)$/ && NF >= 3 { print "PROC " toupper($3) " " node " " toupper($2) }'
    if [ "$side" = "src" ]; then
        if echo "$out" | grep -qiE '(status|state)[^a-z]*running'; then echo "PROC DP1 $node RUNNING"; else echo "PROC DP1 $node STOPPED"; fi
    fi
}

# Lag = lag of the last heartbeat + its age: between heartbeats and during an outage the view keeps the old
# incoming_lag, the age keeps growing (film L1). LAB: column incoming_heartbeat_age in ggadmin.gg_lag (26ai)
# The view keeps one row per path (the DP host is in incoming_path): after a relocate the old path only ages,
# so the freshest row counts (T1 16.11: max() over every path gave 360 s, the freshest path 10 s)
probe_lag() {
    sysdba_query "alter session set container = $TGT_PDB;
select 'LAG ' || nvl(round(min(incoming_lag + nvl(incoming_heartbeat_age, 0)) keep (dense_rank first order by incoming_heartbeat_age nulls last)), -1) from ggadmin.gg_lag;
select 'TGTLOAD ' || inst || ' ' || count(*) from sales.load_events group by inst;" 2>/dev/null
}

while :; do
    echo "TICK $mode"
    case "$mode" in
        crs) probe_crs ;;
        gg)  if [ "$NODE_ROLE" = "tgt" ]; then probe_gg tgt; else probe_gg src; fi ;;
        lag) probe_lag ;;
        *) die "mode: crs|gg|lag" ;;
    esac
    [ "$once" = "--once" ] && break
    sleep "$interval"
done
