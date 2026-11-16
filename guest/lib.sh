#!/bin/bash
# ==============================================================================
# Tytul:        lib.sh
# Opis:         Wspolne funkcje skryptow na maszynach labu: log, tryb podgladu (DRY_RUN),
#               znaczniki wykonanych krokow (/root/lab/done), uruchamianie jako grid/oracle,
#               kontrole CHECK, czekanie na warunek. Wczytuje lab.env i ~/.lab_secrets.
# Description [EN]: Shared functions for lab guest scripts: logging, dry-run mode, done
#               markers (/root/lab/done), running as grid/oracle, CHECK lines, waiting for
#               a condition, SQL*Plus as sysdba. Loads lab.env and ~/.lab_secrets.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.9 (komentarz rsp_keys_check: przyklady kluczy 26ai / 26ai key examples)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - bash, root; /root/lab/lab.env (kopiuje lab.ps1)
# Requirements [EN]: - bash, root; /root/lab/lab.env (copied by lab.ps1)
#
# Uzycie [PL]:       source /root/lab/lib.sh   (pierwsza linia kazdego skryptu guest/)
# Usage [EN]:        source /root/lab/lib.sh   (first line of every guest/ script)
# ==============================================================================
set -euo pipefail

LAB_DIR=/root/lab
DONE_DIR=$LAB_DIR/done
LOG_DIR=$LAB_DIR/logs
mkdir -p "$DONE_DIR" "$LOG_DIR"

# shellcheck disable=SC1091
source "$LAB_DIR/lab.env"
# shellcheck disable=SC1091
[ -f /root/.lab_secrets ] && source /root/.lab_secrets

DRY_RUN=${DRY_RUN:-0}
CHECK_FAILED=0

log()  { echo "[$(date +%H:%M:%S)] [$NODE_NAME] $*"; }
ok()   { echo "  OK  $*"; }
warn() { echo " WARN $*"; }
die()  { echo "[$(date +%H:%M:%S)] [$NODE_NAME] ERROR: $*" >&2; exit 1; }

# run command... : executes; DRY_RUN=1 only prints.
run() {
    if [ "$DRY_RUN" = "1" ]; then echo "  DRY  $*"; else "$@"; fi
}

# step_done <id> : true if the step finished before (marker file exists).
step_done() { [ -f "$DONE_DIR/$1" ]; }
# mark_done <id> : records a finished step with a timestamp (skipped in dry-run).
mark_done() {
    [ "$DRY_RUN" = "1" ] && { echo "  DRY  mark_done $1"; return 0; }
    date '+%F %T' > "$DONE_DIR/$1"
}

# run_as <user> <script-file> [args] : runs a file with the user's login profile
# (ORACLE_HOME, PATH). The file is readable by the user; secrets come from its ~/.lab_secrets.
run_as() {
    local u=$1 f=$2; shift 2
    [ -f "$f" ] || die "run_as: no such file: $f"
    if [ "$DRY_RUN" = "1" ]; then echo "  DRY  [$u] bash $f $*"; return 0; fi
    chmod 755 "$f"
    runuser -l "$u" -c "bash $(printf '%q ' "$f" "$@")" </dev/null
}

# as_user <user> <command string> : short commands with the user's login profile.
as_user() {
    local u=$1; shift
    if [ "$DRY_RUN" = "1" ]; then echo "  DRY  [$u] $*"; return 0; fi
    runuser -l "$u" -c "$*" </dev/null
}

# mask_secret : stdin -> stdout with LAB_PASS replaced by ******** (also a last line without a newline).
# SQL*Plus prints the failing statement (IDENTIFIED BY "<pw>") even with ECHO OFF: every log goes through it.
mask_secret() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "${LAB_PASS:-}" ]; then printf '%s\n' "${line//"$LAB_PASS"/********}"; else printf '%s\n' "$line"; fi
    done
}

