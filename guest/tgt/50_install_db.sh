#!/bin/bash
# ==============================================================================
# Tytul:        50_install_db.sh
# Opis:         Oprogramowanie Oracle Database 26ai na ggtgt (single-instance, bez GI): wywoluje wspolny
#               /root/lab/shared/install_db.sh z ta sama faza (stage, install, root).
# Description [EN]: Oracle Database 26ai software on ggtgt (single-instance, no GI): runs the shared
#               /root/lab/shared/install_db.sh with the same phase (stage, install, root).
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - tgt/10_os_prereq.sh; lab.cmd tgt kopiuje ZIP-y
# Requirements [EN]: - tgt/10_os_prereq.sh; lab.cmd tgt copies the ZIPs
#
# Uzycie [PL]:       bash /root/lab/tgt/50_install_db.sh stage|install|root   (DRY_RUN=1 = podglad)
# Usage [EN]:        bash /root/lab/tgt/50_install_db.sh stage|install|root   (DRY_RUN=1 = preview)
# ==============================================================================
exec bash /root/lab/shared/install_db.sh "$@"
