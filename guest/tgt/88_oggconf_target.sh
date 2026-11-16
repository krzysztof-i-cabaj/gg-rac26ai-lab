#!/bin/bash
# ==============================================================================
# Tytul:        88_oggconf_target.sh
# Opis:         Replikacja po stronie celu (bloki 3 i 9 raportu): ggadmin w TGTPDB
#               (sql/04_tgt_users_pdb.sql, haslo tylko w kopii 600), rep1.prm w deploymencie,
#               sesja adminclient: alias ggtarget i setup_target.oby (heartbeat, tabela checkpoint,
#               Parallel Replicat, start). Hasla tylko w potoku adminclient.
# Description [EN]: Target side of the replication (report blocks 3 and 9): ggadmin in TGTPDB
#               (sql/04_tgt_users_pdb.sql, password only in a 600 copy), rep1.prm in the deployment,
#               adminclient session: alias ggtarget and setup_target.oby (heartbeat, checkpoint
#               table, Parallel Replicat, start). Passwords only in the adminclient pipe.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab.cmd ogg (oggtarget dziala), 88_oggconf_source.sh (trail et dochodzi przez dp1)
# Requirements [EN]: - lab.cmd ogg (oggtarget running), 88_oggconf_source.sh (trail et arrives via dp1)
#
# Uzycie [PL]:       bash /root/lab/tgt/88_oggconf_target.sh   (lab.cmd oggconf)
# Usage [EN]:        bash /root/lab/tgt/88_oggconf_target.sh   (lab.cmd oggconf)
# ==============================================================================
source /root/lab/lib.sh

USERS_SQL=$STAGE_DIR/04_tgt_users_pdb.sql
trap 'rm -f "$USERS_SQL"' EXIT   # the rendered file holds the password: gone on every exit, also after die
PRM_DIR=$OGG_TGT_HOME/etc/conf/ogg

log "ggadmin in $TGT_PDB (sql/04_tgt_users_pdb.sql)"
render_secret "$LAB_DIR/sql/04_tgt_users_pdb.sql" "$USERS_SQL" oracle
sysdba_file "$USERS_SQL" "$TGT_PDB"
run rm -f "$USERS_SQL"

log "rep1.prm -> $PRM_DIR"
run install -D -m 640 -o oracle -g oinstall "$LAB_DIR/ogg/rep1.prm" "$PRM_DIR/rep1.prm"

log "adminclient $OGG_TGT_DEPLOY: credential store, Replicat (setup_target.oby)"
adminclient_run "$OGG_TGT_URL" "$OGG_TGT_DEPLOY" "$LAB_DIR/ogg/setup_target.oby" "ggadmin@${NODE_NAME}.${LAB_DOMAIN}:1521/${TGT_PDB}|ggtarget"
mark_done oggconf_target
ok "target replication configured (check: 90_validate.sh repl)"
