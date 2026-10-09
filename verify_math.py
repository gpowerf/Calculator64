#!/usr/bin/env python3
"""Verify the decimal math test harness: read the C64 screen through
VICE's remote monitor and compare against expected values.

The harness prints two 16-char results per row: tests at column 0 and
column 20, 10 rows total (16 compute tests + 4 entry/format tests).
"""
import sys
import time
import os

sys.path.insert(0, os.path.expanduser("~/Coding/C64DevKit/c64devk"))
from vice_bridge import ViceMonitor

SCR = 0x0400

# expected strings, right-aligned in a 16-char field
EXPECTED = [
    "            3.75",  # 1: 1.5 + 2.25
    "             0.3",  # 2: 0.1 + 0.2
    "             2.5",  # 3: 5 / 2
    "     0.333333333",  # 4: 1 / 3
    "     0.666666667",  # 5: 2 / 3 (rounded)
    "            -3.5",  # 6: -7 / 2
    "            17.5",  # 7: 7 * 2.5
    "            0.25",  # 8: 0.5 * 0.5
    "      0.00000001",  # 9: 1 - 0.999999999 (9-digit truncation)
    "      1000000000",  # 10: 999999999 + 1
    "      14.2857143",  # 11: 100 / 7
    "           ERROR",  # 12: 1 / 0
    "           -0.25",  # 13: -0.5 + 0.25
    "   1000000000000",  # 14: 1000000 * 1000000
    "               0",  # 15: 1.23 - 1.23
    "       100000000",  # 16: 99999999.9 + 0.1
    "             1.5",  # e1: entry "1.5"
    "           0.007",  # e2: entry ".007"
    "             42.",  # e3: entry "42."
    "             1.5",  # e4: commit "1.5"
]


def main():
    m = ViceMonitor()
    if not m.connect(timeout=20):
        print("FAIL: no monitor")
        return 1
    time.sleep(1.0)
    raw = m.read_memory(SCR, 400)

    def dec(b):
        if 0x20 <= b <= 0x7f:
            return chr(b)
        if 0x41 <= b <= 0x5a:
            return chr(b)
        if 0xc1 <= b <= 0xda:
            return chr(b - 0x80)
        return "?"

    failed = 0
    for i, exp in enumerate(EXPECTED):
        row, col = divmod(i * 20, 40)
        got = "".join(dec(b) for b in raw[row * 40 + col:row * 40 + col + 16])
        ok = got == exp
        if not ok:
            failed += 1
        print(f"{'PASS' if ok else 'FAIL'}  {i + 1:2d}: expected {exp!r} got {got!r}")
    print()
    if failed:
        print(f"RESULT: {failed}/{len(EXPECTED)} FAILED")
        return 1
    print(f"RESULT: all {len(EXPECTED)} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
