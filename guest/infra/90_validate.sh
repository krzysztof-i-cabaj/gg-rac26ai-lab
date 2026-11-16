#!/bin/bash
# ==============================================================================
# Tytul:        90_validate.sh
# Opis:         Kontrole gginfra (tylko odczyt): SCAN zwraca 3 adresy, PTR wezlow, oggvip,
#               nazwy spoza labu przez NAT, chrony zsynchronizowany i udostepnia czas labowi.
#               Kod wyjscia 0 = wszystko ok; kazda kontrola to wiersz CHECK ok|FAIL.
# Description [EN]: gginfra checks (read-only): SCAN returns 3 addresses, node PTRs, oggvip,
#               non-lab names via NAT, chrony synced and serving the lab. Exit 0 = all ok;
#               each check prints a CHECK ok|FAIL line.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1 (firewalld off)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - po 10_dnsmasq.sh i 20_chrony.sh; bind-utils (dig)
# Requirements [EN]: - after 10_dnsmasq.sh and 20_chrony.sh; bind-utils (dig)
#
# Uzycie [PL]:       lab.cmd validate   (recznie: bash /root/lab/infra/90_validate.sh)
# Usage [EN]:        lab.cmd validate   (manual: bash /root/lab/infra/90_validate.sh)
# ==============================================================================
source /root/lab/lib.sh

q() { dig +short "$@" @127.0.0.1; }
sorted_scan=$(echo "$SCAN_IPS" | tr ' ' '\n' | sort | paste -sd' ')

check "dnsmasq active"                         systemctl is-active --quiet dnsmasq
check_eq "SCAN ${SCAN_NAME} = ${sorted_scan}"   "$sorted_scan" sh -c "dig +short ${SCAN_NAME}.${LAB_DOMAIN} @127.0.0.1 | sort | paste -sd' '"
i=0
for n in $RAC_NODES; do
    ip=$(echo "$RAC_IPS" | cut -d' ' -f$((i + 1)))
    check_eq "A ${n}"   "$ip"                   q "${n}.${LAB_DOMAIN}"
    check_eq "PTR ${ip}" "${n}.${LAB_DOMAIN}."  q -x "$ip"
    i=$((i + 1))
done
check_eq "A ${TGT_NAME}"     "$TGT_IP"          q "${TGT_NAME}.${LAB_DOMAIN}"
check_eq "A ${OGG_VIP_NAME}" "$OGG_VIP"         q "${OGG_VIP_NAME}.${LAB_DOMAIN}"
check "non-lab name via NAT (yum.oracle.com)"  sh -c "[ -n \"\$(dig +short yum.oracle.com @127.0.0.1)\" ]"
check "dig -x on the lab subnet is local"      sh -c "dig -x ${INFRA_IP} @127.0.0.1 | grep -q 'status: NOERROR'"

check "chronyd active"                         systemctl is-active --quiet chronyd
check "chrony Leap status : Normal"            sh -c "chronyc tracking | grep -q 'Leap status *: Normal'"
check "chrony allows ${PUBLIC_SUBNET}"         grep -q "^allow ${PUBLIC_SUBNET}" /etc/chrony.d/lab-server.conf
check "UDP 123 listening"                      sh -c "ss -lun | grep -q ':123 '"
check "firewalld off"                          sh -c "! systemctl is-active --quiet firewalld"
finish_checks
