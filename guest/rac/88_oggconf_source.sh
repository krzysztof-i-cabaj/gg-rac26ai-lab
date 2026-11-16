#!/bin/bash
# ==============================================================================
# Tytul:        88_oggconf_source.sh
# Opis:         Replikacja po stronie zrodla (bloki 2, 7, 8 raportu): ggadmin w SRCPDB
#               (sql/02_src_users_pdb.sql, haslo tylko w kopii 600), ext1.prm w deploymencie,
#               sesja adminclient: alias ggsource, setup_source.oby (supplemental, heartbeat,
#               REGISTER, Extract, start), alias ggtgt_dp i setup_path.oby (Distribution Path dp1).
#               Hasla tylko w potoku adminclient. Uruchamiac na wezle, na ktorym dziala GoldenGate.
# Description [EN]: Source side of the replication (report blocks 2, 7, 8): ggadmin in SRCPDB
#               (sql/02_src_users_pdb.sql, password only in a 600 copy), ext1.prm in the deployment,
#               adminclient session: alias ggsource, setup_source.oby (supplemental, heartbeat,
#               REGISTER, Extract, start), alias ggtgt_dp and setup_path.oby (Distribution Path dp1).
#               Passwords only in the adminclient pipe. Run on the node that runs GoldenGate.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab.cmd xag (oggsource dziala pod XAG), lab.cmd ogg (Receiver na ggtgt)
# Requirements [EN]: - lab.cmd xag (oggsource running under XAG), lab.cmd ogg (Receiver on ggtgt)
#
# Uzycie [PL]:       bash /root/lab/rac/88_oggconf_source.sh   (lab.cmd oggconf)
# Usage [EN]:        bash /root/lab/rac/88_oggconf_source.sh   (lab.cmd oggconf)
# ==============================================================================
source /root/lab/lib.sh

USERS_SQL=$STAGE_DIR/02_src_users_pdb.sql
trap 'rm -f "$USERS_SQL"' EXIT   # the rendered file holds the password: gone on every exit, also after die
PRM_DIR=$OGG_SRC_HOME/etc/conf/ogg

if [ "$DRY_RUN" != "1" ]; then
    mountpoint -q "$OGG_DEPLOY_ROOT" || die "GoldenGate does not run on $NODE_NAME ($OGG_DEPLOY_ROOT not mounted): run this on the node from 'agctl status goldengate $OGG_SRC_DEPLOY'"
fi

log "ggadmin in $SRC_PDB (sql/02_src_users_pdb.sql)"
render_secret "$LAB_DIR/sql/02_src_users_pdb.sql" "$USERS_SQL" oracle
sysdba_file "$USERS_SQL" "$SRC_PDB"
run rm -f "$USERS_SQL"

log "ext1.prm -> $PRM_DIR"
run install -D -m 640 -o oracle -g oinstall "$LAB_DIR/ogg/ext1.prm" "$PRM_DIR/ext1.prm"

log "adminclient $OGG_SRC_DEPLOY: credential store, Extract (setup_source.oby)"
adminclient_run "$OGG_SRC_URL" "$OGG_SRC_DEPLOY" "$LAB_DIR/ogg/setup_source.oby" "ggadmin@OGGSOURCE_PDB|ggsource"

log "adminclient $OGG_SRC_DEPLOY: Distribution Path dp1 -> $TGT_NAME (setup_path.oby, $OGG_PATH_PROTO)"
adminclient_run "$OGG_SRC_URL" "$OGG_SRC_DEPLOY" "$LAB_DIR/setup_path.oby" "$OGG_ADMIN_USER|ggtgt_dp"
mark_done oggconf_source
ok "source replication configured (check: 90_validate.sh repl)"
