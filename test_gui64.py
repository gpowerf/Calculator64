#!/usr/bin/env python3
"""Interactive test of the Calculator64 app inside a real GUI64 cartridge.

Drives the app entirely through the VICE remote monitor:

- Mouse clicks: the GUI64 mouse is sprite 0 ($D000/$D001). Set the driver
  state ($77/$79) and the sprite, then set exit_code ($39) = 3
  (EC_LBTNPRESS) and resume with 'g'. A couple of RAM patches make the
  synthetic events reliable: the runtime keyboard scan's STA $53 ($0690)
  and the mouse driver's spurious EC_MOUSEMOVE writes ($08EB/$08FF). Both
  patches are only applied if the expected code bytes are present.
- Keyboard: set actkey ($53) to PETSCII, exit_code = 10 (EC_KEYPRESS),
  resume with 'g'.

Requires a GUI64 v2.1 cartridge image. Point the GUI64_CART environment
variable at it if it is not in the default location.
"""
import os
import re
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CART = os.environ.get("GUI64_CART",
                      "/tmp/opencode/GUI64/Binaries/v2.1/GUI64v2.1.win.crt")
APP = os.path.join(HERE, "calculator.gui")
ROMS = os.environ.get("VICE_ROMS", "/usr/share/vice/C64")

STR_DISPLAY = 0xB0D2
ZP_EXIT = 0x39
ZP_KEY = 0x53
SCAN_STA_ACTKEY = 0x0690   # runtime keyboard scan: A9 FF 85 0E 85 53

# Button centers in emulated screen char coords (xScr = (sprX-24)/8):
# window is at (8,1), 23x20; client area starts at row 3, col 8.
BUTTON_C = (11, 6)
BUTTON_SIGN = (16, 6)
BUTTON_DIV = (21, 6)
BUTTON_MUL = (26, 6)
BUTTON_7 = (11, 9)
BUTTON_8 = (16, 9)
BUTTON_9 = (21, 9)
BUTTON_SUB = (26, 9)
BUTTON_4 = (11, 12)
BUTTON_5 = (16, 12)
BUTTON_6 = (21, 12)
BUTTON_ADD = (26, 12)
BUTTON_1 = (11, 15)
BUTTON_2 = (16, 15)
BUTTON_3 = (21, 15)
BUTTON_EQ = (26, 15)
BUTTON_0 = (11, 18)
BUTTON_POINT = (16, 18)
# On the original v2.1 cart "3", "=", "0" are not clickable (the runtime
# scans only controls 0..15) -> they are driven via keyboard in this test.


