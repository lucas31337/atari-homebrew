; rainstorm.asm - RAINSTORM (4K, NTSC)  -- see docs/GAMEPLAY.md
;
; States:  TITLE - "RAINSTORM / BY / LUCAS YOUNG" + blinking "START"; FIRE starts the intro
;          INTRO - blue sky and field; clouds roll in, turn grey, lightning in the clouds,
;                  rain starts, two lightning strikes hit the ground
;          MAIN  - three trees of height 2-4 (level 1: all 4).  Lightning strikes the
;                  tallest object: the tallest tree, or the player's wood tower if it is
;                  taller than every tree.  A struck tree becomes a pile of wood blocks.
;                  The player walks (joystick), picks up blocks and stacks them on the
;                  tower at the right edge (FIRE).  When all trees are gone the player
;                  holds a seed; FIRE plants it in the nearest empty slot.  Tower height
;                  >= goal -> next level (new trees, random heights, faster lightning).
;                  Console RESET (F2 in Stella) returns to the title from anywhere.
;
; Frame:   3 VSYNC + 37 VBLANK + 192 visible + 30 overscan = 262 lines
; Scene kernel, top to bottom (192 lines):
;          8 status (level / tower / goal digits) | 24 clouds (playfield, 4 rows) |
;          1+79 sky with rain (playfield) and the lightning bolt (P1) |
;          48 tree band: 8 rows of 6 lines, playfield from RAM (trees, wood piles, tower),
;          bolt (P1) and the player (P0, rows 5-7) | 1+31 grass
        processor 6502
        include "vcs.h"
        include "macro.h"

STATE_TITLE     = 0
STATE_INTRO     = 1
STATE_MAIN      = 2

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
PLAYER_ROW      = 5             ; first tree-band row that draws the player (rows 5-7)
PLAYER_Y0       = PLAYER_ROW * BLOCK_LINES
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
TOWER_STRIKE_LOSS = 2           ; blocks burnt off the tower by a strike
PLAYER_MAX      = 152
TOWER_ZONE      = 128           ; player x from which FIRE stacks a block
PILE_REACH      = 10            ; |player centre - pile centre| to pick up
PLANT_SPLIT_01  = 54            ; player centre below this plants in slot 0,
PLANT_SPLIT_12  = 102           ;   below this slot 1, else slot 2
CARRY_NONE      = 0
CARRY_BLOCK     = 1
CARRY_SEED      = 2
TARGET_TOWER    = 3
TARGET_NONE     = $FF

;------------------------------------------------------------------------------
        seg.u Vars
        org $80
State       ds 1
Frame       ds 1
FireDown    ds 1                ; $80 while the button is held
FirePressed ds 1                ; $80 for one frame on a new press
StartColor  ds 1
Rand        ds 1                ; 8-bit LFSR, never 0
Tmp         ds 1
Tmp2        ds 1
Row         ds 1                ; Rebuild: row base index
Cnt         ds 1                ; Rebuild: rows left
Obj         ds 1                ; Rebuild: tree slot
Phase       ds 1                ; sub-state within INTRO
Timer       ds 1                ; frame countdown for the current phase step
Count       ds 1                ; generic counter for the current phase
CloudOffset ds 1                ; 0..CLOUD_STEPS
CloudColor  ds 1
SkyColor    ds 1
CloudNow    ds 1                ; colours used this frame (after flash)
SkyNow      ds 1
RainBase    ds 1                ; 0 = no rain, RAIN_ON = rain
RainScroll  ds 1
RainIdx     ds 1                ; kernel start index into the rain tables
FlashTimer  ds 1
BoltTimer   ds 1
BoltX       ds 1
BoltPtr     ds 2                ; bolt graphics for the sky band (or Zeros)
BoltPtr2    ds 2                ; bolt graphics for the tree band (Zeros - end line)
PlayerPtr   ds 2                ; player sprite - PLAYER_Y0 (or hidden)
Target      ds 1                ; 0-2 tree, TARGET_TOWER, TARGET_NONE
TreeH       ds 3                ; trunk blocks per slot, 0 = no tree
Pile        ds 3                ; wood blocks lying at each slot
TowerH      ds 1
PlayerX     ds 1
Facing      ds 1                ; REFP0 value: 0 right, 8 left
WalkCnt     ds 1
Carry       ds 1                ; CARRY_*
Level       ds 1
Goal        ds 1                ; tower height that completes the level
NextStrike  ds 1
Dirty       ds 1                ; bits 0-2: redraw tree slot, bit 3: redraw tower (one per frame)
Rows        ds TREE_ROWS*6      ; per row: PF0L PF1L PF2L PF0R PF1R PF2R
RowColor    ds TREE_ROWS
StatusPF1   ds 5                ; status digits, top row first
StatusPF2   ds 5

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
; PF_TEXT label, scale -- draw 5-row asymmetric playfield text from the
; label_PF0L..label_PF2R tables, each row repeated 'scale' scanlines.
; Uses 5*scale+1 scanlines and leaves the playfield cleared.
; Cycle counts are from the end of WSYNC; right-half writes must land after
; the left half is drawn and before the right half starts:
;   PF0 right 28..49, PF1 right 39..54, PF2 right 50..65
        MAC PF_TEXT
        ldy #4
