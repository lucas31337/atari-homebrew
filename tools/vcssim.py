"""Tiny Atari 2600 frame-timing simulator (CPU + WSYNC + RIOT timer only).

Counts scanlines per frame from VSYNC to VSYNC and reports anything that is
not 262, plus the first playfield write per frame.  Needs the py65 package:
    python -m venv .venv && .venv\\Scripts\\pip install py65
Usage: python tools/vcssim.py bin/rainstorm.a26 [frames] [fire_from_frame] [fire_frames]
"""
import sys
from py65.devices.mpu6502 import MPU

rom = open(sys.argv[1], 'rb').read()
FRAMES = int(sys.argv[2]) if len(sys.argv) > 2 else 5
FIRE_AT = int(sys.argv[3]) if len(sys.argv) > 3 else -1
FIRE_LEN = int(sys.argv[4]) if len(sys.argv) > 4 else 2


class Mem:
    def __init__(s):
        s.ram = bytearray(128); s.cpu = None
        s.wsync = False; s.timer_set = 0; s.timer_val = 0; s.timer_int = 64
        s.vsync_on = False; s.frame_start = 0; s.frames = []; s.frame = 0

    def cyc(s): return s.cpu.processorCycles
    def line(s): return (s.cyc() - s.frame_start) // 76
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
                return 0xFF  # SWCHB etc: nothing pressed
            return s.ram[a & 0x7F]
        if (a & 0x0F) == 0x0C:  # INPT4
            return 0x00 if (FIRE_AT >= 0 and FIRE_AT <= s.frame < FIRE_AT + FIRE_LEN) else 0x80
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
print('RAM $80-$9F:', ' '.join(f'{b:02X}' for b in m.ram[0:32]))