class Mon:
    """VICE remote monitor over a raw socket, with reconnect support."""

    def __init__(self):
        self.s = None

    def connect(self, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            try:
                self.s = socket.create_connection(("127.0.0.1", 6510), timeout=2)
                self.s.settimeout(0.3)
                time.sleep(0.3)
                self.drain(0.5)
                return True
            except OSError:
                time.sleep(1)
        return False

    def drain(self, dur=1.0):
        data = b""
        end = time.time() + dur
        while time.time() < end:
            try:
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                data += chunk
            except socket.timeout:
                break
        return data

    def cmd(self, c, dur=0.4):
        self.s.sendall((c + "\n").encode())
        return self.drain(dur).decode(errors="replace")

    def poke(self, addr, val):
        return self.cmd(f"> {addr:04X} {val:02X}")

    def read(self, addr, n):
        out = bytearray()
        while len(out) < n:
            a = addr + len(out)
            r = self.cmd(f"m {a:04X} {(a + (n - len(out)) - 1):04X}")
            for line in r.split("\n"):
                mm = re.match(r">?C:([0-9a-fA-F]{4})\s+((?:[0-9a-fA-F]{2} ? ?)+)", line)
                if mm:
                    out += bytes.fromhex(mm.group(2).replace(" ", ""))
        return bytes(out[:n])

    def resume(self):
        self.cmd("g", 0.15)

    def quit(self):
        try:
            self.cmd("quit", 0.2)
        except OSError:
            pass
        if self.s:
            self.s.close()


def display_str(m):
    d = m.read(STR_DISPLAY, 16)
    out = []
    for b in d:
        if 0x20 <= b <= 0x3f:
            out.append(chr(b))
        elif 0x41 <= b <= 0x5a:
            out.append(chr(b))
        elif 0xc1 <= b <= 0xda:
            out.append(chr(b - 0x80))
        else:
            out.append("?")
    return "".join(out)


def set_mouse(m, cx, cy):
    m.poke(0x77, (cx * 8) & 0xFF)
    m.poke(0x78, 0)
    m.poke(0x79, (cy * 8) & 0xFF)
    m.poke(0x7A, 0)
    sprx = cx * 8 + 24
    m.poke(0xD000, sprx & 0xFF)
    m.poke(0xD001, cy * 8 + 50)
    m.poke(0xD010, 1 if sprx >= 256 else 0)   # sprite 0 X MSB


def click_button(m, pos):
    print(f">>> click {pos}")
    set_mouse(m, *pos)
    # the mouse driver fires a spurious EC_MOUSEMOVE when the sprite moves;
    # drain it (and any pending exit_code) before injecting the click
    _drain_exit(m, wait=1.0)
    m.poke(ZP_EXIT, 3)      # EC_LBTNPRESS
    m.cmd("g", 0.1)
    _wait_consumed(m)
    time.sleep(0.2)


def press_key(m, petscii):
    print(f">>> key {petscii:02x}")
    m.poke(ZP_KEY, petscii)
    m.poke(ZP_EXIT, 10)     # EC_KEYPRESS
    m.cmd("g", 0.1)
    _wait_consumed(m)
    time.sleep(0.15)


def _drain_exit(m, wait=0.4):
    """Wait until exit_code is (and stays) 0, so no stale event remains."""
    end = time.time() + wait
    while time.time() < end:
        if m.read(0x39, 1)[0] != 0:
            m.cmd("g", 0.1)
        time.sleep(0.05)
    m.poke(0x39, 0)


def _wait_consumed(m, timeout=3.0):
    """Wait until the GUI64 main loop has consumed exit_code ($39)."""
    end = time.time() + timeout
    while time.time() < end:
        if m.read(0x39, 1)[0] == 0:
            return True
        time.sleep(0.05)
    return False


def main():
    subprocess.run(["pkill", "-9", "-x", "x64sc"], check=False)
    time.sleep(2)

    def launch():
        subprocess.Popen(
            ["/usr/bin/x64sc", "-remotemonitor", "+sound",
             "-cartcrt", CART,
             "-kernal", f"{ROMS}/kernal-901227-03.bin",
             "-basic", f"{ROMS}/basic-901226-01.bin",
             "-chargen", f"{ROMS}/chargen-901225-01.bin",
             "-controlport1device", "3"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)

    m = Mon()
    if not m.connect(60):
        # VICE occasionally fails to open the monitor port; relaunch once
        print("first launch had no monitor, relaunching...")
        subprocess.run(["pkill", "-9", "-x", "x64sc"], check=False)
        time.sleep(3)
        launch()
        if not m.connect(60):
            print("FAIL: no monitor")
            return 1
    print("monitor connected, waiting for GUI64 desktop to settle...")
    time.sleep(8)
    print("GUI64 booted")

    r = m.cmd(f'l "{APP}" 0')
    print(r.strip().splitlines()[-2] if "\n" in r else r)
    m.cmd("> C000 20 00 B0 4C 03 04")
    m.cmd("g C000")
    time.sleep(2)

    disp = display_str(m)
    print(f"after launch: {disp!r}")
    if disp.strip() != "0":
        print("FAIL: app did not initialise display")
        m.quit()
        return 1

    # NOP the runtime keyboard scan's STA $53 so injected keys persist
    old = m.read(SCAN_STA_ACTKEY, 2)
    if old != b"\xea\xea":
        m.poke(SCAN_STA_ACTKEY, 0xEA)
        m.poke(SCAN_STA_ACTKEY + 1, 0xEA)
        print(f"patched $0690: {old.hex()} -> EAEA")

    # NOP the mouse driver's spurious EC_MOUSEMOVE writes ($39 = 5) so
    # synthetic clicks are never preempted by driver events
    for addr in (0x08EB, 0x08FF):
        if m.read(addr, 2) == b"\x85\x39":
            m.poke(addr, 0xEA)
            m.poke(addr + 1, 0xEA)
            print(f"patched ${addr:04x}: 8539 -> EAEA")

    results = []

    def check(name, expected):
        got = display_str(m).strip()
        ok = got == expected
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}: expected {expected!r} got {got!r}")

    # ----- mouse clicks + keyboard for the non-clickable keys -----
    click_button(m, BUTTON_C)
    click_button(m, BUTTON_1)
    click_button(m, BUTTON_8)
    press_key(m, 0x30)              # "0" (not clickable)
    check("mouse 1 8 + key 0", "180")
    click_button(m, BUTTON_SIGN)
    check("mouse +/- -> -180", "-180")
    press_key(m, 0x3D)              # "=" (not clickable)
    check("= keeps -180", "-180")
    press_key(m, 0x43)              # C
    press_key(m, 0x35)              # 5
    press_key(m, 0x2F)              # /
    press_key(m, 0x30)              # 0
    press_key(m, 0x3D)              # =
    check("key 5/0= -> ERROR", "ERROR")
    press_key(m, 0x43)              # C
    check("key C -> 0", "0")
    click_button(m, BUTTON_5)
    click_button(m, BUTTON_SIGN)
    click_button(m, BUTTON_ADD)   # commit -5
    click_button(m, BUTTON_4)
    click_button(m, BUTTON_ADD)   # chain: -5+4 = -1
    click_button(m, BUTTON_2)
    press_key(m, 0x3D)              # =
    check("mouse -5+4+2 -> 1", "1")
    click_button(m, BUTTON_C)
    click_button(m, BUTTON_1)
    click_button(m, BUTTON_ADD)
    click_button(m, BUTTON_2)
    press_key(m, 0x3D)              # =
    check("mouse 1+2= -> 3", "3")
    click_button(m, BUTTON_C)
    click_button(m, BUTTON_7)
    click_button(m, BUTTON_MUL)
    click_button(m, BUTTON_9)
    press_key(m, 0x3D)
    check("mouse 7*9= -> 63", "63")

    # ----- keyboard-only tests -----
    press_key(m, 0x43)              # C
    press_key(m, 0x39)              # 9
    press_key(m, 0x2D)              # -
    press_key(m, 0x34)              # 4
    press_key(m, 0xFC)              # RETURN
    check("key 9-4= -> 5", "5")
    press_key(m, 0x43)
    press_key(m, 0x31)              # 1
    press_key(m, 0x32)              # 2
    press_key(m, 0x2A)              # *
    press_key(m, 0x36)              # 6
    press_key(m, 0x3D)
    check("key 12*6= -> 72", "72")
    press_key(m, 0x43)
    press_key(m, 0x31)              # 1
    press_key(m, 0x30)              # 0
    press_key(m, 0x30)              # 0
    press_key(m, 0x2F)              # /
    press_key(m, 0x37)              # 7
    press_key(m, 0x3D)
    check("key 100/7= -> 14.2857143", "14.2857143")

    # ----- decimal tests -----
    press_key(m, 0x43); press_key(m, 0x31); press_key(m, 0x2E)
    press_key(m, 0x35); press_key(m, 0x2B); press_key(m, 0x32)
    press_key(m, 0x2E); press_key(m, 0x32); press_key(m, 0x35)
    press_key(m, 0x3D)
    check("key 1.5+2.25= -> 3.75", "3.75")
    press_key(m, 0x43); press_key(m, 0x31); press_key(m, 0x2F)
    press_key(m, 0x33); press_key(m, 0x3D)
    check("key 1/3= -> 0.333333333", "0.333333333")
    press_key(m, 0x43); press_key(m, 0x32); press_key(m, 0x2F)
    press_key(m, 0x33); press_key(m, 0x3D)
    check("key 2/3= -> 0.666666667", "0.666666667")
    press_key(m, 0x43); press_key(m, 0x2E); press_key(m, 0x31)
    press_key(m, 0x2B); press_key(m, 0x2E); press_key(m, 0x32)
    press_key(m, 0x3D)
    check("key .1+.2= -> 0.3", "0.3")
    click_button(m, BUTTON_C)
    click_button(m, BUTTON_POINT)
    click_button(m, BUTTON_5)
    check("mouse . 5 -> 0.5", "0.5")
    click_button(m, BUTTON_MUL)
    click_button(m, BUTTON_2)
    click_button(m, BUTTON_EQ)
    check("mouse 0.5*2= -> 1", "1")
    press_key(m, 0x43)              # C
    press_key(m, 0x31)              # 1
    press_key(m, 0x2F)              # /
    press_key(m, 0x33)              # 3
    press_key(m, 0x2A)              # *
    press_key(m, 0x33)              # 3
    press_key(m, 0x3D)              # =
    check("key chained 1/3*3 -> 0.999999999", "0.999999999")
    press_key(m, 0x43)              # C
    for _ in range(9):
        press_key(m, 0x39)          # 999999999
    press_key(m, 0x2A)              # *
    for _ in range(9):
        press_key(m, 0x39)          # 999999999
    press_key(m, 0x3D)              # =
    check("key big product -> 9.99999998E17", "9.99999998E17")

    m.quit()

    print()
    if all(results):
        print(f"RESULT: all {len(results)} interactive tests passed")
        return 0
    print(f"RESULT: {results.count(False)}/{len(results)} interactive tests FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
