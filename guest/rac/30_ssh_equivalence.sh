#!/bin/bash
# ==============================================================================
# Tytul:        30_ssh_equivalence.sh
# Opis:         Rownowaznosc SSH miedzy wezlami RAC dla grid i oracle (wymog gridSetup/runInstaller):
#               keygen (klucz RSA w formacie PEM), authorize (klucze obu wezlow z pliku, known_hosts
#               dla krotkich nazw, FQDN i adresow), verify (ssh bez hasla do kazdego wezla).
# Description [EN]: SSH equivalence between RAC nodes for grid and oracle (needed by gridSetup and
#               runInstaller): keygen (RSA key in PEM format), authorize (both nodes' keys from a
#               file, known_hosts for short names, FQDNs and addresses), verify (password-less ssh).
#
# Autor:        KCB Kris
# Data:         2026-11-14
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - uzytkownicy grid i oracle (kickstart); lab.ps1 zbiera klucze PUBKEY z obu wezlow
# Requirements [EN]: - grid and oracle users (kickstart); lab.ps1 collects PUBKEY lines from both nodes
#
# Uzycie [PL]:       bash 30_ssh_equivalence.sh keygen <user> | authorize <user> <plik_kluczy> | verify <user>
# Usage [EN]:        bash 30_ssh_equivalence.sh keygen <user> | authorize <user> <key_file> | verify <user>
# ==============================================================================
source /root/lab/lib.sh

mode=${1:-}; user=${2:-}
[ -n "$mode" ] && [ -n "$user" ] || die "usage: keygen|authorize|verify <user> [key_file]"
home=$(getent passwd "$user" | cut -d: -f6)
[ -n "$home" ] || die "no such user: $user"
peers=""
for n in $RAC_NODES; do peers="$peers $n $n.$LAB_DOMAIN"; done
peers="$peers $RAC_IPS"

case "$mode" in
    keygen)
        # PEM RSA: the installers' Java SSH client has rejected the OpenSSH key format before (INS-06006)
        if [ ! -f "$home/.ssh/id_rsa" ]; then
            as_user "$user" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -f ~/.ssh/id_rsa"
        fi
        [ "$DRY_RUN" = "1" ] || echo "PUBKEY $(cat "$home/.ssh/id_rsa.pub")"
        ;;
    authorize)
        keyfile=${3:-}
        [ -f "$keyfile" ] || die "missing key file: $keyfile"
        if [ "$DRY_RUN" = "1" ]; then echo "  DRY  authorize $user <- $(wc -l < "$keyfile") keys; keyscan:$peers"; exit 0; fi
        install -d -m 700 -o "$user" -g oinstall "$home/.ssh"
        touch "$home/.ssh/authorized_keys"
        while read -r k; do
            [ -n "$k" ] || continue
            grep -qxF "$k" "$home/.ssh/authorized_keys" || echo "$k" >> "$home/.ssh/authorized_keys"
        done < "$keyfile"
        # shellcheck disable=SC2086
        ssh-keyscan -T 5 $peers 2>/dev/null | sort -u > "$home/.ssh/known_hosts"
        chown "$user":oinstall "$home/.ssh/authorized_keys" "$home/.ssh/known_hosts"
        chmod 600 "$home/.ssh/authorized_keys"; chmod 644 "$home/.ssh/known_hosts"
        restorecon -R "$home/.ssh" || true
        ok "$user: $(wc -l < "$home/.ssh/authorized_keys") keys, known_hosts: $(wc -l < "$home/.ssh/known_hosts")"
        ;;
    verify)
        [ "$DRY_RUN" = "1" ] && { echo "  DRY  verify $user ->$peers"; exit 0; }
        for h in $peers; do
            check "$user@$NODE_NAME -> $h" as_user "$user" "ssh -o BatchMode=yes -o ConnectTimeout=5 $h true"
        done
        [ "$CHECK_FAILED" = "0" ] || die "SSH equivalence incomplete for $user"
        mark_done "ssh_$user"
        ;;
    *) die "unknown mode: $mode" ;;
esac
