# atari-homebrew

Atari 2600 homebrew experiments → `.a26` ROMs for the Atari Flashback 12 Gold.
Current game: **RAINSTORM** (`src/rainstorm.asm`, spec in `docs/GAMEPLAY.md`).

## Toolchain (Windows)
- **Stella 7.0** emulator/debugger — `winget install TheStellaTeam.Stella` → `C:\Program Files\Stella\Stella.exe`
- **DASM 2.20.17** assembler — `%LOCALAPPDATA%\Programs\dasm\dasm.exe` (on user PATH)
- `include/vcs.h`, `include/macro.h` — standard 2600 headers from the DASM repo
- **TIATracker 1.3** (music) — `%USERPROFILE%\OneDrive\Desktop\TIATracker\TIATracker.exe`; it saves songs in its own `songs\`
  folder, copy them to `music\`. Its `player\dasm\tt_player.asm` is checked in as `src/tt_player.asm` (Apache 2.0).

## Build & run
```powershell
.\build.ps1 rainstorm -Run      # src\rainstorm.asm -> bin\rainstorm.a26, opens in Stella
run.bat [name]                 # same thing, double-clickable (default: rainstorm)
.\tools\pftext.ps1 src\rainstorm_text.inc Title:RAINSTORM By:BY "Author:LUCAS YOUNG" Start:START   # title text tables
.\tools\pftext.ps1 src\rainstorm_over.inc "Over:GAME OVER"   # game-over text table
.\tools\gfx.ps1                 # clouds / rain / tree patterns / digits / bolt / player -> src\rainstorm_*.inc
python tools\ttt2asm.py src\rainstorm_music.inc "music\glafouk - miniblast.ttt" "music\game over - first revision.ttt" "music\second round.ttt"   # songs (SONG_* order)
```
Test builds: `dasm src\rainstorm.asm -f3 -Iinclude -Isrc -DAUTOSTART=1 -DBOLT_FRAMES=120 -obin\test.a26`
(skips the title screen, holds the lightning bolt on screen).

Stella: `` ` `` debugger · `Ctrl+R` reload ROM · `Tab` options · arrows + `Space` = joystick (up = jump) + fire · `F2` console Reset · `Esc` quits (no launcher).
Frame stats overlay: run with `-plr.stats 1`; a good NTSC ROM shows 261/262 lines / 60 Hz.

`tools/vcssim.py` (needs `pip install py65`) runs a ROM headless with scripted joystick input and reports any frame
that is not 262 lines plus the game variables, e.g.
`python tools\vcssim.py bin\rainstorm.a26 1300 3:F 1100-1150:R 1155:F` (fire at frame 3, hold right 1100-1150, fire at 1155).

## Layout
`src/` game sources · `include/` headers · `tools/` generators + simulator · `docs/` design · `bin/` build output (ignored)

The ROM is 8K, F8 bank-switched (hotspots `$FFF8`/`$FFF9`). Bank 1 (file offset `$1000`) is the game and is full: the main code
region ends at the `$FA00` text page, `PickTarget` lives after the graphics tables, the text screens in the bolt page, and a few
small tables in the player-sprite page; check `Bank 1 bytes free` and the listing when adding code. Bank 0 (`src/rainstorm_bank0.asm`)
holds the TIATracker player and the songs with ~2.9K to spare. Both banks start with the same `MusicPlay`/`MusicStart` stubs:
a stub does `sta BANK0`, the next instruction is fetched from bank 0 (`jsr` the routine, `sta BANK1`) and the `rts` is back in
bank 1. RAM is full too: the player's 8 state bytes end at `$F7` and the stack has `$F8-$FF`, 4 levels of `jsr`
(`tools/vcssim.py` prints the deepest use).