.row    ldx #{2}
.line   sta WSYNC
        lda {1}_PF0L,y          ; 4
        sta PF0                 ; 7
        lda {1}_PF1L,y          ; 11
        sta PF1                 ; 14
        lda {1}_PF2L,y          ; 18
        sta PF2                 ; 21
        lda {1}_PF0R,y          ; 25
        nop                     ; 27
        sta PF0                 ; 30
        lda {1}_PF1R,y          ; 34
        nop                     ; 36
        nop                     ; 38
        sta PF1                 ; 41
        lda {1}_PF2R,y          ; 45
        nop                     ; 47
        nop                     ; 49
        sta PF2                 ; 52
        dex
        bne .line
        dey
        bpl .row
        sta WSYNC
        lda #0
        sta PF0
        sta PF1
        sta PF2
        ENDM

;------------------------------------------------------------------------------
; CLOUD_ROW r -- one cloud row, CLOUD_LINES lines, X = scroll offset
        MAC CLOUD_ROW
        ldy #CLOUD_LINES
.line   sta WSYNC
        lda Cloud{1}_PF0L,x     ; 4
        sta PF0                 ; 7
        lda Cloud{1}_PF1L,x     ; 11
        sta PF1                 ; 14
        lda Cloud{1}_PF2L,x     ; 18
        sta PF2                 ; 21
        lda Cloud{1}_PF0R,x     ; 25
        nop                     ; 27
        sta PF0                 ; 30
        lda Cloud{1}_PF1R,x     ; 34
        nop                     ; 36
        nop                     ; 38
        sta PF1                 ; 41
        lda Cloud{1}_PF2R,x     ; 45
        nop                     ; 47
        nop                     ; 49
        sta PF2                 ; 52
        dey                     ; 54
        bne .line               ; 57
        ENDM

;------------------------------------------------------------------------------
; TREE_ROW row, player -- one tree-band row (BLOCK_LINES lines) from RAM with
; the bolt (P1) and, if player=1, the player (P0; VDELP0 makes the late write
; safe).  Y = line within the band.  Sprite tables must not cross a page.
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
        seg Code
        org $F000

Reset   CLEAN_START
        lda #$80
        sta FireDown            ; ignore a button already held at power-on
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
        sta VBLANK              ; beam off
        SET_TIMER 35            ; 35*64 cycles ~= 30 lines of overscan
        jsr RebuildNext         ; redraw one changed object (runs in overscan)
.waitOverscan
        lda INTIM
        bne .waitOverscan
        jmp MainLoop

;------------------------------------------------------------------------------
; Edge-detect the left joystick button (INPT4 bit 7 is 0 while pressed).
        SUBROUTINE
ReadFire
        lda INPT4
        and #$80
        eor #$80                ; $80 = held now
        tay
        lda FireDown
        eor #$80                ; $80 = was up last frame
        sty FireDown
        and FireDown            ; $80 = up last frame and held now
        sta FirePressed
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
        ldx #START_COLOR_ON     ; blink "START" every 16 frames
        lda Frame
        and #$10
        beq .on
        ldx #START_COLOR_OFF
.on     stx StartColor

        lda FirePressed
        beq .stay
        jmp InitScene
.stay   rts

TitleKernel
        lda #TITLE_COLOR
        sta COLUPF
        ldx #TOP_GAP
        jsr SkipLines
        PF_TEXT Title, TITLE_SCALE
        lda #AUTHOR_COLOR
        sta COLUPF
        ldx #BY_GAP
        jsr SkipLines
        PF_TEXT By, BY_SCALE
        ldx #AUTHOR_GAP
        jsr SkipLines
        PF_TEXT Author, AUTHOR_SCALE
        lda StartColor
        sta COLUPF
        ldx #MID_GAP
        jsr SkipLines
        PF_TEXT Start, START_SCALE
        ldx #BOTTOM_GAP
        jmp SkipLines           ; tail call

; Title screen layout, top to bottom, in scanlines (must total 192).
; Each PF_TEXT block takes scale*5+1 lines (+1 for the line that clears the playfield).
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
        lda #0
        sta CloudOffset
        sta RainBase
        sta RainScroll
        sta FlashTimer
        sta BoltTimer
        sta Phase
        sta Count
        sta TowerH
        sta Carry
        sta Facing
        ldx #2
.clr    sta TreeH,x
        sta Pile,x
        dex
        bpl .clr
        ldx #TREE_ROWS*6+TREE_ROWS+10-1
.clrs   sta Rows,x              ; Rows, RowColor and the status digits are adjacent
        dex
        bpl .clrs
        sta Dirty
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
        jsr HideBolt
        jsr HidePlayer
        lda #STATE_INTRO
        sta State
        rts

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
        lda Level
        clc
        adc #4
        cmp #TREE_ROWS+1
        bcc .goalOk
        lda #TREE_ROWS
