; rainstorm.asm - RAINSTORM (8K F8, NTSC)  -- see docs/GAMEPLAY.md
;
; Bank 1 ($F000-$FFFF, file offset $1000) is the game; bank 0 holds the TIATracker
; music player and the songs (src/tt_player.asm, src/rainstorm_music.inc) and is
; only entered through the MusicPlay/MusicStart stubs at the start of both banks.
;
; States:  TITLE - "RAINSTORM / BY / LUCAS YOUNG" + blinking "START"; FIRE starts the intro
;          INTRO - blue sky and field; clouds roll in, turn grey, lightning in the clouds,
;                  rain starts, two lightning strikes hit the ground
;          (the song music/glafouk - miniblast.ttt starts with the intro)
;          MAIN  - three trees of height 2-4 (level 1: all 4).  Lightning strikes the
;                  tallest object, counted in blocks: the tallest tree trunk (canopy not
;                  counted), or the player's wood tower if it is at least as tall as every
;                  tree.  Wood piles count too, and the player (2 blocks, 4 at the top of a
;                  jump); ties: tower, tree, pile, player last.  A struck tree becomes a pile
;                  of wood blocks; a struck tower or pile loses 2 blocks.  A bolt that hits
;                  the player: GAME OVER (the scene freezes, then a text screen; FIRE
;                  returns to the title).  Standing beside a struck object is safe.
;                  The player walks (joystick), jumps 2 blocks high (UP), picks up blocks
;                  and stacks them on the tower at the right edge (FIRE).  When all trees are gone the player
;                  holds a seed; FIRE plants it in the nearest empty slot.  Tower height
;                  >= goal, or the round clock (30 s, +30 s per round) running out -> next
;                  level (new trees, random heights, faster lightning).
;                  Console RESET (F2 in Stella) returns to the title from anywhere.
;
; Frame:   3 VSYNC + 37 VBLANK + 192 visible + 30 overscan = 262 lines
;          (RIOT timers; see Overscan for why their run-out cycle must sit early in a line)
; Scene kernel, top to bottom (192 lines):
;          12 status (level / tower / seconds left) | 24 clouds (playfield, 4 rows) |
;          1+79 sky with rain (playfield) and the lightning bolt (P1) |
;          48 tree band: 8 rows of 6 lines, playfield from RAM (trees, wood piles, tower),
;          bolt (P1) and the player (P0, rows 3-7: stands in 5-7, jumps 2 rows) | 1+31 grass
        processor 6502
        include "vcs.h"
        include "macro.h"

STATE_TITLE     = 0
STATE_INTRO     = 1
STATE_MAIN      = 2
STATE_OVER      = 3             ; game over: scene frozen (Phase 0), then text (Phase 1)
STATE_ROUND     = 4             ; "ROUND n" text screen between rounds (Phase 1)

;--- colours (NTSC)
TITLE_COLOR     = $C8           ; green
AUTHOR_COLOR    = $9A           ; light blue
START_COLOR_ON  = $0E           ; white
START_COLOR_OFF = $04           ; dark grey
SKY_DAY         = $9C           ; light blue; darkens by 2 per grey step
CLOUD_WHITE     = $0E           ; darkens by 2 per grey step
FLASH_SKY       = $9E
FLASH_CLOUD     = $0E
RAIN_COLOR      = $9E
CANOPY_COLOR    = $C4
WOOD_COLOR      = $F2           ; trunks, piles, tower
GRASS_COLOR     = $C8
GRASS_DARK      = $C6
STATUS_COLOR    = $0C
PLAYER_COLOR    = $48           ; red
BOLT_COLOR_A    = $0E
BOLT_COLOR_B    = $1E

;--- scene kernel layout (must total 192)
STATUS_LINES    = 12            ; 1 blank + 5 digit rows x 2 lines + 1 blank
CLOUD_LINES     = 6             ; per cloud row, 4 rows
SKY_LINES       = 79            ; rain/bolt loop lines (+1 transition line)
BLOCK_LINES     = 6             ; per tree-band row
TREE_ROWS       = 8
TREE_LINES      = TREE_ROWS * BLOCK_LINES
PLAYER_ROW      = 5             ; tree-band row the player stands in (rows 5-7)
PLAYER_Y0       = PLAYER_ROW * BLOCK_LINES
JUMP_MAX        = 12            ; lines a jump rises (2 blocks): rows 3-7 draw the player
GRASS_DARK_LINES = 4
GRASS_LINES     = 192 - STATUS_LINES - CLOUD_LINES * 4 - 1 - SKY_LINES - TREE_LINES - 1 - GRASS_DARK_LINES

;--- scene timing (frames unless noted)
CLOUD_STEPS     = 20            ; scroll offsets until the clouds are fully in
CLOUD_STEP      = 12            ; frames per scroll step
GREY_STEPS      = 4
GREY_STEP       = 24
CLOUD_LIGHTNING = 180           ; lightning in the clouds before the rain starts
RAIN_ONLY       = 120           ; rain before the first ground strike
GROUND_STRIKES  = 2
STRIKE_GAP      = 60
FLASH_CHANCE    = 6             ; per-frame chance (out of 256) of a cloud flash
FLASH_SHORT     = 2
FLASH_STRIKE    = 5
        IFNCONST BOLT_FRAMES    ; dasm -DBOLT_FRAMES=120 holds the bolt on screen (for testing)
BOLT_FRAMES     = 8
        ENDIF
RAIN_SPEED      = 3             ; rain tile rows per frame
RAIN_ON         = 16            ; RainBase value when raining (tile rows 16-31)

;--- game
ROUND_SEC_STEP  = $30           ; BCD seconds: round 1 gets 30, each round 30 more (max 99)
TOWER_STRIKE_LOSS = 2           ; blocks burnt off the tower by a strike
PILE_STRIKE_LOSS = 2            ; blocks burnt off a wood pile by a strike
BOLT_MIN_X      = 19            ; the kernel's GRP1 write needs the bolt at x >= 19
OVER_FREEZE     = 90            ; frames the final scene stays before the GAME OVER text
SONG_MAIN       = 0             ; songs in rainstorm_music.inc, in tools/ttt2asm.py order:
SONG_OVER       = 1             ;   miniblast (intro + game), game over, round, silence
SONG_ROUND      = 2
SONG_NONE       = 3
ROUND_SHOW      = 120           ; frames the ROUND n screen stays
OVER_COLOR      = $44           ; red (GAME OVER); ROUND uses TITLE_COLOR
TEXT_SCALE      = 8             ; text screen: lines per font row
DIGIT_LINES     = 40            ; the big round number: 5 glyph rows x 8 lines
TEXT_TOP        = 40
TEXT_GAP        = 16
TEXT_BOTTOM     = 192 - TEXT_TOP - (TEXT_SCALE * 5 + 1) - TEXT_GAP - DIGIT_LINES
PLAYER_MAX      = 152
TOWER_ZONE      = 128           ; player x from which FIRE stacks a block
PILE_REACH      = 10            ; |player centre - pile centre| to pick up
PLANT_SPLIT_01  = 54            ; player centre below this plants in slot 0,
PLANT_SPLIT_12  = 102           ;   below this slot 1, else slot 2
CARRY_NONE      = 0
CARRY_BLOCK     = 1
CARRY_SEED      = 2
BANK0           = $FFF8         ; F8 bank-switch hotspots: any access selects that bank
BANK1           = $FFF9
TARGET_TOWER    = 3
TARGET_PILE     = 4             ; 4-6: wood pile at slot Target-4
TARGET_PLAYER   = 7
TARGET_NONE     = $FF