## Music
`music/*.ttt` are TIATracker songs, played by TIATracker's own player (`src/tt_player.asm`, 182 bytes, ~250 cycles per frame,
called first thing in VBLANK) from bank 0. `tools/ttt2asm.py` merges all songs into one data set (`src/rainstorm_music.inc`,
~900 bytes): shared instrument/percussion/pattern tables and one sequence table in which each song has a start position
(`SongC0`/`SongC1`, song number = argument order = `SONG_*` in `rainstorm.asm`). A song that ends without a goto gets a
pause + looping hold appended so it plays once and goes quiet; the last song number is pure silence. `MusicStart` (A = song)
restarts a song, `MusicPlay` advances it one frame. Limits of this player build: 7 instruments in total (a "pure combined"
instrument counts twice if it uses notes both below and above 32), 15 percussion, no slides, no overlay percussion, no
funk tempo (odd/even speeds). The tool asserts on all of these. The player source is written to be inlined, so bank 0 adds
the `rts` after it. The `.ttt` format, for reading a song by hand: note `type` 0 = hold, 1 = instrument, 2 = pause, 3 = percussion;
a "pure combined" instrument (waveform 16) plays note values 0-31 as AUDC 4 / AUDF = value and 32-63 as AUDC 12 / AUDF = value - 32;
the instrument's `frequencies` envelope entries are added to AUDF (TIA keeps the low 5 bits) and its `volumes` go to AUDV; a row
lasts `evenspeed` frames (the track's when `globalspeed` is true, else the pattern's).

## Flashback 12 Gold
Copy the `.a26` file to a USB storage device and plug it into the console. Stick to 2K/4K/standard bank-switched ROMs for compatibility.

## How RAINSTORM works
- Title → intro (clouds roll in, grey, cloud lightning, rain, two ground strikes) → main game → GAME OVER (player struck:
  scene freezes with the bolt, then a text screen; FIRE → title).
- Music: START begins `music/glafouk - miniblast.ttt`, which loops through the intro and the game; the strike on the player
  silences it, the GAME OVER and ROUND screens play their own tunes, and the title is silent (`TitleLogic` mutes both channels).
- Main game: 3 tree slots, trees of 2-4 blocks + 2-row canopy (level 1: all 4). Lightning (interval shrinks per level) hits the
  tallest object counted in blocks: tree trunks (canopy ignored), wood piles, the tower and the player (2, up to 4 when jumping;
  ties: tower, then leftmost tree, then leftmost pile, player last). The bolt hitting the player → game over; standing beside a struck object is safe.
  Struck tree → that many wood blocks piled at its base; struck tower or pile → loses 2 blocks. Player: joystick left/right; FIRE picks up a block at a pile, stacks it when at the right
  edge (tower zone), or plants the seed (held automatically once all trees are gone) in the nearest empty slot.
  Round clock: 30 s on round 1, +30 s per round (max 99, BCD). Clock at 0 or tower height ≥ goal (4 + level, max 8) → next level,
  announced by a 2 s "ROUND n" screen (`TextKernel`, shared with GAME OVER: text via `DrawText`, big digit via `DrawDigit`).
  Status line: level · tower · seconds left.
- Drawing (192 lines): 12 status (playfield digits) · 24 clouds (playfield scroll tables) · 80 sky with rain (playfield) + bolt (P1)
  · 48 tree band = 8 rows × 6 lines of playfield kept in RAM (`Rows`), rebuilt one object per frame during overscan
  (`Dirty` bitmask), player = P0 (VDELP0) in the bottom 3 rows · 32 grass.
- Random = 8-bit LFSR. Sprites are repositioned every frame in VBLANK (`PosObject`).

## Gotchas
- **RIOT timer:** always read `INTIM` right before writing `TIM64T` (see `SET_TIMER`). After a timer runs out it ticks once per cycle and wraps every 256 cycles; a write landing on a wrap cycle leaves it in that mode and the next wait ends ~64x early. Symptom: frame length depends on code layout (79/248/310 lines instead of 262).
- **DASM `.local` labels** are scoped by `SUBROUTINE`, not by the nearest global label; put `SUBROUTINE` before every routine that uses them. Branches are ±127 bytes: long routines need `jmp`. `macro.h`'s `SLEEP` crashed DASM 2.20.17 here; use explicit delay loops.
- **Playfield pixels are 4x wider than tall**; vertical detail is cheap, horizontal detail is not. Digit rows need ≥ 2 lines to be legible.
- **Budget:** ~2750 cycles of VBLANK and ~2170 of overscan per frame; anything heavier must be split across frames.
  `tools/vcssim.py` prints the busiest frame per timer.