.goalOk sta Goal
        jsr StrikeInterval
        lda #$0F
        sta Dirty
        lda #PLAYER_COLOR
        sta COLUP0
        rts

; A = height for a new tree (4 on level 1, else 2..4), preserves X
        SUBROUTINE
TreeHeight
        lda Level
        cmp #1
        bne .random
        lda #4
        rts
.random jsr NextRand
        lda Rand
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
HideBolt
        lda #<Zeros
        sta BoltPtr
        sta BoltPtr2
        lda #>Zeros
        sta BoltPtr+1
        sta BoltPtr2+1
        rts

        SUBROUTINE
HidePlayer
        lda #<(Zeros-PLAYER_Y0)
        sta PlayerPtr
        lda #>(Zeros-PLAYER_Y0)
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
        jsr HideBolt
        jsr StrikeEffect
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
        bne .tree
        lda #TREE_ROWS
        sec
        sbc TowerH
        tax
        lda Mul6,x
        sta Tmp
        lda #TOWER_BOLT_X
        jmp StartStrike
.tree   tax
        lda #TREE_ROWS-2        ; top row of the tree = 8 - (h + 2)
        sec
        sbc TreeH,x
        tay
        lda Mul6,y
        sta Tmp
        lda TreeX,x
        jmp StartStrike
.done   rts

; Target = tallest object (tallest tree wins ties with the tower)
        SUBROUTINE
PickTarget
        lda #TARGET_NONE
        sta Target
        lda #0
        sta Tmp                 ; best height so far
        ldx #2
.scan   lda TreeH,x
        beq .next
        clc
        adc #2                  ; canopy
        cmp Tmp
        bcc .next
        beq .next
        sta Tmp
        stx Target
.next   dex
        bpl .scan
        lda TowerH
        cmp Tmp
        bcc .done
        beq .done
        lda #TARGET_TOWER
        sta Target
.done   rts

; The bolt has finished: apply the strike
        SUBROUTINE
StrikeEffect
        lda State
        cmp #STATE_MAIN
        bne .done
        ldx Target
        bmi .done
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
.moved  inc WalkCnt
        lda WalkCnt
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
        lda PlayerLo,x
        sta PlayerPtr
        lda PlayerHi,x
        sta PlayerPtr+1
        lda Facing
        sta REFP0

        lda FirePressed
        beq .noFire
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
        lda TowerH
        cmp Goal
        bcc .noFire
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

; Status line: level | tower height | goal
        SUBROUTINE
StatusDigits
        ldx #4
.row    lda Level
        cmp #10
        bcc .lv
        lda #9
.lv     jsr Times5
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
        lda Goal
        jsr Times5
        lda DigitR,y
        asl
        asl
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

        ldx CloudOffset
        CLOUD_ROW 0
        CLOUD_ROW 1
        CLOUD_ROW 2
        CLOUD_ROW 3

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
        TREE_ROW 3, 0
        TREE_ROW 4, 0
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
Mul6        .byte 0,6,12,18,24,30,36,42,48
BitTbl      .byte 1,2,4,8
TreeX       .byte 26,74,122     ; bolt sprite x (8 wide) centred on tree columns 7,19,31
PileX       .byte 28,76,124     ; pile centres in pixels
GroundX     .byte 50,98         ; intro ground strikes, between the slots
TOWER_BOLT_X = 144              ; tower at playfield columns 36-37
HeightTbl   .byte 2,3,4,4       ; random tree heights (levels 2+)
IntervalTbl .byte 240,210,180,150,120,90,90,90   ; frames between strikes, by level
PlayerLo    .byte <(PlayerStandNone-PLAYER_Y0),<(PlayerWalkNone-PLAYER_Y0)
            .byte <(PlayerStandBlock-PLAYER_Y0),<(PlayerWalkBlock-PLAYER_Y0)
            .byte <(PlayerStandSeed-PLAYER_Y0),<(PlayerWalkSeed-PLAYER_Y0)
PlayerHi    .byte >(PlayerStandNone-PLAYER_Y0),>(PlayerWalkNone-PLAYER_Y0)
            .byte >(PlayerStandBlock-PLAYER_Y0),>(PlayerWalkBlock-PLAYER_Y0)
            .byte >(PlayerStandSeed-PLAYER_Y0),>(PlayerWalkSeed-PLAYER_Y0)

        align 256               ; text tables in one page (no page-cross cycles)
        include "rainstorm_text.inc"

        include "rainstorm_gfx.inc"     ; clouds, rain, slot patterns, digits, BoltGfx

        ; BoltBand, Zeros and the player sprites must share one page (the tree-band
        ; kernel has no spare cycles for page crossing) and BoltBand must directly
        ; precede Zeros (StartStrike points BoltPtr2 at Zeros - end line).
        align 256
        include "rainstorm_bolt.inc"    ; BoltBand (TREE_LINES bytes)
Zeros       ds SKY_LINES                ; blank sprite data; must cover the longest band
        include "rainstorm_player.inc"  ; 6 x 18 bytes

        echo "ROM bytes free:", ($FFFC - *)d

        org $FFFC
        .word Reset
        .word Reset
