#!/bin/bash
# ==============================================================================
# Tytul:        run_step.sh
# Opis:         Uruchamia krok labu (skrypt z /root/lab/<rola>/) odlaczony od sesji SSH: setsid, wyjscie
#               do pliku /root/lab/run/<krok>.out, kod wyjscia do <krok>.rc, blokada flock na czas kroku.
#               Sesja SSH tylko sledzi plik (tail). Zerwane SSH nie zabija juz dbca/runInstaller przez
#               SIGPIPE w tee, a ponowne wywolanie w trakcie kroku podlacza sie do niego zamiast
#               startowac drugi instalator. Kod wyjscia = kod kroku.
# Description [EN]: Runs a lab step (a script from /root/lab/<role>/) detached from the SSH session:
#               setsid, output to /root/lab/run/<step>.out, exit code to <step>.rc, an flock lock for the
#               step's lifetime. The SSH session only follows the file (tail). A dead SSH session no longer
#               kills dbca/runInstaller through SIGPIPE in tee, and a second call while the step runs
#               attaches to it instead of starting a second installer. Exit code = the step's exit code.
#
# Autor:        KCB Kris
# Data:         2026-11-15
# Wersja:       1.1 (flock -o: demony kroku nie dziedzicza blokady / daemons do not inherit the lock)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - OL9 (util-linux: setsid, flock); wywoluje go lab.ps1 (Invoke-Guest) przez SSH jako root
# Requirements [EN]: - OL9 (util-linux: setsid, flock); called by lab.ps1 (Invoke-Guest) over SSH as root
#
# Uzycie [PL]:       bash /root/lab/run_step.sh <rola>/<skrypt.sh> [argumenty]   (np. rac/60_create_db.sh)
# Usage [EN]:        bash /root/lab/run_step.sh <role>/<script.sh> [arguments]
# ==============================================================================
set -uo pipefail
root=${LAB_ROOT:-/root/lab}
[ $# -ge 1 ] || { echo "usage: run_step.sh <role>/<script.sh> [args]" >&2; exit 2; }
step=$1; shift
[ -f "$root/$step" ] || { echo "run_step: no such step: $root/$step" >&2; exit 2; }

id=$(printf '%s' "$step $*" | tr -c 'A-Za-z0-9_.-' '_')
dir=$root/run; mkdir -p "$dir"
out=$dir/$id.out; rcf=$dir/$id.rc; lock=$dir/$id.lock

if flock -n "$lock" true; then
    rm -f "$rcf"; : > "$out"
    export RS_OUT=$out RS_RC=$rcf
    # Own session, no terminal, output to a file: nothing of the step writes into the SSH channel
    setsid flock -o "$lock" bash -c 'bash "$@" > "$RS_OUT" 2>&1 < /dev/null; echo $? > "$RS_RC"' run_step "$root/$step" "$@" \
        > /dev/null 2>&1 < /dev/null &
    # Wait until the step holds the lock (or already ended)
    for _ in $(seq 1 20); do flock -n "$lock" true || break; [ -f "$rcf" ] && break; sleep 0.5; done
else
    echo "== run_step: $step $* is still running (an earlier call started it): following its output"
fi

tail -n +1 -f "$out" & tp=$!
until flock -n "$lock" true; do sleep 2; done
sleep 1; kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
[ -f "$rcf" ] || { echo "run_step: $step ended without an exit code (killed?): see $out" >&2; exit 1; }
exit "$(cat "$rcf")"
