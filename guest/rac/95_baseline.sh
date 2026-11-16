#!/bin/bash
# ==============================================================================
# Tytul:        95_baseline.sh
# Opis:         Powrot do stanu bazowego (etap A) po restarcie albo po tescie awarii, bez dotykania danych:
#               klaster i instancje, serwisy na preferowanych instancjach, GoldenGate (XAG) na wezle serwisu GG
#               (start z ponowieniem), ACFS tylko tam, VIP przy nim, EXT1 i DP1 RUNNING. Kazda faza wypisuje
#               wiersz "BASELINE <faza> <sekundy> done|noop [szczegoly]" (czasy do filmu).
# Description [EN]: Back to the base state (stage A) after a restart or a failure test, data untouched:
#               cluster and instances, services on their preferred instances, GoldenGate (XAG) on the node of
#               the GG service (start with retries), ACFS only there, the VIP with it, EXT1 and DP1 RUNNING.
#               Each phase prints "BASELINE <phase> <seconds> done|noop [details]" (video timings).
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (czeka na autostart CRS, PRCZ-4054 = uruchomione / waits for the CRS autostart)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab zbudowany (lab.cmd all); oba wezly RAC wlaczone; uruchamiac na pierwszym wezle RAC
# Requirements [EN]: - lab built (lab.cmd all); both RAC nodes powered on; run on the first RAC node
#
# Uzycie [PL]:       bash /root/lab/rac/95_baseline.sh   (lab.cmd baseline; DRY_RUN=1 = podglad)
# Usage [EN]:        bash /root/lab/rac/95_baseline.sh   (lab.cmd baseline; DRY_RUN=1 = preview)
# ==============================================================================
source /root/lab/lib.sh

G=$GRID_HOME/bin
AGCTL=$XAG_HOME/bin/agctl
read -r -a NAMES <<< "$RAC_NODES"

