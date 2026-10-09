#!/bin/bash
# Run the math test harness in VICE (headless via xvfb) and verify results
set -e
cd "$(dirname "$0")"

acme test_math.asm

rm -f testdisk.d64
c1541 -format "test,64" d64 testdisk.d64 >/dev/null
c1541 testdisk.d64 -write testmath.prg testmath >/dev/null

pkill -x Xvfb 2>/dev/null || true
pkill -x x64 2>/dev/null || true
sleep 1

setsid nohup xvfb-run -a -s "-screen 0 800x600x24" x64 \
    -kernal /usr/share/vice/C64/kernal-901227-03.bin \
    -basic /usr/share/vice/C64/basic-901226-01.bin \
    -chargen /usr/share/vice/C64/chargen-901225-01.bin \
    -drive8type 1541 -device8 0 \
    -autostart testdisk.d64 -remotemonitor >/tmp/opencode/x64.log 2>&1 < /dev/null &

sleep 28
python3 verify_math.py
RC=$?

pkill -x Xvfb 2>/dev/null || true
pkill -x x64 2>/dev/null || true
exit $RC