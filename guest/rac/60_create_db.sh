#!/bin/bash
# ==============================================================================
# Tytul:        60_create_db.sh
# Opis:         CDB RAC ggcdb z PDB SRCPDB przez dbca -silent (plik rsp 600 z haslem tylko na
#               czas dbca, ARCHIVELOG + FRA na +FRA), potem sql/01_src_prep_cdb.sql (parametry GG
#               na wszystkich instancjach, FORCE LOGGING, supplemental logging). Baza juz
#               zarejestrowana w klastrze = dbca pominiete; czesciowa baza = instrukcja, bez kasowania.
# Description [EN]: RAC CDB ggcdb with PDB SRCPDB via dbca -silent (600 rsp with the password only
#               while dbca runs, ARCHIVELOG + FRA on +FRA), then sql/01_src_prep_cdb.sql (GG
#               parameters on all instances, FORCE LOGGING, supplemental logging). A database
#               already registered in the cluster = dbca skipped; a partial one = instructions only.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1 (pdb_ready)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab.cmd db (oprogramowanie DB na obu wezlach), +DATA i +FRA zamontowane
# Requirements [EN]: - lab.cmd db (DB software on both nodes), +DATA and +FRA mounted
#
# Uzycie [PL]:       bash /root/lab/rac/60_create_db.sh   (na ggrac1; lab.cmd dbca)
# Usage [EN]:        bash /root/lab/rac/60_create_db.sh   (on ggrac1; lab.cmd dbca)
# ==============================================================================
source /root/lab/lib.sh

RSP=$STAGE_DIR/dbca_src.rsp
LOG=$LOG_DIR/dbca_src.log

if as_user oracle "srvctl config database -db $SRC_DB" >/dev/null 2>&1; then
    ok "database $SRC_DB already registered in the cluster, dbca skipped"
else
    # Files of a failed dbca run without a cluster registration: never removed automatically
    if as_user grid "asmcmd ls +DATA/${SRC_DB^^}/" >/dev/null 2>&1; then
        cat >&2 <<EOF
+DATA/${SRC_DB^^}/ exists but $SRC_DB is not registered in the cluster: an earlier dbca stopped half way.
Nothing was removed. Read the log: ls -t $DB_BASE/cfgtoollogs/dbca/$SRC_DB/*.log | head -1
Then, as oracle on $NODE_NAME, remove the partial database and re-run lab.cmd dbca:
  dbca -silent -deleteDatabase -sourceDB $SRC_DB -forceArchiveLogDeletion
  (if dbca refuses: as grid, asmcmd rm -rf +DATA/${SRC_DB^^} +FRA/${SRC_DB^^})
EOF
        die "partial database $SRC_DB, see above"
    fi
    render_secret "$LAB_DIR/dbca_src.rsp" "$RSP" oracle
    log "dbca -silent -createDatabase $SRC_DB (RAC, 40-70 min; log: $LOG)"
    set +e
    as_user oracle "cd /tmp && dbca -silent -createDatabase -responseFile $RSP -ignorePreReqs -enableArchive true -recoveryAreaSize $FRA_SIZE_MB" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    run rm -f "$RSP"
    check_rc "$rc" "dbca -createDatabase $SRC_DB"
fi
as_user oracle "srvctl start database -db $SRC_DB" 2>/dev/null || true
as_user oracle "srvctl status database -db $SRC_DB"
# A dbca that failed after the cluster registration leaves no (or a closed) PDB: stop with what to do
pdb_ready "$SRC_PDB" || {
    cat >&2 <<EOF
$SRC_DB is registered in the cluster but $SRC_PDB is not open READ WRITE: dbca stopped after the registration.
Nothing was removed. Read the log: ls -t $DB_BASE/cfgtoollogs/dbca/$SRC_DB/*.log | head -1
Then, as oracle on $NODE_NAME: dbca -silent -deleteDatabase -sourceDB $SRC_DB -forceArchiveLogDeletion
and re-run lab.cmd dbca
EOF
    die "$SRC_PDB not open, see above"
}

log "sql/01_src_prep_cdb.sql (GG parameters SID='*', FORCE LOGGING, supplemental logging)"
sysdba_file "$LAB_DIR/sql/01_src_prep_cdb.sql" "$STREAMS_POOL_MB" "$SRC_PDB"
mark_done src_db
ok "source CDB $SRC_DB ready"