# lib.sh runs set -euo pipefail: helpers used in $(...) must not return non-zero for a normal answer
inst_of() { local i; for i in "${!NAMES[@]}"; do if [ "${NAMES[$i]}" = "$1" ]; then echo "${SRC_DB}$((i + 1))"; fi; done; }
node_of() { local n=${1#"$SRC_DB"}; echo "${NAMES[$((n - 1))]}"; }
ora() { as_user oracle "$*"; }

# wait_quiet <seconds> command... : like wait_until, but returns 1 on timeout instead of stopping the script
wait_quiet() {
    local timeout=$1; shift
    [ "$DRY_RUN" = "1" ] && return 0
    local deadline=$(( $(uptime_s) + timeout ))
    until "$@" >/dev/null 2>&1; do [ "$(uptime_s)" -lt "$deadline" ] || return 1; sleep 5; done
}

# Phase bookkeeping: one BASELINE line per phase, seconds by uptime (chrony may step the wall clock)
phase() { PH=$1; PH_T=$(uptime_s); PH_ACT=noop; PH_DET=""; log "baseline: $PH"; }
did() { PH_ACT=done; PH_DET="${PH_DET:+$PH_DET; }$*"; }
phase_end() { echo "BASELINE $PH $(( $(uptime_s) - PH_T )) $PH_ACT${PH_DET:+ $PH_DET}"; }

# --- 1. Cluster: every node Active, CRS online everywhere (a booting node needs a few minutes)
cluster_up() {
    local out
    out=$("$G/crsctl" check cluster -all 2>/dev/null) || return 1
    echo "$out" | grep -q 'is online' && ! echo "$out" | grep -qiE 'offline|not running|cannot communicate' || return 1
    [ "$("$G/olsnodes" -s 2>/dev/null | grep -c Active)" -eq "${#NAMES[@]}" ]
}
phase cluster
cluster_up || did "waited for CRS"
wait_until 900 "cluster online on ${NAMES[*]}" cluster_up
phase_end

# --- 2. Instances: right after a cluster start CRS brings them up itself (an early srvctl start raced it,
# PRCZ-4054, 16.11): grace period first, then srvctl start instance only for one still down (srvctl stop, abort).
inst_running() { ora "srvctl status instance -db $SRC_DB -instance $1" 2>/dev/null | grep -q 'is running'; }
all_inst() { local n; for n in "${NAMES[@]}"; do inst_running "$(inst_of "$n")" || return 1; done; }
phase instances
if ! all_inst; then
    did "waited for the CRS autostart"
    wait_quiet 300 all_inst || true
fi
for n in "${NAMES[@]}"; do
    i=$(inst_of "$n")
    if ! inst_running "$i"; then
        out=$(runuser -l oracle -c "srvctl start instance -db $SRC_DB -instance $i" </dev/null 2>&1) \
            || grep -q 'PRCZ-4054' <<< "$out" || die "srvctl start instance $i failed: $out"
        did "started $i"
    fi
done
wait_until 600 "instances of $SRC_DB running" all_inst
phase_end

# --- 3. Services on their preferred instances. Admin-managed: relocate -oldinst/-newinst for a singleton on its
# available instance, start -instance for a preferred instance without it. CRS never moves a service back alone.
running_on() { ora "srvctl status service -db $SRC_DB -service $1" 2>/dev/null | sed -nE 's/.*running on (instance\(s\)|instances):? *//p' | tr -d ' ' || true; }
phase services
for s in $(ora "srvctl config service -db $SRC_DB" | sed -n 's/^Service name: //p'); do
    pref=$(ora "srvctl config service -db $SRC_DB -service $s" | sed -n 's/^Preferred instances: //p' | tr -d ' ' || true)
    [ -n "$pref" ] || continue
    IFS=, read -r -a want <<< "$pref"
    cur=$(running_on "$s")
    for p in "${want[@]}"; do
        case ",$cur," in *",$p,"*) continue ;; esac
        if [ "${#want[@]}" -eq 1 ] && [ -n "$cur" ]; then
            run runuser -l oracle -c "srvctl relocate service -db $SRC_DB -service $s -oldinst ${cur%%,*} -newinst $p" </dev/null \
                || die "srvctl relocate service $s ${cur%%,*} -> $p failed"
            did "$s ${cur%%,*}->$p"
        else
            run runuser -l oracle -c "srvctl start service -db $SRC_DB -service $s -instance $p" </dev/null || die "srvctl start service $s on $p failed"
            did "$s started on $p"
        fi
    done
done
phase_end

# GoldenGate belongs on the node of the GG service (--use_local_services); after phase 3 that is the base node
gg_inst=$(running_on "$GG_SERVICE" | cut -d, -f1)
want_node=$([ -n "$gg_inst" ] && node_of "$gg_inst" || true)
[ -n "$want_node" ] || [ "$DRY_RUN" = "1" ] || die "$GG_SERVICE is not running: no node for GoldenGate"
want_node=${want_node:-${NAMES[0]}}

# --- 4. GoldenGate through XAG: relocate when on the other node, start (3 tries) when down. The XAG health check
# can outlast its 60 s script timeout on a busy node right after a cluster start (lab 16.11): CRS then cleans the
# resource although GoldenGate came up, so a failed start is retried after a pause.
gg_node() { "$AGCTL" status goldengate "$OGG_SRC_DEPLOY" 2>/dev/null | sed -n "s/.* is running on //p" | tr -d ' ' || true; }
phase goldengate
cur=$(gg_node)
if [ -n "$cur" ] && [ "$cur" != "$want_node" ]; then
    run "$AGCTL" relocate goldengate "$OGG_SRC_DEPLOY" --node "$want_node" || die "agctl relocate goldengate $OGG_SRC_DEPLOY --node $want_node failed"
    did "relocated $cur->$want_node"
elif [ -z "$cur" ]; then
    # CRS may be starting it right now (it did after the restart of 16.11): a short grace period first
    gg_here() { [ "$(gg_node)" = "$want_node" ]; }
    if wait_quiet 120 gg_here; then
        did "came up by itself on $want_node"
    else
        for try in 1 2 3; do
            if [ "$(gg_node)" = "$want_node" ]; then break; fi
            run "$AGCTL" start goldengate "$OGG_SRC_DEPLOY" --node "$want_node" || warn "agctl start try $try: rc=$?"
            if [ "$DRY_RUN" = "1" ] || wait_quiet 60 gg_here; then break; fi
            [ "$try" -lt 3 ] || die "agctl start goldengate $OGG_SRC_DEPLOY --node $want_node failed 3 times (trace: $XAG_HOME/log/$want_node)"
        done
        did "started on $want_node (tries: $try)"
    fi
    # moved by hand to a node other than the service node: relocate it
    cur=$(gg_node)
    if [ -n "$cur" ] && [ "$cur" != "$want_node" ]; then
        run "$AGCTL" relocate goldengate "$OGG_SRC_DEPLOY" --node "$want_node" || die "agctl relocate goldengate failed"
        did "relocated $cur->$want_node"
    fi
fi
phase_end

# --- 5. ACFS only on the GoldenGate node (AUTO_START=restore mounts it on every node after a full cluster restart)
phase acfs
dev=$("$G/crsctl" status resource "$OGG_ACFS_RES" -p 2>/dev/null | sed -n 's/^VOLUME_DEVICE=//p' || true)
state=$("$G/crsctl" status resource "$OGG_ACFS_RES" 2>/dev/null | sed -n 's/^STATE=//p' || true)
for n in "${NAMES[@]}"; do
    [ "$n" = "$want_node" ] && continue
    case "$state" in *"ONLINE on $n"*)
        [ -n "$dev" ] || die "no VOLUME_DEVICE for $OGG_ACFS_RES"
        run runuser -l grid -c "srvctl stop filesystem -device $dev -node $n" </dev/null || die "srvctl stop filesystem on $n failed (something uses /u01/oggdeploy there?)"
        did "unmounted on $n" ;;
    esac
done
phase_end

# --- 6. Chain on one node and EXT1 + DP1 RUNNING (profile MAA autostarts them about 60 s after GoldenGate)
probe_ok() {
    local p; p=$(bash /root/lab/shared/probe.sh crs 1 --once 2>/dev/null; bash /root/lab/shared/probe.sh gg 1 --once 2>/dev/null)
    for r in vip acfs svc sm; do grep -q "^RES $r $want_node ONLINE" <<< "$p" || return 1; done
    grep -qE "^PROC ${OGG_EXTRACT^^} [^ ]+ RUNNING" <<< "$p" && grep -qE "^PROC ${OGG_PATH^^} [^ ]+ RUNNING" <<< "$p"
}
phase processes
probe_ok || did "waited for autostart"
wait_until 300 "VIP, ACFS, service, GoldenGate on $want_node; ${OGG_EXTRACT^^} and ${OGG_PATH^^} RUNNING" probe_ok
phase_end
ok "source side in the base state on $want_node"
