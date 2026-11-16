#!/bin/bash
# ==============================================================================
# Tytul:        95_baseline.sh
# Opis:         Cel w stanie bazowym (etap A), bez dotykania danych: baza docelowa i listener
#               (oracle-db.service), PDB otwarta, GoldenGate celu (OracleGoldenGate.service), REP1 RUNNING.
#               Kazda faza wypisuje "BASELINE <faza> <sekundy> done|noop [szczegoly]".
# Description [EN]: Target in the base state (stage A), data untouched: target database and listener
#               (oracle-db.service), PDB open, target GoldenGate (OracleGoldenGate.service), REP1 RUNNING.
#               Each phase prints "BASELINE <phase> <seconds> done|noop [details]".
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab zbudowany (lab.cmd tgt, ogg, oggconf); ggtgt wlaczona
# Requirements [EN]: - lab built (lab.cmd tgt, ogg, oggconf); ggtgt powered on
#
# Uzycie [PL]:       bash /root/lab/tgt/95_baseline.sh   (lab.cmd baseline; DRY_RUN=1 = podglad)
# Usage [EN]:        bash /root/lab/tgt/95_baseline.sh   (lab.cmd baseline; DRY_RUN=1 = preview)
# ==============================================================================
source /root/lab/lib.sh

phase() { PH=$1; PH_T=$(uptime_s); PH_ACT=noop; PH_DET=""; log "baseline: $PH"; }
did() { PH_ACT=done; PH_DET="${PH_DET:+$PH_DET; }$*"; }
phase_end() { echo "BASELINE $PH $(( $(uptime_s) - PH_T )) $PH_ACT${PH_DET:+ $PH_DET}"; }

# --- 1. Target database: the unit starts the listener and the oratab=Y database (dbstart through bash, SELinux)
phase tgt_db
if ! systemctl is-active -q oracle-db.service; then
    run systemctl start oracle-db.service || die "systemctl start oracle-db.service failed (journalctl -u oracle-db)"
    did "oracle-db.service started"
fi
wait_until 600 "$TGT_PDB open READ WRITE" pdb_ready "$TGT_PDB"
phase_end

# --- 2. Target GoldenGate: Service Manager unit (registered by oggca), then REP1 (profile MAA autostarts it)
phase tgt_ogg
if ! systemctl is-active -q OracleGoldenGate.service; then
    run systemctl start OracleGoldenGate.service || die "systemctl start OracleGoldenGate.service failed"
    did "OracleGoldenGate.service started"
fi
rep_ok() { bash /root/lab/shared/probe.sh gg 1 --once 2>/dev/null | grep -qE "^PROC ${OGG_REPLICAT^^} [^ ]+ RUNNING"; }
rep_ok || did "waited for ${OGG_REPLICAT^^}"
wait_until 300 "${OGG_REPLICAT^^} RUNNING" rep_ok
phase_end
ok "target side in the base state"
