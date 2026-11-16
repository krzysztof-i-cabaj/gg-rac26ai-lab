#!/bin/bash
# ==============================================================================
# Tytul:        install_db.sh
# Opis:         Oprogramowanie Oracle Database 26ai (23.26) w fazach: stage (rozpakowanie DB,
#               OPatch, RU), install (runInstaller -silent [-applyRU], na RAC od razu na obu wezlach
#               przez SSH, na ggtgt single-instance), root (root.sh na kazdym wezle). Gotowe fazy
#               pomija; zainstalowanego home nie rusza; niczego nie kasuje sam.
# Description [EN]: Oracle Database 26ai (23.26) software in phases: stage (unzip DB, OPatch, RU),
#               install (runInstaller -silent [-applyRU]; on RAC both nodes over SSH, on ggtgt
#               single-instance), root (root.sh on each node). Skips finished phases; never
#               touches an installed home; never deletes anything on its own.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1 (unzip_once)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - RAC: GI dziala, rownowaznosc SSH oracle; ZIP-y w $STAGE_DIR (lab.cmd db / tgt)
# Requirements [EN]: - RAC: GI running, oracle SSH equivalence; ZIPs in $STAGE_DIR (lab.cmd db / tgt)
#
# Uzycie [PL]:       przez rac/50_install_db.sh albo tgt/50_install_db.sh stage|install|root
#                    (DRY_RUN=1 = podglad); wspolny kod dla RAC i celu (guest/shared)
# Usage [EN]:        via rac/50_install_db.sh or tgt/50_install_db.sh stage|install|root
#                    (DRY_RUN=1 = preview); shared code for RAC and the target (guest/shared)
# ==============================================================================
source /root/lab/lib.sh

phase=${1:-}
RSP=$STAGE_DIR/db_install.rsp
LOG=$LOG_DIR/db_${phase}.log
RU_DIR=$STAGE_DIR/ru_db/$DB_RU_ID
INV_XML=$INVENTORY/ContentsXML/inventory.xml

db_installed() { grep -q "LOC=\"$DB_HOME\"" "$INV_XML" 2>/dev/null; }
# A DB RU is a bundle too: compare its numeric sub-patch directories with the home's oneoffs.
ru_applied() {
    local s subs
    [ -n "$DB_RU_ID" ] || return 1
    [ -d "$DB_HOME/inventory/oneoffs/$DB_RU_ID" ] && return 0
    subs=$(ls "$RU_DIR" 2>/dev/null | grep -xE '[0-9]+' || true)
    [ -n "$subs" ] || return 1
    for s in $subs; do [ -d "$DB_HOME/inventory/oneoffs/$s" ] || return 1; done
}

case "$phase" in
    stage)
        if db_installed; then ok "DB home in the inventory, stage skipped"; exit 0; fi
        [ -n "$DB_ZIP" ] && [ -f "$STAGE_DIR/$DB_ZIP" ] || die "missing $STAGE_DIR/$DB_ZIP (lab.cmd db copies the ZIPs)"
        run mkdir -p "$DB_HOME"; run chown oracle:oinstall "$DB_HOME"
        unzip_once oracle "$STAGE_DIR/$DB_ZIP" "$DB_HOME"
        if [ -n "$OPATCH_ZIP" ]; then
            [ -f "$STAGE_DIR/$OPATCH_ZIP" ] || die "missing $STAGE_DIR/$OPATCH_ZIP"
            if [ -f "$STAGE_DIR/.opatch_db_done" ]; then ok "OPatch already replaced in DB_HOME"
            else
                log "replace OPatch in DB_HOME"
                as_user oracle "cd $DB_HOME && rm -rf OPatch && unzip -q -o $STAGE_DIR/$OPATCH_ZIP"
                run touch "$STAGE_DIR/.opatch_db_done"
            fi
        fi
        if [ -n "$DB_RU_ZIP" ]; then
            unzip_once oracle "$STAGE_DIR/$DB_RU_ZIP" "$STAGE_DIR/ru_db"
        else
            warn "no DB RU configured (Binaries.DbRu): base 23.26.1 only"
        fi
        sample=$DB_HOME/install/response/db_install.rsp
        if [ -f "$sample" ]; then
            rsp_keys_check "$LAB_DIR/db_install.rsp" "$sample" db_install.rsp
        fi
        ;;
    install)
        if db_installed; then ok "DB home in the inventory"; exit 0; fi
        run install -m 644 -o oracle -g oinstall "$LAB_DIR/db_install.rsp" "$RSP"
        APPLY=""
        if [ -n "$DB_RU_ID" ]; then
            # A retry after a failure past the RU step: the patch is in the home already
            if ru_applied; then ok "RU $DB_RU_ID already in DB_HOME, no -applyRU"
            else APPLY="-applyRU $RU_DIR"; fi
        fi
        log "runInstaller -silent ${APPLY:-(no RU)} (20-40 min; log: $LOG)"
        set +e
        as_user oracle "cd /tmp && $DB_HOME/runInstaller -silent -ignorePrereqFailure -waitforcompletion $APPLY -responseFile $RSP" 2>&1 | tee "$LOG"
        rc=${PIPESTATUS[0]}
        set -e
        check_rc "$rc" "runInstaller (DB software)"
        ;;
    root)
        if step_done db_root; then ok "DB root.sh already done on $NODE_NAME"; exit 0; fi
        db_installed || [ "$DRY_RUN" = "1" ] || die "DB software not installed yet (phase install on the first node)"
        [ -f "$INVENTORY/orainstRoot.sh" ] && [ ! -f /etc/oraInst.loc ] && run "$INVENTORY/orainstRoot.sh"
        log "root.sh (DB) on $NODE_NAME"
        set +e
        run "$DB_HOME/root.sh" 2>&1 | tee "$LOG"
        rc=${PIPESTATUS[0]}
        set -e
        [ "$rc" -eq 0 ] || die "root.sh (DB) rc=$rc, log: $LOG"
        mark_done db_root
        ok "root.sh (DB) OK on $NODE_NAME"
        ;;
    *) die "phase: stage|install|root" ;;
esac