need_lab_pass() { [ -n "${LAB_PASS:-}" ] || die "LAB_PASS empty: /root/.lab_secrets missing (kickstart %post)"; }

# crs_res_exists <name> : the Clusterware resource exists. "crsctl status resource <missing>" returns rc 0
# with CRS-2613 (GI 23.26, lab 16.11): only the NAME= line proves it.
crs_res_exists_cmd() { "$GRID_HOME/bin/crsctl" status resource "$1" 2>/dev/null; }
crs_res_exists() { crs_res_exists_cmd "$1" | grep -q "^NAME=$1$"; }

# ogg_admin_pass : GoldenGate administrator password. GoldenGate 23.26 enforces a strong password policy (8-30 chars,
# a lowercase, an uppercase, a digit and one of - ! @ % & * . # _; INS-85080). LAB_PASS plus the missing classes.
ogg_admin_pass() {
    need_lab_pass
    local p=$LAB_PASS
    [[ $p =~ [-\!@%\&*.#_] ]] || p="${p}_"
    [[ $p =~ [A-Z] ]] || p="${p}A"
    [[ $p =~ [a-z] ]] || p="${p}a"
    [[ $p =~ [0-9] ]] || p="${p}1"
    [ ${#p} -le 30 ] || die "GoldenGate admin password would be ${#p} chars (max 30): use a shorter LAB_PASS"
    printf '%s' "$p"
}

# render_secret <template> <target> <owner> : @@LAB_PASS@@ -> password, file 600 owned by <owner>.
# Substitution happens inside bash (no sed): the password never appears in any process argv.
render_secret() {
    local tmpl=$1 out=$2 owner=$3 content
    [ -f "$tmpl" ] || die "render_secret: missing template $tmpl"
    if [ "$DRY_RUN" = "1" ]; then echo "  DRY  render $tmpl -> $out (600, $owner)"; return 0; fi
    need_lab_pass
    content=$(<"$tmpl")
    content=${content//@@OGG_ADMIN_PASS@@/$(ogg_admin_pass)}
    ( umask 077; printf '%s\n' "${content//@@LAB_PASS@@/$LAB_PASS}" > "$out" )
    chown "$owner": "$out"; chmod 600 "$out"
}

# check_rc <rc> <what> : Oracle installers return 0 = ok, 6 = ok with warnings (see the log).
check_rc() {
    case "$1" in
        0) ok "$2: rc=0" ;;
        6) warn "$2: rc=6 (warnings, see the log)" ;;
        *) die "$2: rc=$1 (logs: $INVENTORY/logs, $LOG_DIR)" ;;
    esac
}

# check "label" command... : prints CHECK ok|FAIL; finish_checks sets the exit code.
check() {
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then echo "CHECK ok   $label"
    else echo "CHECK FAIL $label"; CHECK_FAILED=1; fi
}
# check_eq "label" expected command... : compares the command output (trimmed) with expected.
check_eq() {
    local label=$1 want=$2 got; shift 2
    got=$("$@" 2>/dev/null | sed 's/[[:space:]]*$//' || true)
    if [ "$got" = "$want" ]; then echo "CHECK ok   $label"
    else echo "CHECK FAIL $label (want '$want', got '$got')"; CHECK_FAILED=1; fi
}
finish_checks() { exit "$CHECK_FAILED"; }

# uptime_s : whole seconds since boot. chrony steps the wall clock (makestep), not this one.
uptime_s() { local u; read -r u _ < /proc/uptime; echo "${u%%.*}"; }

# wait_until <seconds> "label" command... : retries every 5 s. The deadline counts uptime, not the
# wall clock: the first chrony sync after the install can step the clock by minutes.
wait_until() {
    local timeout=$1 label=$2; shift 2
    [ "$DRY_RUN" = "1" ] && { echo "  DRY  wait: $label"; return 0; }
    local deadline=$(( $(uptime_s) + timeout ))
    log "waiting up to ${timeout}s: $label"
    until "$@" >/dev/null 2>&1; do
        [ "$(uptime_s)" -lt "$deadline" ] || die "timed out: $label"
        sleep 5
    done
    ok "$label"
}

# write_if_changed <target> : stdin -> target only when content differs; returns 0 if changed.
# install -D creates missing parent directories (OL 9.8 ships no /etc/chrony.d).
write_if_changed() {
    local target=$1 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; return 1; fi
    if [ "$DRY_RUN" = "1" ]; then echo "  DRY  write $target"; rm -f "$tmp"; return 0; fi
    install -D -m 644 "$tmp" "$target"; rm -f "$tmp"
    return 0
}

# sysdba_query "<sql>" : as oracle, / as sysdba (ORACLE_SID from the profile); one value per
# line, trimmed, no headings. Read-only checks; also works in dry-run.
sysdba_query() {
    printf 'set heading off feedback off pagesize 0 verify off echo off linesize 400 trimout on\nwhenever sqlerror exit 1\n%s\nexit\n' "$1" |
        runuser -l oracle -c 'sqlplus -S -L / as sysdba' | sed -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
# sysdba_file <file.sql> [args] : runs a sql/ script as oracle, / as sysdba, log in $LOG_DIR.
# The scripts stop on the first error (WHENEVER SQLERROR EXIT), so rc != 0 = failure.
# oracle cannot enter /root (mode 550): the file runs from a private copy in /tmp.
sysdba_file() {
    local f=$1 tmp rc; shift
    [ -f "$f" ] || die "sysdba_file: no such file: $f"
    if [ "$DRY_RUN" = "1" ]; then echo "  DRY  [oracle] sqlplus / as sysdba @$f $*"; return 0; fi
    tmp=$(mktemp -d /tmp/labsql.XXXXXX)
    install -m 644 "$f" "$tmp/"; chown oracle "$tmp"; chmod 700 "$tmp"
    set +e
    runuser -l oracle -c "sqlplus -S -L / as sysdba @$(printf '%q ' "$tmp/$(basename "$f")" "$@")" </dev/null 2>&1 | mask_secret | tee -a "$LOG_DIR/$(basename "$f" .sql).log"
    rc=${PIPESTATUS[0]}
    set -e
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || die "$(basename "$f") rc=$rc (log: $LOG_DIR/$(basename "$f" .sql).log)"
}

# rsp_keys_check <our.rsp> <shipped sample> <label> : every key of ours must appear (also commented out) in
# the sample shipped with this release. Keys get renamed between releases (26ai: installOption, scanName, clusterNodes ...),
# so an unknown key stops the step before the installer, with what to fix. No sample: warning only.
rsp_keys_check() {
    local ours=$1 sample=$2 label=$3 unknown
    if [ ! -f "$sample" ]; then warn "$label: no sample $sample, keys not checked"; return 0; fi
    unknown=$(comm -23 <(grep -oE '^[A-Za-z_.]+=' "$ours" | sort -u) <(grep -oE '^#?[A-Za-z_.]+=' "$sample" | tr -d '#' | sort -u) || true)
    if [ -z "$unknown" ]; then ok "$label keys match the sample ($sample)"; return 0; fi
    die "$label: keys not in the sample of this release: $(echo $unknown). Compare with $sample and fix the template in the repo (response/ or ogg/), then re-run"
}

# unzip_once <user> <zip> <dir> : unzip as <user> into <dir> (-o: a re-run completes an interrupted extract).
# A marker in $DONE_DIR records the finished extract; one file inside <dir> appears early and proves nothing.
unzip_once() {
    local u=$1 zip=$2 d=$3 m
    m=unzip_$(printf '%s__%s' "$(basename "$zip")" "$d" | tr -c 'A-Za-z0-9_.-' '_')
    if step_done "$m"; then ok "$(basename "$zip") already unzipped in $d"; return 0; fi
    log "unzip $(basename "$zip") -> $d"
    as_user "$u" "mkdir -p $d && cd $d && unzip -q -o $zip" || die "unzip $zip -> $d failed (re-run repeats the extract)"
    mark_done "$m"
}

# pdb_ready <pdb> : 0 when the PDB is READ WRITE here; a MOUNTED PDB is opened (all instances) first.
# A dbca that failed after registering the database leaves no PDB: callers stop with the cleanup command.
pdb_ready() {
    local pdb=$1 q st
    if [ "${DRY_RUN:-0}" = "1" ]; then echo "  DRY  check $pdb READ WRITE"; return 0; fi
    q="select open_mode from v\$pdbs where name = upper('$pdb');"
    st=$(sysdba_query "$q" 2>/dev/null || true)
    if [ "$st" = "MOUNTED" ]; then
        sysdba_query "alter pluggable database $pdb open instances = all;" >/dev/null 2>&1 ||
            sysdba_query "alter pluggable database $pdb open;" >/dev/null 2>&1 || true
        st=$(sysdba_query "$q" 2>/dev/null || true)
    fi
    [ "$st" = "READ WRITE" ]
}

# adminclient_run <url> <deployment> <commands-file> [user|alias ...] : one adminclient session as
# oracle. CONNECT and each credential store alias get LAB_PASS inside this shell (printf builtin):
# the password travels through the pipe only, never argv or a file; echoed lines are masked in the
# output and the log. Comment lines (--) of the file are dropped. adminclient goes on after a
# failed command ("already exists" on a re-run): callers validate the result afterwards.
adminclient_run() {
    local url=$1 dep=$2 f=$3 c u a pw rc; shift 3
    if [ "$DRY_RUN" = "1" ]; then echo "  DRY  [oracle] adminclient: CONNECT $url DEPLOYMENT $dep; aliases: ${*:-none}; commands: $f"; return 0; fi
    need_lab_pass
    [ -r "$f" ] || die "adminclient_run: cannot read $f"
    if [ $# -gt 0 ]; then
        # DELETE first, own session: a re-run replaces the alias; a missing alias (first run) is OGG-15409, ignored
        {
            printf 'CONNECT %s DEPLOYMENT %s AS %s PASSWORD %s\n' "$url" "$dep" "$OGG_ADMIN_USER" "$(ogg_admin_pass)"
            for c in "$@"; do printf 'ALTER CREDENTIALSTORE DELETE USER %s ALIAS %s DOMAIN OracleGoldenGate\n' "${c%%|*}" "${c##*|}"; done
            printf 'EXIT\n'
        } | runuser -l oracle -c "$OGG_HOME/bin/adminclient" >/dev/null 2>&1 || true
    fi
    set +e
    {
        printf 'CONNECT %s DEPLOYMENT %s AS %s PASSWORD %s\n' "$url" "$dep" "$OGG_ADMIN_USER" "$(ogg_admin_pass)"
        for c in "$@"; do
            u=${c%%|*}; a=${c##*|}
            # the GoldenGate admin (path to the target) has its own password; database users keep LAB_PASS
            if [ "$u" = "$OGG_ADMIN_USER" ]; then pw=$(ogg_admin_pass); else pw=$LAB_PASS; fi
            printf 'ALTER CREDENTIALSTORE ADD USER %s PASSWORD %s ALIAS %s DOMAIN OracleGoldenGate\n' "$u" "$pw" "$a"
        done
        grep -v '^[[:space:]]*--' "$f"
        printf 'EXIT\n'
    } | runuser -l oracle -c "$OGG_HOME/bin/adminclient" 2>&1 |
        mask_secret | tee -a "$LOG_DIR/adminclient_$dep.log"
    rc=${PIPESTATUS[1]}
    set -e
    # adminclient exits 2 after any failed command ("already exists" on a re-run): the caller validates the result
    [ "$rc" -eq 0 ] || warn "adminclient $dep ($(basename "$f")): rc=$rc, a command failed (see above); validate checks the result"
    return 0
}