;------------------------------------------------------------------------------
        seg.u Vars
        org $80
State       ds 1
Frame       ds 1
Fire        ds 1                ; bit 7: button held, bit 6: new press this frame
StartColor  ds 1
tt_timer    = StartColor        ; music row timer (StartColor is title-only; the title is silent)
Rand        ds 1                ; 8-bit LFSR, never 0
Tmp         ds 1
Tmp2        ds 1
tt_ptr      = Tmp               ; the player's pointer: it runs first in VBLANK, when Tmp/Tmp2 are free
Row         ds 1                ; Rebuild: row base index
Cnt         ds 1                ; Rebuild: rows left
Obj         ds 1                ; Rebuild: tree slot
Phase       ds 1                ; sub-state within INTRO
Timer       ds 1                ; frame countdown for the current phase step
Count       ds 1                ; generic counter for the current phase
CountTick   = Timer             ; MAIN reuses the intro-only vars: frames left in this second
RoundSec    = Count             ;   and this round's length, BCD seconds
CloudOffset ds 1                ; 0..CLOUD_STEPS
CloudColor  ds 1
SkyColor    ds 1
CloudNow    ds 1                ; colours used this frame (after flash)
SkyNow      ds 1
RainBase    ds 1                ; 0 = no rain, RAIN_ON = rain
RainScroll  ds 1
RainIdx     ds 1                ; kernel start index into the rain tables
FlashTimer  ds 1
ShowTimer   = FlashTimer        ; STATE_ROUND reuses it: frames the screen stays (no flash runs then)
BoltTimer   ds 1
BoltX       ds 1
BoltPtr     ds 2                ; bolt graphics for the sky band (or Zeros)
BoltPtr2    ds 2                ; bolt graphics for the tree band (Zeros - end line)
PlayerPtr   ds 2                ; player sprite - PLAYER_Y0 (or hidden)
Target      ds 1                ; 0-2 tree, TARGET_TOWER, TARGET_PILE+0..2, TARGET_PLAYER, TARGET_NONE
TreeH       ds 3                ; trunk blocks per slot, 0 = no tree
Pile        ds 3                ; wood blocks lying at each slot
TowerH      ds 1
PlayerX     ds 1
Facing      ds 1                ; REFP0 value: 0 right, 8 left
CountSec    ds 1                ; seconds left in the round, BCD (status line)
JumpT       ds 1                ; 0 on the ground, else 1 + index into JumpTbl
Carry       ds 1                ; CARRY_*
Level       ds 1
NextStrike  ds 1
Dirty       ds 1                ; bits 0-2: redraw tree slot, bit 3: redraw tower (one per frame)
Rows        ds TREE_ROWS*6      ; per row: PF0L PF1L PF2L PF0R PF1R PF2R
RowColor    ds TREE_ROWS
StatusPF1   ds 5                ; status digits, top row first
StatusPF2   ds 5
        ; TIATracker player state (bank 0); tt_timer and tt_ptr are aliased above
tt_cur_pat_index_c0  ds 1       ; sequence table index
tt_cur_pat_index_c1  ds 1
tt_cur_note_index_c0 ds 1       ; row within the pattern
tt_cur_note_index_c1 ds 1
tt_envelope_index_c0 ds 1
tt_envelope_index_c1 ds 1
tt_cur_ins_c0        ds 1       ; current note byte (0 = none yet)
tt_cur_ins_c1        ds 1
        ; what is left, $F8-$FF, is the stack: 4 levels of jsr.  tools/vcssim.py
        ; prints the deepest use; TreeHeight inlines NextRand to stay within it.

;------------------------------------------------------------------------------
; SET_TIMER n -- start the RIOT timer for n*64 cycles.
; The INTIM read first is essential: once the previous timer has run out it
; counts 1 tick per cycle and wraps every 256 cycles, and a TIM64T write that
; lands exactly on a wrap cycle does not leave the 1-tick-per-cycle mode, so
; the new timer runs out ~64x too fast (verified in Stella 7.0: the frame
; length then depends on the cycle phase of the code).  Reading INTIM clears
; that state; the write a few cycles later cannot hit a wrap as well.
        MAC SET_TIMER
        lda INTIM
        lda #{1}
        sta TIM64T
        ENDM

;------------------------------------------------------------------------------
; TEXT label, scale -- draw 5-row asymmetric playfield text from the
; label_PF0L..label_PF2R tables (DrawText), each row 'scale' scanlines.
        MAC TEXT
        lda #<{1}_PF0L
        sta Tmp
        lda #>{1}_PF0L
        ldx #{2}
        jsr DrawText
        ENDM
; TEXTS label, scale -- same, for a table in the same page as the previous TEXT
        MAC TEXTS
        lda #<{1}_PF0L
        sta Tmp
        ldx #{2}
        jsr DrawTextLo
        ENDM


;------------------------------------------------------------------------------
; TREE_ROW row, player -- one tree-band row (BLOCK_LINES lines) from RAM with
;the bolt (P1) and, if player=1, the player (P0; VDELP0 makes the late write
; safe).  Y = line within the band.  Sprite reads must not cross a page: the
; player rows read sprite-JUMP_MAX .. sprite+17+JUMP_MAX, all blank-padded.
        MAC TREE_ROW
        ldx #BLOCK_LINES
.line   sta WSYNC
        lda (BoltPtr2),y        ; 5
        sta GRP1                ; 8
        lda RowColor+{1}        ; 11
        sta COLUPF              ; 14  (in HBLANK)
        lda Rows+{1}*6+0        ; 17
        sta PF0                 ; 20
        lda Rows+{1}*6+1        ; 23
        sta PF1                 ; 26
        lda Rows+{1}*6+2        ; 29
        sta PF2                 ; 32
        IF {2}
        lda (PlayerPtr),y       ; 37
        sta GRP0                ; 40  (buffered; shown from the next GRP1 write)
        ENDIF
        lda Rows+{1}*6+3        ; 43
        sta PF0                 ; 46  right PF0 (28..49)
        lda Rows+{1}*6+4        ; 49
        sta PF1                 ; 52  right PF1 (39..54)
        lda Rows+{1}*6+5        ; 55
        sta PF2                 ; 58  right PF2 (50..65)
        iny                     ; 60
        dex                     ; 62
        bne .line               ; 65
        ENDM

