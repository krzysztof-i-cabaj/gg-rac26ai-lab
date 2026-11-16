#!/bin/bash
# ==============================================================================
# Tytul:        86_oggca_target.sh
# Opis:         Deployment docelowy na ggtgt przez oggca.sh -silent: Service Manager ggsm01 i deployment
#               oggtarget na dysku lokalnym, potem rejestracja Service Managera jako uslugi systemd
#               (registerServiceManager.sh, jednostka OracleGoldenGate) i start. Gotowy deployment =
#               pominiety; czesciowy = instrukcja, bez kasowania.
# Description [EN]: Target deployment on ggtgt via oggca.sh -silent: Service Manager ggsm01 and
#               deployment oggtarget on a local disk, then the Service Manager registered as a systemd
#               service (registerServiceManager.sh, unit OracleGoldenGate) and started. Existing =
#               skipped; partial = instructions, nothing removed.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (plik rsp do konca rejestracji: oggca -checkpoint)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - tgt/80_install_ogg.sh
# Requirements [EN]: - tgt/80_install_ogg.sh
#
# Uzycie [PL]:       bash /root/lab/tgt/86_oggca_target.sh   (lab.cmd ogg)
# Usage [EN]:        bash /root/lab/tgt/86_oggca_target.sh   (lab.cmd ogg)
# ==============================================================================
source /root/lab/lib.sh

RSP=$STAGE_DIR/oggca_target.rsp
LOG=$LOG_DIR/oggca_target.log
UNIT=OracleGoldenGate

# registerServiceManager.sh runs "oggca.sh -checkpoint" with this same response file: keep it until the end
[ "$DRY_RUN" = "1" ] || trap 'rm -f "$RSP"' EXIT
run mkdir -p "$OGG_DEPLOY_ROOT"; run chown oracle:oinstall "$OGG_DEPLOY_ROOT"
if [ -d "$OGG_TGT_HOME/etc/conf" ] && [ -d "$OGG_SM_HOME/etc/conf" ]; then
    ok "Service Manager $OGG_SM and deployment $OGG_TGT_DEPLOY exist, oggca skipped"
elif [ -e "$OGG_SM_HOME" ] || [ -e "$OGG_TGT_HOME" ]; then
    cat >&2 <<EOF
$OGG_SM_HOME or $OGG_TGT_HOME exists without a complete deployment: an earlier oggca stopped half way.
Nothing was removed. Read: ls -t $OGG_HOME/cfgtoollogs/oggca/*.log | head -1
Then remove it with oggca (as oracle, CONFIGURATION_OPTION=REMOVE) or move both directories away,
and re-run lab.cmd ogg.
EOF
    die "partial deployment, see above"
else
    render_secret "$LAB_DIR/oggca_target.rsp" "$RSP" oracle
    log "oggca.sh -silent: $OGG_SM + $OGG_TGT_DEPLOY (log: $LOG)"
    set +e
    as_user oracle "cd /tmp && $OGG_HOME/bin/oggca.sh -silent -responseFile $RSP" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    check_rc "$rc" "oggca.sh $OGG_TGT_DEPLOY"
fi

# REGISTER_SERVICEMANAGER_AS_A_SERVICE=true leaves a root script in the Service Manager home
if systemctl list-unit-files "$UNIT.service" 2>/dev/null | grep -q "^$UNIT"; then
    ok "systemd unit $UNIT registered"
else
    reg=$OGG_SM_HOME/bin/registerServiceManager.sh
    [ -x "$reg" ] || [ "$DRY_RUN" = "1" ] || die "no $reg (oggca did not register the Service Manager as a service)"
    [ -f "$RSP" ] || render_secret "$LAB_DIR/oggca_target.rsp" "$RSP" oracle
    log "registerServiceManager.sh (systemd unit $UNIT)"
    run "$reg"
fi
run systemctl enable "$UNIT.service"
systemctl is-active --quiet "$UNIT.service" || run systemctl start "$UNIT.service"
mark_done oggca_target
ok "deployment $OGG_TGT_DEPLOY ready, Service Manager on $NODE_NAME:$OGG_SM_PORT"
