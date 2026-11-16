#!/bin/bash
# ==============================================================================
# Tytul:        compare.sh
# Opis:         Odcisk danych replikowanych tabel w PDB tego wezla (SRCPDB na RAC, TGTPDB na ggtgt)
#               przez sql/10_compare.sql: wiersze "COMPARE <tabela> <wiersze> <hasz>" i "SEQ <inst> ...".
#               Host porownuje wyniki obu stron (Compare-CompareLines). Tylko odczyt.
# Description [EN]: Fingerprint of the replicated tables in this node's PDB (SRCPDB on the RAC,
#               TGTPDB on ggtgt) via sql/10_compare.sql: "COMPARE <table> <rows> <hash>" and "SEQ <inst> ..."
#               lines. The host compares both sides (Compare-CompareLines). Read-only.
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.1 (wiersze SEQ / SEQ lines)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - 05_demo_schema.sql w PDB
# Requirements [EN]: - 05_demo_schema.sql in the PDB
#
# Uzycie [PL]:       bash /root/lab/shared/compare.sh   (lab.cmd validate, testy T1-T10)
# Usage [EN]:        bash /root/lab/shared/compare.sh   (lab.cmd validate, tests T1-T10)
# ==============================================================================
source /root/lab/lib.sh

pdb=$SRC_PDB; [ "$NODE_ROLE" = "tgt" ] && pdb=$TGT_PDB
if [ "$DRY_RUN" = "1" ]; then echo "  DRY  [oracle] @10_compare.sql $pdb"; exit 0; fi
sysdba_file "$LAB_DIR/sql/10_compare.sql" "$pdb" | grep '^COMPARE '
# SEQ per instance: rows, distinct SEQ (rows - distinct = duplicates), min, max (film D1)
sysdba_query "alter session set container = $pdb;
select 'SEQ ' || inst || ' ' || count(*) || ' ' || count(distinct seq) || ' ' || nvl(min(seq), 0) || ' ' || nvl(max(seq), 0) from sales.load_events group by inst;"
