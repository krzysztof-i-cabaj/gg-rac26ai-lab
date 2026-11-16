#!/bin/bash
# ==============================================================================
# Tytul:        87_xag_register.sh
# Opis:         GoldenGate pod kontrola XAG, etap A: vip (VIP aplikacyjny oggvip przez appvipcfg,
#               uruchomiony na tym wezle, zanim oggca zwiaze z nim Service Managera), add (agctl add
#               goldengate dla Microservices z OGG_AGCTL_ARGS; --service_manager najpierw w formie MAA
#               "yes", przy bledzie skladni jako gola flaga; haslo oggadmin na stdin; potem start
#               i status). Powtarzalny: istniejacy VIP i zasob XAG zostaja.
# Description [EN]: GoldenGate under XAG control, stage A: vip (application VIP oggvip via appvipcfg,
#               started on this node before oggca binds the Service Manager to it), add (agctl add
#               goldengate for Microservices from OGG_AGCTL_ARGS; --service_manager first as the MAA
#               "yes" form, on a syntax error as a bare flag; oggadmin password on stdin; then start
#               and status). Re-runnable: an existing VIP and XAG resource are kept.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.3 (istnienie zasobu: NAME= / XAG-212, nie rc)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - root; vip: 85_install_xag.sh; add: 86_oggca_source.sh (deployment na ACFS)
# Requirements [EN]: - root; vip: 85_install_xag.sh; add: 86_oggca_source.sh (deployment on ACFS)
#
# Uzycie [PL]:       bash 87_xag_register.sh vip|add   (ggrac1; lab.cmd xag)
# Usage [EN]:        bash 87_xag_register.sh vip|add   (ggrac1; lab.cmd xag)
# ==============================================================================
source /root/lab/lib.sh

phase=${1:-}
G=$GRID_HOME/bin
AGCTL=$XAG_HOME/bin/agctl
LOG=$LOG_DIR/xag_register.log

case "$phase" in
    vip)
        if crs_res_exists "$OGG_VIP_NAME"; then
            ok "VIP resource $OGG_VIP_NAME exists"
        else
            # Public network number: ora.net1.network = 192.168.58.0 (checked on the lab 16.11 with
            # crsctl status resource -p -attr NAME,USR_ORA_SUBNET -w "TYPE = ora.network.type")
            log "appvipcfg create $OGG_VIP_NAME = $OGG_VIP on network 1"
            run "$G/appvipcfg" create -network=1 -ip="$OGG_VIP" -vipname="$OGG_VIP_NAME" -user=root
            # oracle (owner of the GoldenGate resource) may start and stop the VIP
            run "$G/crsctl" setperm resource "$OGG_VIP_NAME" -u user:oracle:r-x
        fi
        if "$G/crsctl" status resource "$OGG_VIP_NAME" 2>/dev/null | grep -q '^STATE=ONLINE'; then
            ok "$OGG_VIP_NAME ONLINE: $("$G/crsctl" status resource "$OGG_VIP_NAME" | sed -n 's/^STATE=//p')"
        else
            run "$G/crsctl" start resource "$OGG_VIP_NAME" -n "$NODE_NAME"
        fi
        ;;
    add)
        # agctl config returns rc 0 also for a missing instance (XAG-212 ... is not yet registered)
        if "$AGCTL" config goldengate "$OGG_SRC_DEPLOY" >/dev/null 2>&1 && ! "$AGCTL" config goldengate "$OGG_SRC_DEPLOY" 2>&1 | grep -q 'XAG-212'; then
            ok "XAG resource for $OGG_SRC_DEPLOY exists"
        elif [ "$DRY_RUN" = "1" ]; then
            echo "  DRY  agctl add goldengate $OGG_SRC_DEPLOY --service_manager [yes] $OGG_AGCTL_ARGS   (password on stdin)"
        else
            need_lab_pass
            added=0
            # The XAG Microservices template (MAA guide, docs check 15.11) has a bare flag; "yes" is the fallback
            for form in '' yes; do
                log "agctl add goldengate $OGG_SRC_DEPLOY --service_manager ${form:-(flag)} ..."
                set +e
                out=$(printf '%s\n' "$(ogg_admin_pass)" | "$AGCTL" add goldengate "$OGG_SRC_DEPLOY" --service_manager $form $OGG_AGCTL_ARGS 2>&1)
                rc=$?
                set -e
                echo "$out" | tee -a "$LOG"
                if [ "$rc" -eq 0 ]; then
                    echo "accepted form: --service_manager ${form:-(bare flag)}" | tee -a "$LOG"
                    added=1; break
                fi
                # Retry with "yes" only on a syntax complaint about the bare flag; any other error stops here
                [ -z "$form" ] && echo "$out" | grep -qiE 'service_manager|usage|invalid (option|value)|unrecognized|unexpected' || break
            done
            [ "$added" = "1" ] || die "agctl add goldengate failed (log: $LOG)"
        fi
        run "$AGCTL" config goldengate "$OGG_SRC_DEPLOY"
        if "$AGCTL" status goldengate "$OGG_SRC_DEPLOY" 2>/dev/null | grep -qi 'is running'; then
            ok "$("$AGCTL" status goldengate "$OGG_SRC_DEPLOY")"
        else
            log "agctl start goldengate $OGG_SRC_DEPLOY --node $NODE_NAME"
            if ! run "$AGCTL" start goldengate "$OGG_SRC_DEPLOY" --node "$NODE_NAME"; then
                pgrep -af "$OGG_HOME/bin/ServiceManager" >&2 || true
                die "agctl start failed. A Service Manager left running by oggca (above, outside XAG) blocks it: stop that process, then lab.cmd xag"
            fi
        fi
        run "$AGCTL" status goldengate "$OGG_SRC_DEPLOY"
        mark_done xag_register
        ;;
    *) die "phase: vip|add" ;;
esac
