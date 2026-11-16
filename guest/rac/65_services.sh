#!/bin/bash
# ==============================================================================
# Tytul:        65_services.sh
# Opis:         Serwisy PDB SRCPDB w klastrze: gg_srcpdb jako singleton (preferred ggcdb1,
#               available ggcdb2; za nim XAG przenosi GoldenGate) oraz srv_load1 (ggcdb1)
#               i srv_load2 (ggcdb2) dla generatora obciazenia; start i kontrola. Potem schematy
#               demo (sql/05_demo_schema.sql) i pakiet LOADGEN (sql/06_loadgen.sql). Powtarzalny.
# Description [EN]: SRCPDB services in the cluster: gg_srcpdb as a singleton (preferred ggcdb1,
#               available ggcdb2; XAG moves GoldenGate with it) plus srv_load1 (ggcdb1) and
#               srv_load2 (ggcdb2) for the load generator; start and check. Then the demo schemas
#               (sql/05_demo_schema.sql) and the LOADGEN package (sql/06_loadgen.sql). Re-runnable.
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab.cmd dbca (baza ggcdb dziala na obu wezlach)
# Requirements [EN]: - lab.cmd dbca (ggcdb running on both nodes)
#
# Uzycie [PL]:       bash /root/lab/rac/65_services.sh   (na ggrac1; lab.cmd services)
# Usage [EN]:        bash /root/lab/rac/65_services.sh   (on ggrac1; lab.cmd services)
# ==============================================================================
source /root/lab/lib.sh

# add_service <name> <srvctl options> : adds the service once; an existing one is left as it is
add_service() {
    local svc=$1; shift
    if as_user oracle "srvctl config service -db $SRC_DB -service $svc" >/dev/null 2>&1; then
        ok "service $svc exists"
    else
        log "srvctl add service $svc $*"
        as_user oracle "srvctl add service -db $SRC_DB -service $svc -pdb $SRC_PDB $*"
    fi
    as_user oracle "srvctl start service -db $SRC_DB -service $svc" 2>/dev/null || true
}

# Singleton for the per-PDB Extract: GoldenGate runs where this service runs (--use_local_services)
add_service "$GG_SERVICE" -preferred ${SRC_DB}1 -available ${SRC_DB}2
# One load service per instance: the generator writes from both threads at once
set -- $LOAD_SERVICES
add_service "$1" -preferred ${SRC_DB}1 -available ${SRC_DB}2
add_service "$2" -preferred ${SRC_DB}2 -available ${SRC_DB}1
for svc in $GG_SERVICE $LOAD_SERVICES; do as_user oracle "srvctl status service -db $SRC_DB -service $svc"; done

log "demo schemas HR, SALES in $SRC_PDB (sql/05_demo_schema.sql)"
sysdba_file "$LAB_DIR/sql/05_demo_schema.sql" "$SRC_PDB"
log "load generator SALES.LOADGEN in $SRC_PDB (sql/06_loadgen.sql)"
sysdba_file "$LAB_DIR/sql/06_loadgen.sql" "$SRC_PDB"
mark_done src_services
ok "services and demo schema ready"
