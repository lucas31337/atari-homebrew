# atari-homebrew

Atari 2600 homebrew experiments → `.a26` ROMs for the Atari Flashback 12 Gold.
Current game: **RAINSTORM** (`src/rainstorm.asm`, spec in `docs/GAMEPLAY.md`).

## Toolchain (Windows)
- **Stella 7.0** emulator/debugger — `winget install TheStellaTeam.Stella` → `C:\Program Files\Stella\Stella.exe`
- **DASM 2.20.17** assembler — `%LOCALAPPDATA%\Programs\dasm\dasm.exe` (on user PATH)
- `include/vcs.h`, `include/macro.h` — standard 2600 headers from the DASM repo

## Build & run
```powershell
.\build.ps1 rainstorm -Run      # src\rainstorm.asm -> bin\rainstorm.a26, opens in Stella
.\tools\pftext.ps1 src\rainstorm_text.inc Title:RAINSTORM By:BY "Author:LUCAS YOUNG" Start:START   # title text tables
.\tools\gfx.ps1                 # clouds / rain / trees / bolt / flame tables -> src\rainstorm_gfx.inc
```
Test builds: `dasm src\rainstorm.asm -f3 -Iinclude -Isrc -DAUTOSTART=1 -DBOLT_FRAMES=120 -obin\test.a26`
(skips the title screen, holds the lightning bolt on screen).

Stella: `` ` `` debugger · `Ctrl+R` reload ROM · `Tab` options · `Space` fire · `F2` console Reset · `Esc` quits (no launcher).
Frame stats overlay: run with `-plr.stats 1`; a good NTSC ROM shows 261/262 lines / 60 Hz.

`tools/vcssim.py` (needs `pip install py65`) runs a ROM headless and reports any frame that is not 262 lines,
e.g. `python tools\vcssim.py bin\rainstorm.a26 1100 3` (1100 frames, FIRE pressed at frame 3).

## Layout
`src/` game sources · `include/` headers · `tools/` generators + simulator · `docs/` design · `bin/` build output (ignored)

## Flashback 12 Gold
Copy the `.a26` file to a USB storage device and plug it into the console. Stick to 2K/4K/standard bank-switched ROMs for compatibility.

## How RAINSTORM is drawn
- Title: playfield text from generated tables (3x5 font, 40 px wide).
- Scene (192 lines): 8 sky · 24 clouds (playfield, scroll tables) · 88 sky with rain (playfield) + bolt (P1) · 40 trees (playfield in RAM so they can burn; flames = P0 with VDELP0) · 32 grass.
- Lightning in the clouds = sky/cloud colour flash. Strikes reposition P0/P1 during VBLANK. Random = 8-bit LFSR.

## Gotchas
- **RIOT timer:** always read `INTIM` right before writing `TIM64T` (see `SET_TIMER`). After a timer runs out it ticks once per cycle and wraps every 256 cycles; a write landing on a wrap cycle leaves it in that mode and the next wait ends ~64x early. Symptom: frame length depends on code layout (79/248/310 lines instead of 262).
- **DASM `.local` labels** are scoped by `SUBROUTINE`, not by the nearest global label; put `SUBROUTINE` before every routine that uses them. Branches are ±127 bytes: long routines need `jmp`.
- **Playfield pixels are 4x wider than tall**; vertical detail is cheap, horizontal detail is not.

## Log
- 2026-10-12 — repo set up, Stella + DASM installed, `hello.asm` (rainbow bars) builds to 4K ROM.
- 2026-10-12 — `rainstorm.asm`: title screen (RAINSTORM / BY / LUCAS YOUNG / blinking START), FIRE → placeholder, Reset → title. Playfield text generator `tools/pftext.ps1`. Found and fixed the RIOT timer gotcha above.
- 2026-10-12 — Gameplay per `docs/GAMEPLAY.md`: intro (clouds roll in, grey, cloud lightning, rain, two ground strikes) and main game (bolt strikes a random living tree, it burns to a stump; after all three → title). `tools/gfx.ps1` generates the graphics; `tools/vcssim.py` checks frame timing. 541 ROM bytes free.
