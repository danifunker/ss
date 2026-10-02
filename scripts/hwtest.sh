#!/usr/bin/env bash
# hwtest.sh 5|20 TEST... - regression runs on the MiSTer, logged and checked.
#
# Tests (run in the order given):
#   cpu      the CPU suite as boot.rom (tests/cpu/out/<target>/cputest.rom);
#            the output must equal tests/cpu/expected/ss{5,20}-core-hw.log
#            (--record overwrites that baseline instead)
#   netbsd   OpenBIOS, console on ttya, HD0 = netbsd11.raw: wait for
#            'login:', log in as root, run a command, check its output
#   solaris  OpenBIOS, console on ttya, HD0 = sol8.img on the SS5,
#            sol8-ss20.img on the SS20 (its /dev links name the SS20's ESP
#            path, docs/disk-images.md; target 3): wait for
#            'console login:', log in as root, run a command, check its output
#   solaris-obp  the Sun PROM (--obp FILE, here; Sun's image is never in the
#            repo) with the NVRAM image --nvram NAME (default ss20-obp.nvr in
#            games/SunSparcStation/), HD0 = sol8-ss20.img: as solaris, plus
#            psrinfo, then 'init 0' so the disk is clean. The NVRAM image
#            must already hold diag-switch? false, auto-boot? true,
#            boot-device disk, input-device and output-device ttya (set them
#            once at the PROM's ok prompt: they are saved, TOD-6)
#   scsi     the SCSI path: tests/cpu/out/<target>/scsitest.rom as boot.rom
#            with two images of known content (tests/cpu/mkscsiimg.py, copied
#            to games/SunSparcStation/scsi-hd{0,1}.img) at HD0 (t3) and HD1
#            (t1); the output must equal
#            tests/cpu/expected/ss{5,20}-scsi-hw.log (--record writes it), and
#            HD0 must be unchanged afterwards (the write test restores it).
#            HD0 = the OS image again and HD1 empty afterwards
#
#   scripts/hwtest.sh 5 cpu netbsd
#   scripts/hwtest.sh 5 --bios bios/build/boot.rom netbsd   (a new OpenBIOS)
#   scripts/hwtest.sh 20 --obp scratch/ss20-obp225.rom solaris-obp
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
OBP=""
NVRAM=ss20-obp.nvr
TESTS=()
while [ $# -gt 0 ]; do
    a=$1; shift
    case "$a" in
        --record) RECORD=1 ;;
        --bios) BIOS=$1; shift ;;
        --obp) OBP=$1; shift ;;
        --nvram) NVRAM=$1; shift ;;
        cpu|netbsd|solaris|solaris-obp|scsi) TESTS+=("$a") ;;
        *) echo "unknown argument $a" >&2; exit 2 ;;
    esac
done
[ ${#TESTS[@]} -gt 0 ] || { echo "usage: $0 5|20 [--record] [--bios FILE] [--obp FILE] [--nvram NAME] cpu|netbsd|solaris|solaris-obp|scsi..." >&2; exit 2; }
case "$REV" in
    SunSparcStation5)  T=ss5-core; EXP=tests/cpu/expected/ss5-core-hw.log; OSIMG=sol8.img ;;
    SunSparcStation20) T=ss20;     EXP=tests/cpu/expected/ss20-core-hw.log; OSIMG=sol8-ss20.img ;;
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
    scsi)
        sexp=tests/cpu/expected/${T%-core}-scsi-hw.log
        python3 tests/cpu/build.py "$T" --main=scsitest > /dev/null || exit 1
        for n in 0 1; do
            python3 tests/cpu/mkscsiimg.py "sim/out/scsi-hd$n.img" "HD$n" || exit 1
            scp -q "${SSH_OPTS[@]}" "sim/out/scsi-hd$n.img" "$DEV:$G/scsi-hd$n.img" || exit 1
        done
        rsh "cp $G/boot.rom /tmp/boot.rom.hwtest"
        scp -q "${SSH_OPTS[@]}" "tests/cpu/out/$T/scsitest.rom" "$DEV:$G/boot.rom" || exit 1
        scripts/mount.sh --hd0 scsi-hd0.img --hd1 scsi-hd1.img > /dev/null
        scripts/setopt.sh console=serial > /dev/null
        cp=$(run_capture "$log" 120 'CPUTEST DONE')
        sleep 2; stop_capture "$cp"
        rsh "cp /tmp/boot.rom.hwtest $G/boot.rom"
        scripts/mount.sh --hd0 "$OSIMG" --hd1 "" > /dev/null
        scripts/setopt.sh console=serial > /dev/null
        same=$( [ "$(rsh "md5sum < $G/scsi-hd0.img" | cut -c1-32)" = "$(md5sum < sim/out/scsi-hd0.img | cut -c1-32)" ] && echo yes || echo no)
        if [ "$RECORD" = 1 ]; then
            clean "$log" > "$sexp"; log "scsi: baseline recorded: $(grep 'CPUTEST DONE' "$sexp"); HD0 unchanged: $same"
        elif [ "$same" = yes ] && diff <(clean "$sexp") <(clean "$log") > "$log.diff"; then
            log "scsi: PASS, identical to $sexp ($(clean "$log" | grep 'CPUTEST DONE'))"
        else
            log "scsi: FAIL (HD0 unchanged: $same; diff in $log.diff; $(clean "$log" | grep 'CPUTEST DONE' || echo 'no CPUTEST DONE'))"
            FAILED=$((FAILED + 1))
        fi
        ;;
    netbsd|solaris|solaris-obp)
        if [ "$t" = netbsd ]; then img=netbsd11.raw; want='login:'; secs=900
        elif [ "$t" = solaris ]; then want='console login:'; secs=1800
            if [ "$REV" = SunSparcStation20 ]; then img=sol8-ss20.img; else img=sol8.img; fi
        else img=sol8-ss20.img; want='console login:'; secs=1800; fi
        if [ "$t" = solaris-obp ]; then
            [ -f "$OBP" ] || { log "solaris-obp needs --obp FILE (the Sun PROM image)"; exit 2; }
            rsh "test -s $G/$NVRAM" || { log "no $G/$NVRAM on the MiSTer"; exit 2; }
            scp -q "${SSH_OPTS[@]}" "$OBP" "$DEV:$G/boot.rom" || exit 1
            scripts/mount.sh --nvram "$NVRAM" > /dev/null
        else
            # OpenBIOS formats any NVRAM image it does not recognise: run it
            # with the slot empty, so a saved Sun PROM image survives.
            scripts/mount.sh --nvram "" > /dev/null
            if [ -n "$BIOS" ]; then
                scp -q "${SSH_OPTS[@]}" "$BIOS" "$DEV:$G/boot.rom" || exit 1
            else
                rsh "cp $G/openbios.rom $G/boot.rom"
            fi
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
        if [ "$t" = solaris-obp ]; then
            type_tty 'psrinfo\r'; sleep 5
            type_tty 'sync; init 0\r'; sleep 90
            rsh "cp $G/openbios.rom $G/boot.rom"
        fi
        stop_capture "$cp"
        if clean "$log" | grep -q '^X-42$'; then
            log "$t: PASS, login and shell on ttya ($(clean "$log" | grep -a -m1 -E '^(NetBSD|SunOS) [0-9]' || true))$([ "$t" = solaris-obp ] && echo "; $(clean "$log" | grep -a -c 'on-line') CPUs on-line")"
        else
            log "$t: FAIL, '$want' seen but the shell did not answer"
            FAILED=$((FAILED + 1))
        fi
        ;;
    esac
done
exit $FAILED
