#!/bin/bash
# ==============================================================================
# Tytul:        80_install_ogg.sh
# Opis:         Oprogramowanie GoldenGate 26ai Microservices na ggtgt (deployment oggtarget): wywoluje wspolny
#               /root/lab/shared/install_ogg.sh (instalacja lokalna w OGG_HOME + bundle patch).
# Description [EN]: GoldenGate 26ai Microservices software on ggtgt (deployment oggtarget): runs the shared
#               /root/lab/shared/install_ogg.sh (local install in OGG_HOME + bundle patch).
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - tgt/60_create_db.sh; lab.cmd ogg kopiuje ZIP-y GoldenGate
# Requirements [EN]: - tgt/60_create_db.sh; lab.cmd ogg copies the GoldenGate ZIPs
#
# Uzycie [PL]:       bash /root/lab/tgt/80_install_ogg.sh   (DRY_RUN=1 = podglad)
# Usage [EN]:        bash /root/lab/tgt/80_install_ogg.sh   (DRY_RUN=1 = preview)
# ==============================================================================
exec bash /root/lab/shared/install_ogg.sh "$@"
