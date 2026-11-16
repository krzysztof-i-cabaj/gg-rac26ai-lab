#!/bin/bash
# ==============================================================================
# Tytul:        50_install_db.sh
# Opis:         Oprogramowanie Oracle Database 26ai na wezlach RAC (instalacja z ggrac1 na oba): wywoluje wspolny
#               /root/lab/shared/install_db.sh z ta sama faza (stage, install, root).
# Description [EN]: Oracle Database 26ai software on RAC nodes (install from ggrac1 to both): runs the shared
#               /root/lab/shared/install_db.sh with the same phase (stage, install, root).
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - GI dziala, rownowaznosc SSH oracle; lab.cmd db kopiuje ZIP-y
# Requirements [EN]: - GI running, oracle SSH equivalence; lab.cmd db copies the ZIPs
#
# Uzycie [PL]:       bash /root/lab/rac/50_install_db.sh stage|install|root   (DRY_RUN=1 = podglad)
# Usage [EN]:        bash /root/lab/rac/50_install_db.sh stage|install|root   (DRY_RUN=1 = preview)
# ==============================================================================
exec bash /root/lab/shared/install_db.sh "$@"
