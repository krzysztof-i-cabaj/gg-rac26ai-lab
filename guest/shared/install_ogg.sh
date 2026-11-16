#!/bin/bash
# ==============================================================================
# Tytul:        install_ogg.sh
# Opis:         Oprogramowanie GoldenGate 26ai (23.26) Microservices lokalnie w OGG_HOME (MAA:
#               binaria na kazdym wezle, nie na ACFS): rozpakowanie, runInstaller -silent z
#               oggcore.rsp, potem bundle patch przez OPatch z OGG_HOME. Zainstalowany home i
#               nalozona latka = pominiete. Latki nie naklada przy dzialajacym Service Managerze.
# Description [EN]: GoldenGate 26ai (23.26) Microservices software local in OGG_HOME (MAA: binaries
#               on each node, not on ACFS): unzip, runInstaller -silent with oggcore.rsp, then the
#               bundle patch with OPatch from OGG_HOME. Installed home and applied patch = skipped.
#               Never patches while a Service Manager of this home is running.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1 (unzip_once)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - ZIP GoldenGate (i bundle) w $STAGE_DIR (lab.cmd ogg kopiuje je na kazdy wezel)
# Requirements [EN]: - GoldenGate ZIP (and bundle) in $STAGE_DIR (lab.cmd ogg copies them to each node)
#
# Uzycie [PL]:       przez rac/80_install_ogg.sh albo tgt/80_install_ogg.sh   (DRY_RUN=1 = podglad)
# Usage [EN]:        via rac/80_install_ogg.sh or tgt/80_install_ogg.sh   (DRY_RUN=1 = preview)
# ==============================================================================
source /root/lab/lib.sh

LOG=$LOG_DIR/ogg_install.log
SRC=$STAGE_DIR/ogg
RSP=$STAGE_DIR/oggcore.rsp
INV_XML=$INVENTORY/ContentsXML/inventory.xml

ogg_installed() { grep -q "LOC=\"$OGG_HOME\"" "$INV_XML" 2>/dev/null && [ -x "$OGG_HOME/bin/adminclient" ]; }

# --- 1. Software
if ogg_installed; then
    ok "GoldenGate home in the inventory: $OGG_HOME"
else
    [ -n "$OGG_ZIP" ] && [ -f "$STAGE_DIR/$OGG_ZIP" ] || die "missing $STAGE_DIR/$OGG_ZIP (Binaries.OggZip; lab.cmd ogg copies it)"
    run mkdir -p "$OGG_HOME" "$SRC"; run chown oracle:oinstall "$OGG_HOME" "$SRC"
    unzip_once oracle "$STAGE_DIR/$OGG_ZIP" "$SRC"
    installer=$(ls -d "$SRC"/*/Disk1/runInstaller 2>/dev/null | head -1 || true)
    [ -n "$installer" ] || [ "$DRY_RUN" = "1" ] || die "no */Disk1/runInstaller under $SRC (unexpected ZIP layout)"
    # Our keys and INSTALL_OPTION vs the sample shipped in this release
    sample=$(dirname "${installer:-/nonexistent/x}")/response/oggcore.rsp
    if [ -f "$sample" ]; then
        rsp_keys_check "$LAB_DIR/oggcore.rsp" "$sample" oggcore.rsp
        # INSTALL_OPTION stays a warning: the 23ai/26ai docs still list ORA21c only (stale page, LAB: shipped sample)
        opt=$(sed -n 's/^INSTALL_OPTION=//p' "$LAB_DIR/oggcore.rsp")
        grep -q "$opt" "$sample" && ok "INSTALL_OPTION=$opt named in the sample" || warn "INSTALL_OPTION=$opt not in the sample: $(grep -i 'INSTALL_OPTION' "$sample" | head -3 | tr '\n' ' ')"
    fi
    run install -m 644 -o oracle -g oinstall "$LAB_DIR/oggcore.rsp" "$RSP"
    log "GoldenGate runInstaller -silent (5-10 min; log: $LOG)"
    set +e
    as_user oracle "cd /tmp && $installer -silent -waitforcompletion -responseFile $RSP" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    check_rc "$rc" "GoldenGate runInstaller"
    [ -f /etc/oraInst.loc ] || run "$INVENTORY/orainstRoot.sh"
fi

# --- 2. Bundle patch (pNNNNNNNN_*.zip -> patch NNNNNNNN)
if [ -n "$OGG_BUNDLE_ZIP" ]; then
    pid=$(echo "$OGG_BUNDLE_ZIP" | sed -n 's/^p\([0-9][0-9]*\)_.*/\1/p')
    [ -n "$pid" ] || die "bundle file name not pNNNN_...zip: $OGG_BUNDLE_ZIP"
    if as_user oracle "ORACLE_HOME=$OGG_HOME $OGG_HOME/OPatch/opatch lspatches" 2>/dev/null | grep -q "^$pid"; then
        ok "bundle patch $pid already in $OGG_HOME"
    else
        pgrep -f "$OGG_HOME/bin/ServiceManager" >/dev/null && die "a Service Manager from $OGG_HOME is running: stop GoldenGate before patching (agctl stop goldengate ... / systemctl stop OracleGoldenGate)"
        [ -f "$STAGE_DIR/$OGG_BUNDLE_ZIP" ] || die "missing $STAGE_DIR/$OGG_BUNDLE_ZIP"
        unzip_once oracle "$STAGE_DIR/$OGG_BUNDLE_ZIP" "$STAGE_DIR/ogg_bundle"
        log "opatch apply $pid in $OGG_HOME"
        set +e
        as_user oracle "cd $STAGE_DIR/ogg_bundle/$pid && ORACLE_HOME=$OGG_HOME $OGG_HOME/OPatch/opatch apply -silent" 2>&1 | tee -a "$LOG"
        rc=${PIPESTATUS[0]}
        set -e
        [ "$rc" -eq 0 ] || die "opatch apply $pid rc=$rc (log: $LOG)"
    fi
else
    warn "no GoldenGate bundle configured (Binaries.OggBundle): base release only"
fi
as_user oracle "$OGG_HOME/bin/adminclient -v" 2>/dev/null | head -3 || true
mark_done ogg_sw
ok "GoldenGate software ready in $OGG_HOME"