;------------------------------------------------------------------------------
        include "rainstorm_bank0.asm"   ; the music player and the songs (file offset 0)

;==============================================================================
; BANK 1: the game
;==============================================================================
        seg Code
        org $2000
        rorg $F000
        ; Bank-0 calls.  A stub switches banks in the middle of itself: the
        ; instruction after sta BANK0 is fetched from bank 0, where the same
        ; addresses hold jsr <routine> / sta BANK1, and the rts here follows.
MusicPlay                       ; once per frame: play the current song (tt_Player)
        sta BANK0
        ds 6
        rts
MusicStart                      ; A = SONG_*: start that song from its first row (MusicInit)
        sta BANK0
        ds 6
        rts
Reset   sta BANK1               ; both banks' RESET vector: bank 0's copy of this
        CLEAN_START             ; instruction brings a bank-0 power-up here
        lda #$80
        sta Fire                ; ignore a button already held at power-on
        lda #$A5
        sta Rand
        lda #1
        sta VDELP0
        IFCONST AUTOSTART       ; dasm -DAUTOSTART=1: skip the title (for testing)
        jsr InitScene
        ENDIF

        SUBROUTINE
MainLoop
        VERTICAL_SYNC
        SET_TIMER 43            ; 43*64 cycles ~= 37 lines of VBLANK

        lda State
        beq .quiet              ; the title is silent (TitleLogic mutes the channels)
        jsr MusicPlay
.quiet
        ;--- game logic (runs during VBLANK) ---
        inc Frame
        jsr ReadFire
        jsr NextRand
        lda State
        bne .play
        jsr TitleLogic
        jmp .logicDone
.play   jsr PlayLogic
.logicDone

.waitVBlank
        lda INTIM
        bne .waitVBlank
        sta WSYNC
        sta VBLANK              ; A = 0: beam on

        ;--- visible frame: 192 scanlines ---
        lda State
        bne .playKernel
        jsr TitleKernel
        jmp Overscan
.playKernel
        jsr SceneKernel

        SUBROUTINE
Overscan
        lda #2
        sta VBLANK              ; beam off (line 232, cycle ~12)
        ldx #4                  ; ~21 cycles so TIM64T is written at cycle ~42: 34*64
.phase  dex                     ; cycles then run out at cycle ~14 of line 261, leaving the
        bne .phase              ; wait loop + VERTICAL_SYNC's WSYNC most of that line.
        SET_TIMER 34            ; (35 ticks ran out at cycle ~52 of line 261 and whether
                                ; the frame was 262 or 263 lines depended on code phase.)
        jsr RebuildNext         ; redraw one changed object (runs in overscan)
.waitOverscan
        lda INTIM
        bne .waitOverscan
        jmp MainLoop

;------------------------------------------------------------------------------
; Edge-detect the left joystick button (INPT4 bit 7 is 0 while pressed):
; Fire bit 7 = held now, bit 6 = up last frame and held now (test with bit/bvc).
        SUBROUTINE
ReadFire
        lda INPT4
        and #$80
        eor #$80                ; $80 = held now
        bit Fire
        bmi .store              ; held last frame too: no new press
        cmp #$80
        bne .store
        ora #$40                ; new press
.store  sta Fire
        rts

; 8-bit maximal-length LFSR
        SUBROUTINE
NextRand
        lda Rand
        lsr
        bcc .noEor
        eor #$B4
.noEor  sta Rand
        rts

;==============================================================================
; TITLE
;==============================================================================
        SUBROUTINE
TitleLogic
        lda #0
        sta COLUBK
        sta AUDV0               ; no music on the title (also after GAME OVER / console RESET)
        sta AUDV1
        ldx #START_COLOR_ON     ; blink "START" every 16 frames
        lda Frame
        and #$10
        beq .on
        ldx #START_COLOR_OFF
.on     stx StartColor

        bit Fire
        bvc .stay
        jmp InitScene
.stay   rts

; Draw 5-row playfield text.  A = page of the tables, X = lines per row,
; Tmp = low byte of label_PF0L; PF1L/PF2L follow at +5/+10 and the right
; halves at +15 (pftext.ps1 layout, 30 bytes in one page).  Uses 5*X+1 lines
; and leaves the playfield cleared.  Borrows the sprite pointers, which only
; the scene kernel uses (InitScene resets them).
; Cycle counts are from the end of WSYNC; right-half writes must land after
; the left half is drawn and before the right half starts:
;   PF0 right 28..49, PF1 right 39..54, PF2 right 50..65
        SUBROUTINE
DrawText
        sta BoltPtr+1
        sta BoltPtr2+1
        sta PlayerPtr+1
DrawTextLo                      ; entry when the page bytes are already set
        stx Cnt                 ; lines per row
        lda Tmp
        sta BoltPtr             ; PF0 tables
        clc
        adc #5
        sta BoltPtr2            ; PF1 tables
        adc #5                  ; (carry clear: a table group never wraps a page)
        sta PlayerPtr           ; PF2 tables
        lda #4
        sta Tmp                 ; row
.row    ldx Cnt                 ; 72 from the previous row's last line: the row
.line   sta WSYNC               ; 75 change must fit in the line, so no extra work here
        ldy Tmp                 ; 3
        lda (BoltPtr),y         ; 8
        sta PF0                 ; 11
        lda (BoltPtr2),y        ; 16
        sta PF1                 ; 19
        lda (PlayerPtr),y       ; 24
        sta PF2                 ; 27
        tya                     ; 29
        adc #15                 ; 31  right-half index (carry is always clear here)
        tay                     ; 33
        lda (BoltPtr),y         ; 38
        sta PF0                 ; 41  right PF0 (28..49)
        lda (BoltPtr2),y        ; 46
        sta PF1                 ; 49  right PF1 (39..54)
        lda (PlayerPtr),y       ; 54
        sta PF2                 ; 57  right PF2 (50..65)
        dex                     ; 59
        bne .line               ; 62
        dec Tmp                 ; 66
        bpl .row                ; 69
        sta WSYNC
        lda #0
        sta PF0
        sta PF1
        sta PF2
        rts

TitleKernel
        lda #TITLE_COLOR
        sta COLUPF
        ldx #TOP_GAP
        jsr SkipLines
        TEXT Title, TITLE_SCALE
        lda #AUTHOR_COLOR
        sta COLUPF
        ldx #BY_GAP
        jsr SkipLines
        TEXTS By, BY_SCALE
        ldx #AUTHOR_GAP
        jsr SkipLines
        TEXTS Author, AUTHOR_SCALE
        lda StartColor
        sta COLUPF
        ldx #MID_GAP
        jsr SkipLines
        TEXTS Start, START_SCALE
        ldx #BOTTOM_GAP
        jmp SkipLines           ; tail call

