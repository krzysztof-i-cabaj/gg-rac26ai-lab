#!/bin/bash
# ==============================================================================
# Tytul:        40_install_grid.sh
# Opis:         Grid Infrastructure 26ai (23.26) w fazach: stage (rozpakowanie GI, OPatch, RU,
#               cvuqdisk), cvuqdisk (drugi wezel), install (gridSetup.sh -silent [-applyRU]),
#               root (root.sh na kazdym wezle), config (-executeConfigTools), fra (+FRA), ahf (AHF/TFA off). Kazda faza wykrywa
#               stan: gotowe = pomija; stan czesciowy = wznawia, jesli Oracle to dopuszcza, inaczej
#               konczy sie bledem z instrukcja sprzatania. Niczego nie kasuje sam.
# Description [EN]: Grid Infrastructure 26ai (23.26) in phases: stage (unzip GI, OPatch, RU,
#               cvuqdisk), cvuqdisk (second node), install (gridSetup.sh -silent [-applyRU]),
#               root (root.sh on each node), config (-executeConfigTools), fra (+FRA), ahf (AHF/TFA off). Each phase detects
#               state: done = skip; partial = resume where Oracle allows it, otherwise stop with
#               cleanup instructions. It never deletes anything on its own.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.5 (faza ahf: AHF/TFA wylaczone w labie / ahf phase: AHF/TFA off in the lab)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - 10_os_prereq, 20_asm_udev, 30_ssh_equivalence (grid); ZIP-y w $STAGE_DIR (lab.cmd grid)
# Requirements [EN]: - 10_os_prereq, 20_asm_udev, 30_ssh_equivalence (grid); ZIPs in $STAGE_DIR (lab.cmd grid)
#
# Uzycie [PL]:       bash 40_install_grid.sh stage|cvuqdisk|install|root|config|fra|ahf   (DRY_RUN=1 = podglad)
# Usage [EN]:        bash 40_install_grid.sh stage|cvuqdisk|install|root|config|fra|ahf   (DRY_RUN=1 = preview)
# ==============================================================================
source /root/lab/lib.sh

phase=${1:-}
RSP=$STAGE_DIR/grid.rsp
LOG=$LOG_DIR/grid_${phase}.log
RU_DIR=$STAGE_DIR/ru_gi/$GRID_RU_ID
INV_XML=$INVENTORY/ContentsXML/inventory.xml

