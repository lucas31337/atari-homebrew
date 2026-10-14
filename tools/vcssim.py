"""Tiny Atari 2600 frame-timing simulator (CPU + WSYNC + RIOT timer only).

Counts scanlines per frame from VSYNC to VSYNC and reports anything that is
not 262.  Needs the py65 package:
    python -m venv .venv && .venv\\Scripts\\pip install py65
Usage: python tools/vcssim.py rom.a26 FRAMES [INPUT ...]
  INPUT tokens: "<frame>:<keys>" or "<from>-<to>:<keys>", keys from F (fire), L, R
  e.g. python tools/vcssim.py bin/rainstorm.a26 900 3:F 700-760:L 770:F
Prints the game variables (RAM $80..) at the end.
"""
import sys
from py65.devices.mpu6502 import MPU

rom = open(sys.argv[1], 'rb').read()
FRAMES = int(sys.argv[2]) if len(sys.argv) > 2 else 5
events = []   # (first, last, keys)
for tok in sys.argv[3:]:
    span, keys = tok.split(':')
    a, b = (span.split('-') + [None])[:2]
    events.append((int(a), int(b) if b else int(a) + 1, keys.upper()))


def keys_at(frame):
    k = ''
    for a, b, keys in events:
        if a <= frame <= b: k += keys
    return k


class Mem:
    def __init__(s):
        s.ram = bytearray(128); s.cpu = None
        s.wsync = False; s.timer_set = 0; s.timer_val = 0; s.timer_int = 64
        s.vsync_on = False; s.frame_start = 0; s.frames = []; s.frame = 0

    def cyc(s): return s.cpu.processorCycles
    def __len__(s): return 0x10000

    def __getitem__(s, a):
        if isinstance(a, slice): return [s[i] for i in range(*a.indices(0x10000))]
        a &= 0x1FFF
        if a & 0x1000: return rom[a & 0xFFF]
        if a & 0x80:
            if a & 0x200:
                r = a & 0x7
                if r == 4:   # INTIM (no 1-cycle wrap mode: we never rely on it)
                    el = s.cyc() - s.timer_set
                    t = el // s.timer_int
                    if t <= s.timer_val: return s.timer_val - t
                    return (-(el - (s.timer_val + 1) * s.timer_int) - 1) & 0xFF
                if r == 0:   # SWCHA: bit 7 right, bit 6 left (0 = pushed)
                    k = keys_at(s.frame); v = 0xFF
                    if 'R' in k: v &= 0x7F
                    if 'L' in k: v &= 0xBF
                    return v
                return 0xFF  # SWCHB etc: nothing pressed
            return s.ram[a & 0x7F]
        if (a & 0x0F) == 0x0C:  # INPT4
            return 0x00 if 'F' in keys_at(s.frame) else 0x80
        return 0

    def __setitem__(s, a, v):
        a &= 0x1FFF
        if a & 0x1000: return
        if a & 0x80:
            if a & 0x200:
                if (a & 0x17) == 0x16:  # TIM64T
                    s.timer_set = s.cyc(); s.timer_val = v; s.timer_int = 64
                return
            s.ram[a & 0x7F] = v; return
        r = a & 0x3F
        if r == 0x00:  # VSYNC
            on = bool(v & 2)
            if on and not s.vsync_on:
                s.frames.append((s.cyc() - s.frame_start) / 76); s.frame += 1
                s.frame_start = s.cyc()
            s.vsync_on = on
        elif r == 0x02: s.wsync = True


m = Mem()
cpu = MPU(memory=m); m.cpu = cpu
cpu.pc = rom[0xFFC] | (rom[0xFFD] << 8)
while m.frame <= FRAMES:
    cpu.step()
    if m.wsync:
        m.wsync = False
        cpu.processorCycles += (76 - (cpu.processorCycles - m.frame_start) % 76) % 76

bad = [(i, n) for i, n in enumerate(m.frames) if i > 0 and n != 262]
print(f'{len(m.frames)} frames; first frame {m.frames[0]:.0f} lines (power-on)')
print('non-262 frames:', bad[:20] if bad else 'none')
print('RAM $80-$BF:', ' '.join(f'{b:02X}' for b in m.ram[0:64]))
