#!/bin/bash
# ==============================================================================
# Tytul:        80_install_ogg.sh
# Opis:         Oprogramowanie GoldenGate 26ai Microservices na kazdym wezle RAC (osobno na ggrac1 i ggrac2): wywoluje wspolny
#               /root/lab/shared/install_ogg.sh (instalacja lokalna w OGG_HOME + bundle patch).
# Description [EN]: GoldenGate 26ai Microservices software on each RAC node (separately on ggrac1 and ggrac2): runs the shared
#               /root/lab/shared/install_ogg.sh (local install in OGG_HOME + bundle patch).
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - lab.cmd ogg kopiuje ZIP-y GoldenGate na ten wezel
# Requirements [EN]: - lab.cmd ogg copies the GoldenGate ZIPs to this node
#
# Uzycie [PL]:       bash /root/lab/rac/80_install_ogg.sh   (DRY_RUN=1 = podglad)
# Usage [EN]:        bash /root/lab/rac/80_install_ogg.sh   (DRY_RUN=1 = preview)
# ==============================================================================
exec bash /root/lab/shared/install_ogg.sh "$@"
