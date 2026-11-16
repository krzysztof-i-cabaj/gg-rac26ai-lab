#!/bin/bash
# ==============================================================================
# Tytul:        85_install_xag.sh
# Opis:         XAG 10.2 (Oracle Grid Infrastructure Agents) samodzielnie w XAG_HOME na obu wezlach
#               RAC (xagsetup.sh --install --all_nodes jako wlasciciel GI). MAA: GoldenGate
#               Microservices wymaga XAG >= 10.2, instalacja poza GI home. Na koniec kontrola, ze
#               root i oracle widza agctl z XAG_HOME przed tym z GRID_HOME. Powtarzalny.
# Description [EN]: Standalone XAG 10.2 (Grid Infrastructure Agents) in XAG_HOME on both RAC nodes
#               (xagsetup.sh --install --all_nodes as the GI owner). MAA: GoldenGate Microservices
#               needs XAG >= 10.2 outside the GI home. Finally checks that root and oracle find agctl
#               from XAG_HOME before the GRID_HOME one. Re-runnable.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1 (unzip_once)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - xagpack.zip (Binaries.XagZip) w $STAGE_DIR na ggrac1; GI dziala, SSH grid miedzy wezlami
# Requirements [EN]: - xagpack.zip (Binaries.XagZip) in $STAGE_DIR on ggrac1; GI running, grid SSH between nodes
#
# Uzycie [PL]:       bash /root/lab/rac/85_install_xag.sh   (ggrac1; lab.cmd xag)
# Usage [EN]:        bash /root/lab/rac/85_install_xag.sh   (ggrac1; lab.cmd xag)
# ==============================================================================
source /root/lab/lib.sh

PKG=$STAGE_DIR/xag_pkg
LOG=$LOG_DIR/xag_install.log

installed_everywhere() {
    local n
    for n in $RAC_NODES; do
        as_user grid "ssh -o BatchMode=yes $n test -x $XAG_HOME/bin/agctl" >/dev/null 2>&1 || return 1
    done
}

if installed_everywhere; then
    ok "XAG already in $XAG_HOME on: $RAC_NODES"
else
    [ -n "$XAG_ZIP" ] && [ -f "$STAGE_DIR/$XAG_ZIP" ] || die "missing $STAGE_DIR/$XAG_ZIP (Binaries.XagZip; lab.cmd xag copies it)"
    unzip_once grid "$STAGE_DIR/$XAG_ZIP" "$PKG"
    log "xagsetup.sh --install --directory $XAG_HOME --all_nodes (log: $LOG)"
    set +e
    as_user grid "cd $PKG/xag && ./xagsetup.sh --install --directory $XAG_HOME --all_nodes" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    [ "$rc" -eq 0 ] || die "xagsetup.sh rc=$rc (log: $LOG). XAG_HOME must be empty on all nodes before a retry."
fi

as_user grid "$XAG_HOME/bin/agctl query releaseversion" || true
# Profiles from the kickstart put XAG_HOME/bin first; a GI agctl here would register an old agent
for u in root oracle; do
    got=$(runuser -l "$u" -c 'command -v agctl' 2>/dev/null || true)
    [ "$got" = "$XAG_HOME/bin/agctl" ] && ok "$u: agctl = $got" || [ "$DRY_RUN" = "1" ] || die "$u finds agctl at '$got', expected $XAG_HOME/bin/agctl (PATH in the profile)"
done
mark_done xag_sw