; Title screen layout, top to bottom, in scanlines (must total 192).
; Each TEXT block takes scale*5+1 lines (+1 for the line that clears the playfield).
TITLE_SCALE     = 8             ; scanlines per font row
BY_SCALE        = 2
AUTHOR_SCALE    = 2
START_SCALE     = 5
TOP_GAP         = 12
BY_GAP          = 8             ; title -> "BY"
AUTHOR_GAP      = 3             ; "BY" -> author
MID_GAP         = 50            ; author -> "START"
TEXT_LINES      = (TITLE_SCALE + BY_SCALE + AUTHOR_SCALE + START_SCALE) * 5 + 4
BOTTOM_GAP      = 192 - TOP_GAP - BY_GAP - AUTHOR_GAP - MID_GAP - TEXT_LINES

;==============================================================================
; SCENE (INTRO + MAIN)
;==============================================================================
        SUBROUTINE
InitScene
        lda #0                  ; clear everything from Phase to the status digits
        ldx #StatusPF2+5-Phase-1 ; (what needs a value is set below or per level)
.clr    sta Phase,x
        dex
        bpl .clr
        lda #TARGET_NONE
        sta Target
        lda #CLOUD_WHITE
        sta CloudColor
        lda #SKY_DAY
        sta SkyColor
        lda #CLOUD_STEP
        sta Timer
        lda #76
        sta PlayerX
        lda #26
        sta BoltX
        jsr HideBolt            ; hides the player too
        lda #STATE_INTRO
        sta State
        lda #SONG_MAIN          ; the song plays from here through the game
        jmp MusicStart

; Enter the main game (from the intro)
        SUBROUTINE
InitMain
        lda #1
        sta Level
        lda #STATE_MAIN
        sta State
        ; fall into NewLevel

; Fresh trees, empty tower and piles, goal for the current level
        SUBROUTINE
NewLevel
        lda #0
        sta TowerH
        sta Carry
        ldx #2
.slot   lda #0
        sta Pile,x
        jsr TreeHeight
        sta TreeH,x
        dex
        bpl .slot
        ; round clock: 30 s on level 1, 30 s more per level, max 99 (BCD)
        lda Level
        cmp #1
        bne .clock
        lda #0
        sta RoundSec
.clock  sed
        clc
        lda RoundSec
        adc #ROUND_SEC_STEP
        bcc .clockOk
        lda #$99
.clockOk
        cld
        sta RoundSec
        sta CountSec
        lda #60
        sta CountTick
        jsr StrikeInterval
        lda #$0F
        sta Dirty
        lda #PLAYER_COLOR
        sta COLUP0
        lda Level
        cmp #1
        beq .first
        lda #STATE_ROUND        ; "ROUND n" screen before play resumes (TextLogic)
        sta State
        lda #1
        sta Phase               ; text phase (as in STATE_OVER)
        lda #SONG_ROUND
        jsr MusicStart
        lda #ROUND_SHOW
        sta ShowTimer
.first  rts

; A = height for a new tree (4 on level 1, else 2..4), preserves X
        SUBROUTINE
TreeHeight
        lda Level
        cmp #1
        bne .random
        lda #4
        rts
.random lda Rand                ; NextRand, inlined: NewLevel is already 3 calls deep
        lsr
        bcc .noEor
        eor #$B4
.noEor  sta Rand
        and #3
        tay
        lda HeightTbl,y
        rts

; NextStrike = frames between strikes for this level
        SUBROUTINE
StrikeInterval
        ldy Level
        cpy #8
        bcc .ok
        ldy #8
.ok     lda IntervalTbl-1,y
        sta NextStrike
        rts

        SUBROUTINE
