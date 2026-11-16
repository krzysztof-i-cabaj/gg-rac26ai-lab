#!/bin/bash
# ==============================================================================
# Tytul:        70_acfs.sh
# Opis:         ACFS na deploymenty GoldenGate wg MAA (Task 4): prep (kazdy wezel: sterowniki ACFS
#               obslugiwane i zaladowane, punkt montowania), create (ggrac1: wolumen OGGVOL na +DATA,
#               mkfs tylko na pustym wolumenie, zasob srvctl filesystem, montowanie na jednym wezle,
#               wlasciciel oracle). Powtarzalny; istniejacy system plikow nigdy nie jest formatowany.
# Description [EN]: ACFS for the GoldenGate deployments per MAA (Task 4): prep (each node: ACFS
#               drivers supported and loaded, mount point), create (ggrac1: volume OGGVOL on +DATA,
#               mkfs only on an empty volume, srvctl filesystem resource, mounted on one node,
#               owner oracle). Re-runnable; an existing file system is never formatted.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1 (mkfs po rejestracji / mkfs after the registration check)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab.cmd services; jadro obslugiwane przez ACFS (KB129209, blokada z kickstartu)
# Requirements [EN]: - lab.cmd services; kernel supported by ACFS (KB129209, lock from the kickstart)
#
# Uzycie [PL]:       bash 70_acfs.sh prep   (kazdy wezel RAC);  bash 70_acfs.sh create   (ggrac1)
# Usage [EN]:        bash 70_acfs.sh prep   (each RAC node);    bash 70_acfs.sh create   (ggrac1)
# ==============================================================================
source /root/lab/lib.sh

phase=${1:-}
G=$GRID_HOME/bin

vol_device() { as_user grid "asmcmd volinfo -G $ACFS_DG $ACFS_VOLUME" 2>/dev/null | sed -n 's/^[[:space:]]*Volume Device:[[:space:]]*//p'; }

case "$phase" in
    prep)
        out=$("$G/acfsdriverstate" supported 2>&1 || true)
        echo "  $out"
        echo "$out" | grep -q 'ACFS-9200' || [ "$DRY_RUN" = "1" ] || die "ACFS not supported on kernel $(uname -r): see KB129209 (Os.Kernel / Os.UekRepo in lab.config.psd1)"
        if ! "$G/acfsdriverstate" loaded >/dev/null 2>&1; then
            log "ACFS drivers not loaded: acfsload start"
            run "$G/acfsload" start
        fi
        run mkdir -p "$OGG_DEPLOY_ROOT"
        ok "ACFS drivers ready, mount point $OGG_DEPLOY_ROOT"
        ;;
    create)
        if [ -z "$(vol_device)" ]; then
            log "asmcmd volcreate -G $ACFS_DG -s ${ACFS_SIZE_GB}G $ACFS_VOLUME"
            as_user grid "asmcmd volcreate -G $ACFS_DG -s ${ACFS_SIZE_GB}G $ACFS_VOLUME"
        else ok "volume $ACFS_VOLUME exists"; fi
        dev=$(vol_device)
        [ -n "$dev" ] || [ "$DRY_RUN" = "1" ] || die "no Volume Device for $ACFS_VOLUME (asmcmd volinfo -G $ACFS_DG $ACFS_VOLUME)"
        [ "$DRY_RUN" = "1" ] && dev=${dev:-/dev/asm/${ACFS_VOLUME,,}-NNN}
        # Format only an empty volume. A registered filesystem resource means mkfs ran already; else asmcmd
        # volinfo reports "Usage: ACFS" (libblkid has no ACFS prober: docs check 15.11; LAB: exact volinfo text).
        # mkfs refuses an existing ACFS (ACFS-01010) unless forced, and this script never forces it.
        if "$G/srvctl" config filesystem -volume "$ACFS_VOLUME" -diskgroup "$ACFS_DG" >/dev/null 2>&1; then
            ok "$dev formatted (filesystem resource registered)"
        elif as_user grid "asmcmd volinfo -G $ACFS_DG $ACFS_VOLUME" 2>/dev/null | grep -qi 'Usage: *ACFS'; then ok "$dev already ACFS (asmcmd volinfo)"
        else
            log "mkfs -t acfs $dev"
            run /sbin/mkfs -t acfs "$dev" || die "mkfs -t acfs $dev failed. If the volume already holds ACFS (ACFS-01010), nothing was formatted: register it (srvctl add filesystem -device $dev -volume $ACFS_VOLUME -diskgroup $ACFS_DG -path $OGG_DEPLOY_ROOT -user oracle -autostart RESTORE) and re-run lab.cmd acfs"
        fi
        if "$G/srvctl" config filesystem -volume "$ACFS_VOLUME" -diskgroup "$ACFS_DG" >/dev/null 2>&1; then
            ok "filesystem resource $OGG_ACFS_RES registered"
        else
            log "srvctl add filesystem $dev -> $OGG_DEPLOY_ROOT (user oracle, autostart RESTORE)"
            run "$G/srvctl" add filesystem -device "$dev" -volume "$ACFS_VOLUME" -diskgroup "$ACFS_DG" \
                -path "$OGG_DEPLOY_ROOT" -user oracle -autostart RESTORE
        fi
        # MAA: started on one node; XAG moves it together with GoldenGate (--filesystems)
        if "$G/srvctl" status filesystem -volume "$ACFS_VOLUME" -diskgroup "$ACFS_DG" 2>/dev/null | grep -q 'is mounted on nodes'; then
            ok "$OGG_ACFS_RES already mounted"
        else
            run "$G/srvctl" start filesystem -volume "$ACFS_VOLUME" -diskgroup "$ACFS_DG" -node "$NODE_NAME"
        fi
        "$G/srvctl" status filesystem -volume "$ACFS_VOLUME" -diskgroup "$ACFS_DG" || true
        if mountpoint -q "$OGG_DEPLOY_ROOT"; then
            run chown oracle:oinstall "$OGG_DEPLOY_ROOT"; run chmod 775 "$OGG_DEPLOY_ROOT"
        fi
        mark_done acfs
        ;;
    *) die "phase: prep|create" ;;
esac