- **Timer phase:** a RIOT timer should run out early in a scanline. If it runs out near the end of one, whether the
  `lda INTIM / bne` loop plus the following `sta WSYNC` still make that line depends on the cycle phase of the code
  before it, and the frame length flips between 262 and 263 when unrelated code changes (see `Overscan`).
- **F8 banking:** the bank-switch stubs must sit at the same addresses in both banks and `$FFF8`/`$FFF9` must hold no data
  in either bank (a read switches banks too). A power-up can land in bank 0, so both RESET vectors point at `sta BANK1`.
  Routines in bank 0 may only touch RAM and TIA, never bank-1 code or tables. `tools/vcssim.py` emulates F8 (`B0` starts in bank 0).
- **TIATracker player:** `tt_player.asm` has no `rts` (it is meant to be inlined) and `tt_cur_ins_c0/c1` must be zeroed when
  a song starts, or a channel keeps its old note (`TT_STARTS_WITH_NOTES = 0`).
- PowerShell: returning a single-element nested array from a function unrolls it — use `,$array`.

## Log
- 2026-10-12 — repo set up, Stella + DASM installed, `hello.asm` (rainbow bars) builds to 4K ROM.
- 2026-10-12 — `rainstorm.asm`: title screen (RAINSTORM / BY / LUCAS YOUNG / blinking START). Playfield text generator `tools/pftext.ps1`. Found and fixed the RIOT timer gotcha above.
- 2026-10-12 — Intro sequence and a first "lightning burns trees" scene; `tools/gfx.ps1`, `tools/vcssim.py`.
- 2026-10-13 — Gameplay per the updated `docs/GAMEPLAY.md`: tree heights, tallest-object lightning, wood piles, walking player, tower building, seed planting, levels. Status line. ~270 ROM bytes free.
- 2026-10-17 — `run.bat` launcher. Lightning now compares trunk blocks vs tower blocks (canopy ignored, tower wins ties) so the tower actually gets struck; wood piles are targets too and burn 2 logs per strike. Joystick UP jumps 2 blocks (player sprites zero-padded in their own page, drawn in band rows 3-7). Found and fixed the timer-phase gotcha above (overscan timer 34 ticks after a short delay). `tools/vcssim.py`: `U` key, per-timer cycle report. The player is a lightning target too (2 blocks, 4 at the jump peak, loses ties; standing beside a struck tree is safe) and being hit ends the game: frozen scene, then a GAME OVER screen (`src/rainstorm_over.inc`), FIRE → title. Round clock (30 s, +30 s per round) shown in the status line instead of the goal; at 0 the next round starts. The `PF_TEXT` macro became the `DrawText` routine (one copy instead of five expansions, ~150 bytes back). "ROUND n" screen between rounds (`src/rainstorm_round.inc`); GAME OVER shows the round reached. Space found by clearing the scene variables in one loop, merging `HidePlayer` into `HideBolt`, and dropping the `PlayerHi` table. GAME OVER jingle from `music/game over - first revision.ttt` and ROUND jingle from `music/second round.ttt` (hand-converted into the `Tune*` tables, see Music). To make room, the 4 unrolled cloud kernel rows became one loop over tables indexed offset*4 + row (`tools/gfx.ps1`), ~120 bytes back. Rules written up in `docs/GAMEPLAY.md`.
- 2026-10-17 — Background music: Glafouk's "Miniblast" (`music/glafouk - miniblast.ttt`, a TIATracker example song) plays from START through the intro and the game. That needs TIATracker's real player, so the ROM became 8K F8: bank 1 = the game, bank 0 = `src/tt_player.asm` + the songs, generated by the new `tools/ttt2asm.py` which merges all songs (the two jingles included, so the hand-converted `Tune*` tables are gone). RAM for the player's 8 state bytes came from packing the fire button into one byte (`Fire`), computing the goal from the level instead of storing it, and aliasing `tt_timer`/`tt_ptr` onto title-only and temporary variables; the stack keeps 8 bytes. `tools/vcssim.py`: F8 banking, deepest-stack report, audio register log (`A<from>-<to>`), RAM pokes (`<frame>P<addr>=<val>`).
