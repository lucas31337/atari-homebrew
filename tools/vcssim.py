"""Tiny Atari 2600 frame-timing simulator (CPU + WSYNC + RIOT timer only).

Counts scanlines per frame from VSYNC to VSYNC and reports anything that is
not 262.  Needs the py65 package:
    python -m venv .venv && .venv\\Scripts\\pip install py65
Usage: python tools/vcssim.py rom.a26 FRAMES [INPUT ...]
  INPUT tokens: "<frame>:<keys>" or "<from>-<to>:<keys>", keys from F (fire), L, R, U (up = jump);
  "A<from>-<to>" logs the TIA audio register writes (AUDC/AUDF/AUDV) in those frames;
  "B0" starts an 8K (F8) ROM in bank 0 instead of bank 1 (power-up bank is random on real hardware).
  "<frame>P<addr>=<value>" (hex) pokes a RAM byte at the start of that frame, e.g. 1200P9F=0.
  e.g. python tools/vcssim.py bin/rainstorm.a26 900 3:F 700-760:L 770:F
Prints the game variables (RAM $80..) and the deepest stack use at the end.
8K ROMs are F8 bank-switched (hotspots $1FF8/$1FF9).
"""
import sys
from py65.devices.mpu6502 import MPU

rom = open(sys.argv[1], 'rb').read()
FRAMES = int(sys.argv[2]) if len(sys.argv) > 2 else 5
events = []   # (first, last, keys)
audio = None  # (first, last) frames whose audio writes are logged
start_bank = 1
pokes = []    # (frame, address, value)
for tok in sys.argv[3:]:
    if tok == 'B0': start_bank = 0; continue
    if 'P' in tok and '=' in tok:
        f, rest = tok.split('P'); a, v = rest.split('='); pokes.append((int(f), int(a, 16), int(v, 16))); continue
    if tok.startswith('A'):
        a, b = (tok[1:].split('-') + [None])[:2]; audio = (int(a), int(b) if b else int(a)); continue
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
        s.pending = False; s.segs = []   # (frame, timer ticks, cycles from TIM64T to the first INTIM read)
        s.bank = start_bank if len(rom) > 0x1000 else 0; s.switches = 0; s.audio = []

    def cyc(s): return s.cpu.processorCycles
    def __len__(s): return 0x10000

    def __getitem__(s, a):
        if isinstance(a, slice): return [s[i] for i in range(*a.indices(0x10000))]
        a &= 0x1FFF
        if a & 0x1000:
            s.hotspot(a)
            return rom[(s.bank << 12) | (a & 0xFFF)]
        if a & 0x80:
            if a & 0x200:
                r = a & 0x7
                if r == 4:   # INTIM (no 1-cycle wrap mode: we never rely on it)
                    el = s.cyc() - s.timer_set
                    if s.pending: s.pending = False; s.segs.append((s.frame, s.timer_val, el))
                    t = el // s.timer_int
                    if t <= s.timer_val: return s.timer_val - t
                    return (-(el - (s.timer_val + 1) * s.timer_int) - 1) & 0xFF
                if r == 0:   # SWCHA: bit 7 right, bit 6 left (0 = pushed)
                    k = keys_at(s.frame); v = 0xFF
                    if 'R' in k: v &= 0x7F
                    if 'L' in k: v &= 0xBF
                    if 'U' in k: v &= 0xEF
                    return v
                return 0xFF  # SWCHB etc: nothing pressed
            return s.ram[a & 0x7F]
        if (a & 0x0F) == 0x0C:  # INPT4
            return 0x00 if 'F' in keys_at(s.frame) else 0x80
        return 0

    def hotspot(s, a):
        if len(rom) > 0x1000 and (a == 0x1FF8 or a == 0x1FF9):
            s.bank = a & 1; s.switches += 1

    def __setitem__(s, a, v):
        a &= 0x1FFF
        if a & 0x1000: s.hotspot(a); return
        if a & 0x80:
            if a & 0x200:
                if (a & 0x17) == 0x16:  # TIM64T
                    s.timer_set = s.cyc(); s.timer_val = v; s.timer_int = 64; s.pending = True
                return
            s.ram[a & 0x7F] = v; return
        r = a & 0x3F
        if r == 0x00:  # VSYNC
            on = bool(v & 2)
            if on and not s.vsync_on:
                s.frames.append((s.cyc() - s.frame_start) / 76); s.frame += 1
                s.frame_start = s.cyc()
                for f, a, v in pokes:
                    if f == s.frame: s.ram[a & 0x7F] = v
            s.vsync_on = on
        elif r == 0x02: s.wsync = True
        elif 0x15 <= r <= 0x1A and audio and audio[0] <= s.frame <= audio[1]:
            s.audio.append((s.frame, ('AUDC0', 'AUDC1', 'AUDF0', 'AUDF1', 'AUDV0', 'AUDV1')[r - 0x15], v))


m = Mem()
cpu = MPU(memory=m); m.cpu = cpu
cpu.pc = m[0xFFFC] | (m[0xFFFD] << 8)
min_sp = 0xFF
while m.frame <= FRAMES:
    cpu.step()
    if cpu.sp < min_sp and m.frame > 0: min_sp = cpu.sp   # (the power-on RAM clear pushes through the whole page)
    if m.wsync:
        m.wsync = False
        cpu.processorCycles += (76 - (cpu.processorCycles - m.frame_start) % 76) % 76

bad = [(i, n) for i, n in enumerate(m.frames) if i > 0 and n != 262]
print(f'{len(m.frames)} frames; first frame {m.frames[0]:.0f} lines (power-on)')
print('non-262 frames:', bad[:20] if bad else 'none')
# logic cycles per timer segment: the game's code between SET_TIMER and the wait loop
for ticks in sorted({t for _, t, _ in m.segs}):
    worst = max((el, f) for f, t, el in m.segs if t == ticks and f > 0)
    print(f'timer {ticks} ({ticks * 64} cycles): busiest frame {worst[1]} used {worst[0]} cycles')
for f, _ in bad[:5]:
    print(f'frame {f}:', ', '.join(f'timer {t}: {el}' for ff, t, el in m.segs if ff == f))
print('RAM $80-$BF:', ' '.join(f'{b:02X}' for b in m.ram[0:64]))
print(f'deepest stack: SP ${min_sp:02X} ({0xFF - min_sp} bytes)' + (f'; {m.switches} bank switches, ends in bank {m.bank}' if len(rom) > 0x1000 else ''))
if audio:
    last = None
    for f, reg, v in m.audio:
        if f != last: print(f'\nframe {f}:', end=''); last = f
        print(f' {reg}={v}', end='')
    print()