HideBolt                                ; also hides the player (MAIN's PlayerLogic
        lda #<Zeros                     ; sets PlayerPtr again later in the same frame)
        sta BoltPtr
        sta BoltPtr2
        lda #<(Zeros+JUMP_MAX-PLAYER_Y0) ; rows 3-7 then read Zeros+0..29
        sta PlayerPtr
        lda #>Zeros
        sta BoltPtr+1
        sta BoltPtr2+1
        sta PlayerPtr+1
        rts


; Occasionally flash the sky and clouds (lightning inside the clouds).
        SUBROUTINE
RandomFlash
        lda FlashTimer
        bne .done
        lda Rand
        cmp #FLASH_CHANCE
        bcs .done
        lda #FLASH_SHORT
        sta FlashTimer
.done   rts

;------------------------------------------------------------------------------
; Position player X (0 or 1) at pixel A.  Takes one scanline; the caller must
; strobe HMOVE right after the next WSYNC.
        SUBROUTINE
PosObject
        sec
        sta WSYNC
.div    sbc #15
        bcs .div
        eor #7
        asl
        asl
        asl
        asl
        sta HMP0,x
        sta RESP0,x
        rts

; Start a lightning strike: A = bolt x, Tmp = tree-band line where it ends
; (0 = top of the band, TREE_LINES = the ground).
        SUBROUTINE
StartStrike
        sta BoltX
        lda #BOLT_FRAMES
        sta BoltTimer
        lda #FLASH_STRIKE
        sta FlashTimer
        lda #<BoltGfx
        sta BoltPtr
        lda #>BoltGfx
        sta BoltPtr+1
        lda #<Zeros             ; BoltBand (48 rows) sits right before Zeros, so
        sec                     ; Zeros-end gives 'end' rows of bolt then blanks
        sbc Tmp
        sta BoltPtr2
        lda #>Zeros
        sbc #0
        sta BoltPtr2+1
        rts

;------------------------------------------------------------------------------
        SUBROUTINE
PlayLogic
        lda SWCHB               ; bit 0 is 0 while RESET is pressed
        lsr
        bcs .noReset
        lda #STATE_TITLE
        sta State
        rts
.noReset
        lda State
        cmp #STATE_OVER
        bcc .scene
        jmp TextLogic           ; GAME OVER / ROUND n
.scene

        ; bolt colour flickers white/yellow
        ldx #BOLT_COLOR_A
        lda Frame
        and #1
        beq .bc
        ldx #BOLT_COLOR_B
.bc     stx COLUP1

        ; rain scroll -> kernel start index
        lda RainScroll
        clc
        adc #RAIN_SPEED
        sta RainScroll
        and #15
        ora RainBase
        sta RainIdx

        ; lightning flash overrides the sky/cloud colours
        lda FlashTimer
        beq .noFlash
        dec FlashTimer
        lda #FLASH_SKY
        sta SkyNow
        lda #FLASH_CLOUD
        sta CloudNow
        bne .flashDone          ; always
.noFlash
        lda SkyColor
        sta SkyNow
        lda CloudColor
        sta CloudNow
.flashDone

        ; bolt countdown; when it ends the strike takes effect
        lda BoltTimer
        beq .noBolt
        dec BoltTimer
        bne .noBolt
        jsr StrikeEffect
        lda State
        cmp #STATE_OVER
        beq .noBolt             ; game over: the bolt stays in the frozen scene
        jsr HideBolt
.noBolt

        ; sprite positions (one line each + HMOVE line, all in VBLANK)
        lda PlayerX
        ldx #0
        jsr PosObject
        lda BoltX
        ldx #1
        jsr PosObject
        sta WSYNC
        sta HMOVE

        lda State
        cmp #STATE_MAIN
        bne .intro
        jmp MainLogic
.intro  ; dispatch on Phase through the jump table (RTS trick)
        lda Phase
        asl
        tax
        lda IntroPhases+1,x
        pha
        lda IntroPhases,x
        pha
        rts

IntroPhases
        .word Phase0-1, Phase1-1, Phase2-1, Phase3-1, Phase4-1

;------------------------------------------------------------------------------
; Intro phases
        SUBROUTINE
Phase0  ; clouds roll in
        dec Timer
        bne .done
        lda #CLOUD_STEP
        sta Timer
        inc CloudOffset
        lda CloudOffset
        cmp #CLOUD_STEPS
        bne .done
        inc Phase
        lda #GREY_STEP
        sta Timer
        lda #0
        sta Count
.done   rts

        SUBROUTINE
Phase1  ; clouds and sky darken
        dec Timer
        bne .done
        lda #GREY_STEP
        sta Timer
        dec CloudColor
        dec CloudColor
        dec SkyColor
        dec SkyColor
        inc Count
        lda Count
        cmp #GREY_STEPS
        bne .done
        inc Phase
        lda #CLOUD_LIGHTNING
        sta Timer
.done   rts

        SUBROUTINE
Phase2  ; lightning in the clouds
        jsr RandomFlash
        dec Timer
        bne .done
        inc Phase
        lda #RAIN_ON
        sta RainBase
        lda #RAIN_ONLY
        sta Timer
.done   rts

        SUBROUTINE
Phase3  ; rain
        jsr RandomFlash
        dec Timer
        bne .done
        inc Phase
        lda #0
        sta Count
        lda #30
        sta Timer
.done   rts

        SUBROUTINE
Phase4  ; lightning strikes the ground, then the main game begins
        jsr RandomFlash
        lda BoltTimer
        bne .done
        dec Timer
        bne .done
        lda Count
        cmp #GROUND_STRIKES
        beq .toMain
        inc Count
        lda #STRIKE_GAP
        sta Timer
        lda #TREE_LINES         ; bolt reaches the ground
        sta Tmp
        lda Rand
        and #1
        tax
        lda GroundX,x
        jmp StartStrike
.toMain jmp InitMain
.done   rts

;==============================================================================
; MAIN GAME
;==============================================================================
        SUBROUTINE
MainLogic
        jsr RandomFlash
        jsr PlayerLogic

        ; seed: all trees gone and hands free
        lda Carry
        bne .noSeed
        lda TreeH
        ora TreeH+1
        ora TreeH+2
        bne .noSeed
        lda #CARRY_SEED
        sta Carry
.noSeed
        jsr Countdown

        ; lightning
        lda BoltTimer
        bne .done
        dec NextStrike
        bne .done
        jsr StrikeInterval
        jsr PickTarget
        lda Target
        bmi .done               ; nothing to strike
        cmp #TARGET_TOWER
        beq .tower
        bcs .pile
        tax                     ; tree
        lda #TREE_ROWS-2        ; top row of the tree = 8 - (h + 2)
        sec
        sbc TreeH,x
        tay
        lda Mul6,y
        sta Tmp
        lda TreeX,x
        jmp StartStrike
.tower  lda #TREE_ROWS
        sec
        sbc TowerH
        tax
        lda Mul6,x
        sta Tmp
        lda #TOWER_BOLT_X
        jmp StartStrike
.pile   cmp #TARGET_PLAYER
        beq .player
        sec
        sbc #TARGET_PILE        ; A = slot
        tax
        lda #TREE_ROWS
        sec
        sbc Pile,x
        tay
        lda Mul6,y
        sta Tmp
        lda PileX,x
        sec
        sbc #4                  ; 8-wide bolt centred on the pile
        jmp StartStrike
.player lda #PLAYER_Y0          ; bolt ends at the player's head
        sec
        sbc Tmp2                ; jump height this frame (PlayerLogic)
        sta Tmp
        lda PlayerX
        cmp #BOLT_MIN_X
        bcs .px
        lda #BOLT_MIN_X
.px     jmp StartStrike
.done   rts

; Text screens.  STATE_OVER: Phase 0 = frozen scene for Timer frames, then
; Phase 1 = GAME OVER text (with its song) until FIRE (-> title).  STATE_ROUND:
; ROUND n text with its song for ShowTimer frames, then the game resumes.
        SUBROUTINE
TextLogic
        lda Phase
        bne .text
        dec Timer
        bne .done
        inc Phase               ; GAME OVER text: start its song
        lda #SONG_OVER
        jmp MusicStart
.text   lda State
        cmp #STATE_ROUND
        beq .round
        bit Fire                ; GAME OVER: FIRE -> title (TitleLogic mutes the song)
        bvc .done
        lda #STATE_TITLE
        sta State
.done   rts
.round  dec ShowTimer
        bne .done
        lda #STATE_MAIN
        sta State
        lda #60
        sta CountTick           ; Timer doubles as the clock's frame counter
        lda #SONG_MAIN
        jmp MusicStart

; The round number as one big digit: 5 glyph rows of 8 lines, centred
; (PF2 left, bits 2-4, like the old goal digit).  DIGIT_LINES lines.
        SUBROUTINE
DrawDigit
        lda Level
        ldx #0
        jsr Times5
        sty Tmp                 ; glyph index of row 0
        ldx #0
.line   sta WSYNC
        txa                     ; 2
        lsr                     ; 4
        lsr                     ; 6
        lsr                     ; 8   row = line / 8
        clc                     ; 10
        adc Tmp                 ; 13
        tay                     ; 15
        lda DigitR,y            ; 19
        asl                     ; 21
        asl                     ; 23
        sta PF2                 ; 26  left PF2 (cols 18-20), shown from cycle 38
        ldy #4                  ; 28
.wait   dey                     ; 4 iterations: 19 cycles
        bne .wait               ; 47
        lda #0                  ; 49
        sta PF2                 ; 52  clear the right half (50..65)
        inx                     ; 54
        cpx #DIGIT_LINES        ; 56
        bne .line               ; 59
        rts

; Round clock: one second per 60 frames; at 0 the next round starts
        SUBROUTINE
Countdown
        dec CountTick
        bne .done
        lda #60
        sta CountTick
        sed
        sec
        lda CountSec
        sbc #1
        cld
        sta CountSec
        bne .show
        inc Level
        jmp NewLevel            ; time's up: next round
.show   lda Dirty
        ora #8                  ; the tower rebuild also redraws the status line
        sta Dirty
.done   rts

; The bolt has finished: apply the strike
        SUBROUTINE
StrikeEffect
        lda State
        cmp #STATE_MAIN
        bne .done
        ldx Target
        bmi .done
        cpx #TARGET_PLAYER
        beq .hit
        cpx #TARGET_PILE
        bcs .pile
        lda BitTbl,x
        ora Dirty
        sta Dirty
        cpx #TARGET_TOWER
        beq .tower
        lda Pile,x              ; tree -> wood
        clc
        adc TreeH,x
        cmp #TREE_ROWS+1
        bcc .pileOk
        lda #TREE_ROWS
.pileOk sta Pile,x
        lda #0
        sta TreeH,x
        rts
.tower  lda TowerH
        sec
        sbc #TOWER_STRIKE_LOSS
        bcs .towerOk
        lda #0
.towerOk
        sta TowerH
.done   rts
.pile   txa                     ; pile burns
        sec
        sbc #TARGET_PILE
        tax
        jsr DirtySlot
        lda Pile,x
        sec
        sbc #PILE_STRIKE_LOSS
        bcs .pileOk2
        lda #0
.pileOk2
        sta Pile,x
        rts
.hit    lda #STATE_OVER         ; the bolt hit the player: freeze the scene,
        sta State               ; then the GAME OVER text (TextLogic)
        lda #0
        sta Phase
        lda #OVER_FREEZE
        sta Timer
        lda #SONG_NONE          ; silence while the scene is frozen
        jmp MusicStart

;------------------------------------------------------------------------------
        SUBROUTINE
PlayerLogic
        lda SWCHA
        and #$C0                ; bit 7 right, bit 6 left (0 = pushed)
        cmp #$C0
        beq .idle
        and #$80
        beq .right
        lda PlayerX             ; left
        beq .moved
        dec PlayerX
        lda #8
        sta Facing
        bne .moved              ; always
.right  lda PlayerX
        cmp #PLAYER_MAX
        bcs .moved
        inc PlayerX
        lda #0
        sta Facing
.moved  lda Frame
        and #8                  ; walk frame every 8 frames
        bne .frame
.idle   lda #0
.frame  lsr
        lsr
        lsr                     ; 0 or 1
        sta Tmp
        lda Carry
        asl
        ora Tmp                 ; Carry*2 + frame
        tax
        ; jump: UP on the ground takes off, then JumpT steps through JumpTbl
        ldy JumpT
        bne .air
        lda SWCHA
        and #$10                ; bit 4 up (0 = pushed)
        bne .ground
        iny                     ; take off
.air    lda JumpTbl-1,y         ; height this frame, $FF = arc over
        bpl .rising
.ground ldy #0
        lda #0
        beq .setJump            ; always
.rising iny
.setJump
        sty JumpT
        sta Tmp2                ; lines above the ground
        lda PlayerLo,x
        clc
        adc Tmp2                ; same page: see the sprite page layout
        sta PlayerPtr
        lda #>PlayerStandNone   ; all player sprites are in one page
        sta PlayerPtr+1
        lda Facing
        sta REFP0

        bit Fire
        bvc .noFire
        lda Carry
        cmp #CARRY_BLOCK
        beq .haveBlock
        cmp #CARRY_SEED
        beq .haveSeed
        ; empty hands: pick up from a pile within reach
        ldx #2
.pick   lda Pile,x
        beq .nextPile
        lda PlayerX
        clc
        adc #4
        sec
        sbc PileX,x             ; player centre - pile centre
        bcs .abs
        eor #$FF
        adc #1
.abs    cmp #PILE_REACH+1
        bcs .nextPile
        dec Pile,x
        lda #CARRY_BLOCK
        sta Carry
        jmp DirtySlot
.nextPile
        dex
        bpl .pick
.noFire rts
.haveBlock
        lda PlayerX
        cmp #TOWER_ZONE
        bcc .noFire
        inc TowerH
        lda #CARRY_NONE
        sta Carry
        lda Dirty
        ora #8
        sta Dirty
        lda Level               ; goal = 4 + level, at most TREE_ROWS
        clc
        adc #3                  ; (goal - 1 >= TowerH: not there yet)
        cmp #TREE_ROWS
        bcc .goal
        lda #TREE_ROWS-1
.goal   cmp TowerH
        bcs .noFire
        inc Level
        jmp NewLevel
.haveSeed
        ldx #0                  ; nearest slot
        lda PlayerX
        clc
        adc #4
        cmp #PLANT_SPLIT_01
        bcc .slot
        inx
        cmp #PLANT_SPLIT_12
        bcc .slot
        inx
.slot   lda TreeH,x
        bne .noFire             ; occupied (cannot happen: all gone)
        jsr TreeHeight
        sta TreeH,x
        lda #CARRY_NONE
        sta Carry
        ; fall into DirtySlot

; Mark tree slot X for redraw
DirtySlot
        lda BitTbl,x
        ora Dirty
        sta Dirty
        rts

; Status line: level | tower height | seconds left
        SUBROUTINE
StatusDigits
        ldx #4
.row    lda Level
        jsr Times5
        lda DigitL,y
        asl
        asl
        asl
        asl
        asl
        sta Tmp
        lda TowerH
        jsr Times5
        lda DigitL,y
        ora Tmp
        sta StatusPF1,x
        lda CountSec            ; two BCD digits in PF2 (bit 0 = left): tens at
        and #$0F                ; bits 1-3, ones at bits 5-7
        jsr Times5
        lda DigitR,y
        asl
        asl
        asl
        asl
        asl
        sta Tmp
        lda CountSec
        lsr
        lsr
        lsr
        lsr
        jsr Times5
        lda DigitR,y
        asl
        ora Tmp
        sta StatusPF2,x
        dex
        bpl .row
        rts

; Y = A*5 + X (digit glyph row index); preserves X and Tmp
        SUBROUTINE
Times5
        sta Tmp2
        asl
        asl
        clc
        adc Tmp2
        stx Tmp2
        adc Tmp2
        tay
        rts

;------------------------------------------------------------------------------
; Redraw one changed object of the tree-band playfield (Rows) per frame:
; the lowest set bit of Dirty (0-2 = tree slot incl. its wood pile, 3 = tower).
; Each takes < 900 cycles; called from overscan.
        SUBROUTINE
RebuildNext
        lda Dirty
        beq .done
        ldx #0
.find   lsr
        bcs .found
        inx
        bne .find
.found  lda BitTbl,x
        eor #$FF
        and Dirty
        sta Dirty
        cpx #3
        beq .tower
        jsr RebuildSlot
        jmp .colors
.tower  jsr RebuildTower
.colors jsr RowColors
        jmp StatusDigits        ; tail call
.done   rts

; COLUMN_LOOP op -- apply 'op Tmp' to the Rows byte at index Y and the Cnt
; rows below it (stride 6).  op is ora (draw) or and (clear).
        MAC COLUMN_LOOP
.col    lda Rows,y
        {1} Tmp
        sta Rows,y
        tya
        clc
        adc #6
        tay
        dec Cnt
        bne .col
        ENDM

; Redraw tree slot X: clear its 5 columns in every row, then draw the tree
; (trunk rows 8-h..7, wide canopy row 7-h, narrow row 6-h) and the wood pile.
        SUBROUTINE
RebuildSlot
        stx Obj
        txa
        asl
        tax                     ; X = slot*2 (canopy pattern pairs)
        lda WideByte,x
        eor #$FF
        sta Tmp
        ldy WideReg,x
        lda #TREE_ROWS
        sta Cnt
        COLUMN_LOOP and
        lda WideByte+1,x
        eor #$FF
        sta Tmp
        ldy WideReg+1,x
        lda #TREE_ROWS
        sta Cnt
        COLUMN_LOOP and

        ldx Obj
        lda TreeH,x
        beq .noTree
        sta Cnt
        lda #TREE_ROWS
        sec
        sbc TreeH,x
        tay
        lda Mul6,y
        sta Row                 ; index base of the top trunk row
        clc
        adc TrunkReg,x
        tay
        lda TrunkByte,x
        sta Tmp
        COLUMN_LOOP ora
        txa
        asl
        tax                     ; X = slot*2
        lda Row
        sec
        sbc #6
        sta Row                 ; wide canopy row base
        clc
        adc WideReg,x
        tay
        lda Rows,y
        ora WideByte,x
        sta Rows,y
        lda Row
        clc
        adc WideReg+1,x
        tay
        lda Rows,y
        ora WideByte+1,x
        sta Rows,y
        lda Row
        sec
        sbc #6
        sta Row                 ; narrow canopy row base
        clc
        adc NarrowReg,x
        tay
        lda Rows,y
        ora NarrowByte,x
        sta Rows,y
        lda Row
        clc
        adc NarrowReg+1,x
        tay
        lda Rows,y
        ora NarrowByte+1,x
        sta Rows,y
.noTree
        ldx Obj
        lda Pile,x
        beq .done
        sta Cnt
        lda #TREE_ROWS
        sec
        sbc Pile,x
        tay
        lda Mul6,y
        clc
        adc PileReg,x
        tay
        lda PileByte,x
        sta Tmp
        COLUMN_LOOP ora
.done   rts

        SUBROUTINE
RebuildTower
        lda #TOWER_BYTE ^ $FF
        sta Tmp
        ldy #TOWER_REG
        lda #TREE_ROWS
        sta Cnt
        COLUMN_LOOP and
        lda TowerH
        beq .done
        sta Cnt
        lda #TREE_ROWS
        sec
        sbc TowerH
        tay
        lda Mul6,y
        clc
        adc #TOWER_REG
        tay
        lda #TOWER_BYTE
        sta Tmp
        COLUMN_LOOP ora
.done   rts

; Row colours: canopy rows green, everything else wood
        SUBROUTINE
RowColors
        lda #WOOD_COLOR
        ldx #TREE_ROWS-1
.clr    sta RowColor,x
        dex
        bpl .clr
        ldx #2
.tree   lda TreeH,x
        beq .next
        sta Tmp
        lda #TREE_ROWS-1
        sec
        sbc Tmp
        tay
        lda #CANOPY_COLOR
        sta RowColor,y
        dey
        sta RowColor,y
.next   dex
        bpl .tree
        rts

;------------------------------------------------------------------------------
        SUBROUTINE
SceneKernel
        lda State
        cmp #STATE_OVER
        bcc SceneDraw
        lda Phase
        beq SceneDraw           ; frozen final scene (GAME OVER, Phase 0)
        jmp TextKernel
SceneDraw
        ; --- status line (STATUS_LINES): digits in the left playfield ---
        lda SkyNow
        sta COLUBK
        lda #STATUS_COLOR
        sta COLUPF
        sta WSYNC
        ldx #0
.status sta WSYNC               ; 10 lines, 2 per digit row
        txa                     ; 2
        lsr                     ; 4
        tay                     ; 6
        lda StatusPF1,y         ; 10
        sta PF1                 ; 13
        lda StatusPF2,y         ; 17
        sta PF2                 ; 20
        lda #0                  ; 22
        ldy #3                  ; 24
.delay  dey                     ; 3 iterations: 14 cycles
        bne .delay              ; 38
        sta PF1                 ; 41  clear right PF1 (39..54)
        nop
        nop
        nop
        nop                     ; 49
        sta PF2                 ; 52  clear right PF2 (50..65)
        inx                     ; 54
        cpx #10                 ; 56
        bne .status             ; 59
        sta WSYNC
        lda CloudNow
        sta COLUPF
        lda #0
        sta PF1
        sta PF2

        ; 4 cloud rows of CLOUD_LINES lines; the tables are indexed offset*4 + row,
        ; so one loop draws all rows and the row change is cheap (abs,X page crossings
        ; only shift the writes by a cycle each, within their windows)
        lda CloudOffset
        asl
        asl
        tax
        clc
        adc #4
        sta Tmp                 ; end index
.crow   ldy #CLOUD_LINES
.cline  sta WSYNC
        lda Cloud_PF0L,x        ; 4
        sta PF0                 ; 7
        lda Cloud_PF1L,x        ; 11
        sta PF1                 ; 14
        lda Cloud_PF2L,x        ; 18
        sta PF2                 ; 21
        lda Cloud_PF0R,x        ; 25
        nop                     ; 27
        sta PF0                 ; 30  right PF0 (28..49)
        lda Cloud_PF1R,x        ; 34
        nop                     ; 36
        nop                     ; 38
        sta PF1                 ; 41  right PF1 (39..54)
        lda Cloud_PF2R,x        ; 45
        nop                     ; 47
        nop                     ; 49
        sta PF2                 ; 52  right PF2 (50..65)
        dey                     ; 54
        bne .cline              ; 57
        inx                     ; 58  next row
        cpx Tmp                 ; 61
        bne .crow               ; 64  (ldy 66, WSYNC written by 69)

        ; transition line: rain colour, playfield cleared
        sta WSYNC
        lda #RAIN_COLOR
        sta COLUPF
        lda #0
        sta PF0
        sta PF1
        sta PF2

        ; sky band: rain (repeated playfield) and the bolt (P1)
        ldx RainIdx
        ldy #0
.sky    sta WSYNC
        lda RainPF0,x           ; 4
        sta PF0                 ; 7
        lda RainPF1,x           ; 11
        sta PF1                 ; 14
        lda RainPF2,x           ; 18
        sta PF2                 ; 21
        lda (BoltPtr),y         ; 26
        sta GRP1                ; 29  (bolt x must be >= 19)
        inx                     ; 31
        txa                     ; 33
        and #15                 ; 35
        ora RainBase            ; 38
        tax                     ; 40
        iny                     ; 42
        cpy #SKY_LINES          ; 44
        bne .sky                ; 47

        ; tree band: Y counts 0..TREE_LINES-1 for the bolt and player tables
        ldy #0
        TREE_ROW 0, 0
        TREE_ROW 1, 0
        TREE_ROW 2, 0
        TREE_ROW 3, 1
        TREE_ROW 4, 1
        TREE_ROW 5, 1
        TREE_ROW 6, 1
        TREE_ROW 7, 1

        ; grass
        sta WSYNC
        lda #GRASS_DARK
        sta COLUBK
        lda #0
        sta PF0
        sta PF1
        sta PF2
        sta GRP0
        sta GRP1
        ldx #GRASS_DARK_LINES
        jsr SkipLines
        lda #GRASS_COLOR
        sta COLUBK
        ldx #GRASS_LINES
        ; fall into SkipLines

;------------------------------------------------------------------------------
; Wait out X scanlines (X >= 1).
SkipLines
        sta WSYNC
        dex
        bne SkipLines
        rts

;------------------------------------------------------------------------------
; small tables
TreeX       .byte 26,74,122     ; bolt sprite x (8 wide) centred on tree columns 7,19,31
PileX       .byte 28,76,124     ; pile centres in pixels
GroundX     .byte 50,98         ; intro ground strikes, between the slots
TOWER_BOLT_X = 144              ; tower at playfield columns 36-37
HeightTbl   .byte 2,3,4,4       ; random tree heights (levels 2+)
IntervalTbl .byte 240,210,180,150,120,90,90,90   ; frames between strikes, by level

        align 256               ; text tables in one page (no page-cross cycles)
        include "rainstorm_text.inc"

        include "rainstorm_gfx.inc"     ; clouds, rain, slot patterns, digits, BoltGfx

; Target = tallest object, in blocks: tree trunks (the canopy does not count),
; wood piles, the tower and the player (2 blocks, +1 per 6 lines of jump).
; Ties go to the tower, then the leftmost tree, then the leftmost pile; the
; player loses every tie.  Lives here because the main code region is full.
        SUBROUTINE
PickTarget
        lda #TARGET_NONE
        sta Target
        lda #0
        sta Tmp                 ; best height so far
        ldx #2
.pscan  lda Pile,x
        beq .pnext
        cmp Tmp
        bcc .pnext
        sta Tmp
        txa
        clc
        adc #TARGET_PILE
        sta Target
.pnext  dex
        bpl .pscan
        ldx #2
.scan   lda TreeH,x
        beq .next
        cmp Tmp
        bcc .next
        sta Tmp
        stx Target
.next   dex
        bpl .scan
        lda TowerH
        beq .player
        cmp Tmp
        bcc .player
        sta Tmp
        lda #TARGET_TOWER
        sta Target
.player ldx Tmp2                ; jump height this frame (PlayerLogic ran first)
        cpx #6
        lda #2
        adc #0                  ; +1 from 6 lines up
        cpx #12
        adc #0                  ; +1 more at the top (12 lines)
        cmp Tmp
        bcc .done
        beq .done
        lda #TARGET_PLAYER
        sta Target
.done   rts

        ; BoltBand and Zeros share one page (the tree-band kernel has no spare cycles
        ; for page crossing) and BoltBand must directly precede Zeros (StartStrike
        ; points BoltPtr2 at Zeros - end line).
        align 256
        include "rainstorm_bolt.inc"    ; BoltBand (TREE_LINES bytes)
Zeros       ds SKY_LINES                ; blank sprite data; must cover the longest band

        ; rest of this page: the text screens (tables read through DrawText's pointers:
        ; a 30-byte table must not cross a page)
        include "rainstorm_over.inc"    ; Over_PF0L..PF2R (30 bytes)
        include "rainstorm_round.inc"   ; Round_PF0L..PF2R (30 bytes)

        SUBROUTINE
TextKernel                              ; 192 lines: black; GAME OVER (red) or
        lda #0                          ; ROUND (green), then the big round number
        sta COLUBK
        lda State
        cmp #STATE_ROUND
        beq .round
        ldx #<Over_PF0L
        lda #>Over_PF0L
        ldy #OVER_COLOR
        bne .go                 ; always (A = page)
.round  ldx #<Round_PF0L
        lda #>Round_PF0L
        ldy #TITLE_COLOR
.go     sty COLUPF
        stx Tmp
        ldx #TEXT_TOP
        jsr SkipLines           ; keeps A
        ldx #TEXT_SCALE
        jsr DrawText
        ldx #TEXT_GAP
        jsr SkipLines
        jsr DrawDigit
        ldx #TEXT_BOTTOM
        jmp SkipLines

        ; Player sprite page.  PlayerPtr = sprite - PLAYER_Y0 + jump (0..JUMP_MAX) and
        ; the band reads sprite - JUMP_MAX .. sprite + 17 + JUMP_MAX, so everything from
        ; sprite - PLAYER_Y0 on must sit in one page: JumpTbl (>= 18 bytes) fills the
        ; start, then JUMP_MAX blank rows, then the 6 frames, each followed by
        ; JUMP_MAX blank rows (generated).
        align 256
JumpTbl     .byte 2,4,6,8,9,10,11,12,12,12,12,12,11,10,9,8,6,4,2,0,$FF
            ds JUMP_MAX
        include "rainstorm_player.inc"  ; 6 x (18 + JUMP_MAX) bytes
        ; tables that did not fit in the main code region
Mul6        .byte 0,6,12,18,24,30,36,42,48
BitTbl      .byte 1,2,4,8
PlayerLo    .byte <(PlayerStandNone-PLAYER_Y0),<(PlayerWalkNone-PLAYER_Y0)
            .byte <(PlayerStandBlock-PLAYER_Y0),<(PlayerWalkBlock-PLAYER_Y0)
            .byte <(PlayerStandSeed-PLAYER_Y0),<(PlayerWalkSeed-PLAYER_Y0)

        echo "Bank 1 bytes free:", ($FFF8 - *)d   ; $FFF8/9 are the hotspots: keep them clear

        rend
        org $2FFC
        rorg $FFFC
        .word Reset
        .word Reset
        rend