gi_installed() { grep -q "LOC=\"$GRID_HOME\".*CRS=\"true\"" "$INV_XML" 2>/dev/null; }
# Home in the inventory (gridSetup registers it before root.sh; CRS="true" comes with root.sh).
gi_registered() { grep -q "LOC=\"$GRID_HOME\"" "$INV_XML" 2>/dev/null; }
# Registered, no CRS="true" and no install marker: gridSetup stopped half way.
# Not root.sh: the 23.26 image ZIP ships it, so a freshly unzipped home has one.
gi_partial() { ! gi_installed && ! step_done grid_install && gi_registered; }
crs_up() { [ -x "$GRID_HOME/bin/crsctl" ] && "$GRID_HOME/bin/crsctl" check crs >/dev/null 2>&1; }
# A GI RU is a bundle: the home's oneoffs hold its numeric sub-patches, not the bundle number.
ru_applied() {
    local s subs
    [ -n "$GRID_RU_ID" ] || return 1
    [ -d "$GRID_HOME/inventory/oneoffs/$GRID_RU_ID" ] && return 0
    subs=$(ls "$RU_DIR" 2>/dev/null | grep -xE '[0-9]+' || true)
    [ -n "$subs" ] || return 1
    for s in $subs; do [ -d "$GRID_HOME/inventory/oneoffs/$s" ] || return 1; done
}
partial_help() {
    cat >&2 <<EOF
Partial Grid Infrastructure install found in $GRID_HOME (inventory: no CRS="true").
Nothing was removed. Pick one, then run lab.cmd grid again:
  a) inspect the last log: ls -t $INVENTORY/logs/GridSetupActions*/gridSetupActions*.log | head -1
  b) clean the half-installed home, as grid on $NODE_NAME:
       $GRID_HOME/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=$GRID_HOME
     then as root on every node: rm -rf $GRID_HOME/* and re-run: lab.cmd grid
EOF
}

case "$phase" in
    stage)
        # Never touch an installed home: after root.sh it belongs to root
        if gi_installed; then ok "GI installed, stage skipped"; exit 0; fi
        [ -n "$GRID_ZIP" ] && [ -f "$STAGE_DIR/$GRID_ZIP" ] || die "missing $STAGE_DIR/$GRID_ZIP (lab.cmd grid copies the ZIPs)"
        unzip_once grid "$STAGE_DIR/$GRID_ZIP" "$GRID_HOME"
        if [ -n "$OPATCH_ZIP" ]; then
            [ -f "$STAGE_DIR/$OPATCH_ZIP" ] || die "missing $STAGE_DIR/$OPATCH_ZIP"
            if [ -f "$STAGE_DIR/.opatch_grid_done" ]; then ok "OPatch already replaced"
            else
                log "replace OPatch in GRID_HOME"
                as_user grid "cd $GRID_HOME && rm -rf OPatch && unzip -q -o $STAGE_DIR/$OPATCH_ZIP"
                run touch "$STAGE_DIR/.opatch_grid_done"
            fi
        fi
        if [ -n "$GRID_RU_ZIP" ]; then
            unzip_once grid "$STAGE_DIR/$GRID_RU_ZIP" "$STAGE_DIR/ru_gi"
        else
            warn "no GI RU configured (Binaries.GridRu): base 23.26.1 only; OL9 with UEK8 needs >= 23.26.2"
        fi
        # Our response keys vs the sample shipped with this GI version (keys renamed between releases)
        sample=$GRID_HOME/install/response/gridsetup.rsp
        if [ -f "$sample" ]; then
            rsp_keys_check "$LAB_DIR/gridsetup.rsp" "$sample" gridsetup.rsp
        fi
        rpm -q cvuqdisk >/dev/null 2>&1 || run env CVUQDISK_GRP=oinstall rpm -ivh "$GRID_HOME"/cv/rpm/cvuqdisk-*.rpm
        for n in $RAC_NODES; do
            [ "$n" = "$NODE_NAME" ] && continue
            as_user grid "scp -q $GRID_HOME/cv/rpm/cvuqdisk-*.rpm $n:/tmp/"
            ok "cvuqdisk -> $n:/tmp"
        done
        ;;
    cvuqdisk)
        if rpm -q cvuqdisk >/dev/null 2>&1; then ok "cvuqdisk installed"; exit 0; fi
        ls /tmp/cvuqdisk-*.rpm >/dev/null 2>&1 || [ "$DRY_RUN" = "1" ] || die "no /tmp/cvuqdisk-*.rpm (run phase stage on the first node)"
        run env CVUQDISK_GRP=oinstall rpm -ivh /tmp/cvuqdisk-*.rpm
        ;;
    install)
        if gi_installed; then ok "GI installed (inventory CRS=true)"; exit 0; fi
        if step_done grid_install; then ok "GI software installed earlier, root.sh is next"; exit 0; fi
        if gi_partial; then partial_help; die "partial GI install, see above"; fi
        render_secret "$LAB_DIR/gridsetup.rsp" "$RSP" grid
        APPLY=""
        if [ -n "$GRID_RU_ID" ]; then
            if ru_applied; then ok "RU $GRID_RU_ID already in GRID_HOME, no -applyRU"
            else APPLY="-applyRU $RU_DIR"; fi
        fi
        log "gridSetup.sh -silent ${APPLY:-(no RU)} (30-40 min; log: $LOG)"
        set +e
        as_user grid "cd /tmp && $GRID_HOME/gridSetup.sh -silent -ignorePrereqFailure $APPLY -responseFile $RSP" 2>&1 | tee "$LOG"
        rc=${PIPESTATUS[0]}
        set -e
        check_rc "$rc" "gridSetup.sh install"
        mark_done grid_install
        ;;
    root)
        if crs_up; then ok "CRS running on $NODE_NAME, root.sh skipped"; exit 0; fi
        gi_registered || [ "$DRY_RUN" = "1" ] || die "GI home not in the inventory yet (phase install on the first node)"
        [ -f "$INVENTORY/orainstRoot.sh" ] && run "$INVENTORY/orainstRoot.sh" | tee "$LOG"
        # root.sh keeps checkpoints: re-running it after an interruption resumes where it stopped
        [ -f /etc/oracle/olr.loc ] && log "earlier root.sh run found: re-running resumes from its checkpoint"
        log "root.sh on $NODE_NAME (10-20 min)"
        set +e
        run "$GRID_HOME/root.sh" 2>&1 | tee -a "$LOG"
        rc=${PIPESTATUS[0]}
        set -e
        [ "$rc" -eq 0 ] || die "root.sh rc=$rc. Log: $GRID_HOME/install/root_${NODE_NAME}*.log. If a re-run fails again, deconfigure this node as root: $GRID_HOME/crs/install/rootcrs.sh -deconfig -force, then lab.cmd grid"
        ok "root.sh OK on $NODE_NAME"
        ;;
    config)
        if step_done grid_config; then ok "GI config tools already done"; as_user grid "crsctl check cluster -all"; exit 0; fi
        [ -f "$RSP" ] || render_secret "$LAB_DIR/gridsetup.rsp" "$RSP" grid
        log "gridSetup.sh -executeConfigTools (5-10 min)"
        set +e
        as_user grid "cd /tmp && $GRID_HOME/gridSetup.sh -silent -executeConfigTools -responseFile $RSP" 2>&1 | tee "$LOG"
        rc=${PIPESTATUS[0]}
        set -e
        run rm -f "$RSP"
        check_rc "$rc" "gridSetup.sh -executeConfigTools"
        as_user grid "crsctl check cluster -all"
        mark_done grid_config
        ;;
    fra)
        # gridSetup creates +DATA only; +FRA holds the archived logs of both threads
        if as_user grid "asmcmd lsdg --suppressheader FRA" 2>/dev/null | grep -q 'FRA/'; then ok "+FRA exists"
        else
            log "asmca: create +FRA on $FRA_DISKS (EXTERNAL)"
            as_user grid "asmca -silent -createDiskGroup -diskGroupName FRA -disk '$FRA_DISKS' -redundancy EXTERNAL -au_size 4 -compatible.asm 23.0.0.0.0 -compatible.rdbms 23.0.0.0.0"
        fi
        # mounted on every node (asmca mounts it only where it ran)
        as_user grid "srvctl start diskgroup -diskgroup FRA" 2>/dev/null || true
        as_user grid "srvctl status diskgroup -diskgroup FRA"
        ;;
    ahf)
        # AHF/TFA comes with GI 23.26 and runs rediscover/adrci scans; on 2-3 vCPU lab nodes it starved LMD0
        # (ORA-29770, instance terminated by LMHB, 16.11). The lab does not need it (Kris): scheduler stopped,
        # oracle-tfa.service disabled (Restart=always would bring it back). Re-enable: systemctl enable --now oracle-tfa
        AHFCTL=/opt/oracle.ahf/bin/ahfctl
        if [ -x "$AHFCTL" ]; then
            if systemctl is-active -q oracle-tfa.service; then
                log "ahfctl stopahf -all on $NODE_NAME"
                run timeout 600 "$AHFCTL" stopahf -all || log "ahfctl stopahf -all rc=$? (systemctl stops the unit below)"
            fi
            run systemctl disable --now oracle-tfa.service
        else
            log "AHF not installed on $NODE_NAME ($AHFCTL missing)"
        fi
        if [ "$DRY_RUN" != "1" ] && systemctl is-active -q oracle-tfa.service; then die "oracle-tfa.service still active on $NODE_NAME"; fi
        ok "AHF/TFA off on $NODE_NAME"
        ;;
    *) die "phase: stage|cvuqdisk|install|root|config|fra|ahf" ;;
esac
