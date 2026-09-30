#!/usr/bin/env bash
# hwtest.sh 5|20 TEST... - regression runs on the MiSTer, logged and checked.
#
# Tests (run in the order given):
#   cpu      the CPU suite as boot.rom (tests/cpu/out/<target>/cputest.rom);
#            the output must equal tests/cpu/expected/ss{5,20}-core-hw.log
#            (--record overwrites that baseline instead)
#   netbsd   OpenBIOS, console on ttya, HD0 = netbsd11.raw: wait for
#            'login:', log in as root, run a command, check its output
#   solaris  OpenBIOS, console on ttya, HD0 = sol8.img (target 3): wait for
#            'console login:', log in as root, run a command, check its output
#
#   scripts/hwtest.sh 5 cpu netbsd
#   scripts/hwtest.sh 5 --bios bios/build/boot.rom netbsd   (a new OpenBIOS)
#
# The rbf must already be on the MiSTer (deploy.sh --no-launch). Logs go to
# sim/out/hw-<rev>-<test>.log. One capture at a time: a second reader on
# /dev/ttyS1 steals bytes from the first. Exit status: the number of tests
# that failed.
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
REV=$(rev_of "${1:-}") || exit 2; shift
RECORD=0
BIOS=""
TESTS=()
while [ $# -gt 0 ]; do
    a=$1; shift
    case "$a" in
        --record) RECORD=1 ;;
        --bios) BIOS=$1; shift ;;
        cpu|netbsd|solaris) TESTS+=("$a") ;;
        *) echo "unknown argument $a" >&2; exit 2 ;;
    esac
done
[ ${#TESTS[@]} -gt 0 ] || { echo "usage: $0 5|20 [--record] [--bios FILE] cpu|netbsd|solaris..." >&2; exit 2; }
case "$REV" in
    SunSparcStation5)  T=ss5-core; EXP=tests/cpu/expected/ss5-core-hw.log ;;
    SunSparcStation20) T=ss20;     EXP=tests/cpu/expected/ss20-core-hw.log ;;
esac
G="/media/fat/games/$GAMES_DIR"
mkdir -p sim/out
rsh() { ssh "${SSH_OPTS[@]}" "$DEV" "$@"; }
clean() { tr -d '\r' < "$1" | tr -cd '\11\12\40-\176' | grep -v '^$'; }

# Capture ttya for up to $2 seconds into $1 while launching the core; stop
# early when the log matches $3 (an extended regex).
run_capture() {
    local log=$1 secs=$2 until=$3
    scripts/console.sh --seconds "$secs" --out "$log" > /dev/null 2>&1 &
    local cp=$!
    sleep 3
    rsh "echo 'load_core /media/fat/$MISTER_CORE_FOLDER/$REV.rbf' > /dev/MiSTer_cmd"
    local t=0
    while kill -0 $cp 2>/dev/null; do
        if grep -a -q -E "$until" "$log" 2>/dev/null; then break; fi
        sleep 2; t=$((t + 2))
    done
    echo $cp
}
stop_capture() {   # the local ssh, and the remote cat it started
    kill "$1" 2>/dev/null
    # The MiSTer's busybox has no pkill. tty[S]1: a pattern that the awk
    # command line itself does not match.
    rsh "ps | awk '/cat \\/dev\\/tty[S]1/ {print \$1}' | xargs kill" 2>/dev/null
    wait "$1" 2>/dev/null
}
# Type on ttya; printf turns \r into Enter. No single quotes in $1.
type_tty() { rsh "printf '$1' > /dev/ttyS1"; }

scripts/machine.sh "$REV" > /dev/null || exit 1
FAILED=0
for t in "${TESTS[@]}"; do
    log="sim/out/hw-${REV#SunSparcStation}-$t.log"
    case "$t" in
    cpu)
        rsh "cp $G/boot.rom /tmp/boot.rom.hwtest"
        scp -q "${SSH_OPTS[@]}" "tests/cpu/out/$T/cputest.rom" "$DEV:$G/boot.rom" || exit 1
        cp=$(run_capture "$log" 90 'CPUTEST DONE')
        sleep 2; stop_capture "$cp"
        rsh "cp /tmp/boot.rom.hwtest $G/boot.rom"
        if [ "$RECORD" = 1 ]; then
            clean "$log" > "$EXP"; log "cpu: baseline recorded: $(grep 'CPUTEST DONE' "$EXP")"
        elif diff <(clean "$EXP") <(clean "$log") > "$log.diff"; then
            log "cpu: PASS, identical to $EXP ($(clean "$log" | grep 'CPUTEST DONE'))"
        else
            log "cpu: FAIL, differs from $EXP (diff in $log.diff; $(clean "$log" | grep 'CPUTEST DONE' || echo 'no CPUTEST DONE'))"
            FAILED=$((FAILED + 1))
        fi
        ;;
    netbsd|solaris)
        if [ "$t" = netbsd ]; then img=netbsd11.raw; want='login:'; secs=900
        else img=sol8.img; want='console login:'; secs=1800; fi
        if [ -n "$BIOS" ]; then
            scp -q "${SSH_OPTS[@]}" "$BIOS" "$DEV:$G/boot.rom" || exit 1
        else
            rsh "cp $G/openbios.rom $G/boot.rom"
        fi
        scripts/setopt.sh console=serial > /dev/null
        scripts/mount.sh --hd0 "$img" > /dev/null
        cp=$(run_capture "$log" "$secs" "$want")
        if ! grep -a -q "$want" "$log"; then
            stop_capture "$cp"
            log "$t: FAIL, no '$want' after ${secs}s; last line: $(clean "$log" | tail -1)"
            FAILED=$((FAILED + 1)); continue
        fi
        # Log in and run a command; the marker X-""42 prints X-42, which
        # the echoed command line cannot match (any shell, Bourne included).
        sleep 2; type_tty 'root\r'; sleep 8
        type_tty 'uname -sr; echo X-""42\r'; sleep 8
        stop_capture "$cp"
        if clean "$log" | grep -q '^X-42$'; then
            log "$t: PASS, login and shell on ttya ($(clean "$log" | grep -a -m1 -E '^(NetBSD|SunOS) [0-9]' || true))"
        else
            log "$t: FAIL, '$want' seen but the shell did not answer"
            FAILED=$((FAILED + 1))
        fi
        ;;
    esac
done
exit $FAILED
