; rainstorm.asm - RAINSTORM (4K, NTSC)
;
; States:  TITLE - "RAINSTORM / BY / LUCAS YOUNG" + blinking "START"; FIRE starts the intro
;          INTRO - blue sky and field; clouds roll in, turn grey, lightning in the clouds,
;                  rain starts, two lightning strikes hit the ground
;          MAIN  - three trees; lightning strikes a random living tree and burns it to a
;                  stump; when all three are gone the game returns to the title
;          Console RESET (F2 in Stella) returns to the title from anywhere.
;
; Frame:   3 VSYNC + 37 VBLANK + 192 visible + 30 overscan = 262 lines
; Scene kernel, top to bottom (192 lines):
;          8 sky | 24 clouds (playfield, 4 rows) | 1+87 sky with rain (playfield) and the
;          lightning bolt (P1) | 40 trees (playfield from RAM, 4 canopy rows + trunk) with
;          flames (P0) and the bolt | 1+31 grass
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
TRUNK_COLOR     = $F2
GRASS_COLOR     = $C8
GRASS_DARK      = $C6
BOLT_COLOR_A    = $0E
BOLT_COLOR_B    = $1E
FLAME_COLOR_A   = $3A           ; orange
FLAME_COLOR_B   = $1C           ; yellow

;--- scene kernel layout (must total 192)
SKY_TOP_LINES   = 8
CLOUD_LINES     = 6             ; per cloud row, 4 rows
SKY_LINES       = 87            ; rain/bolt loop lines (+1 transition line)
CANOPY_LINES    = 7             ; per canopy row, 4 rows
TRUNK_LINES     = 12
TREE_LINES      = CANOPY_LINES * 4 + TRUNK_LINES
GRASS_DARK_LINES = 4
GRASS_LINES     = 192 - SKY_TOP_LINES - CLOUD_LINES * 4 - 1 - SKY_LINES - TREE_LINES - 1 - GRASS_DARK_LINES

;--- scene timing (frames unless noted)
CLOUD_STEPS     = 40            ; scroll offsets until the clouds are fully in
CLOUD_STEP      = 6             ; frames per scroll step
GREY_STEPS      = 4
GREY_STEP       = 24
CLOUD_LIGHTNING = 180           ; lightning in the clouds before the rain starts
RAIN_ONLY       = 120           ; rain before the first ground strike
GROUND_STRIKES  = 2
STRIKE_GAP      = 60
FIRST_STRIKE    = 90            ; main game: frames before the first tree strike
MIN_GAP         = 60            ; main game: gap between strikes is MIN_GAP + rand(0..127)
END_PAUSE       = 150           ; after the last tree burns, before returning to the title
FLASH_CHANCE    = 6             ; per-frame chance (out of 256) of a cloud flash
FLASH_SHORT     = 2
FLASH_STRIKE    = 5
        IFNCONST BOLT_FRAMES    ; dasm -DBOLT_FRAMES=120 holds the bolt on screen (for testing)
BOLT_FRAMES     = 8
        ENDIF
BURN_FRAMES     = 150
BURN_STAGE1     = 110           ; BurnTimer values at which canopy rows are erased
BURN_STAGE2     = 70
BURN_STAGE3     = 30
RAIN_SPEED      = 3             ; rain tile rows per frame
RAIN_ON         = 16            ; RainBase value when raining (tile rows 16-31)

TREE_BYTES      = 5 * 6

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
BoltPtr     ds 2                ; bolt graphics for the sky band (or Zeros)
BoltPtr2    ds 2                ; bolt graphics for the tree band (or Zeros)
FlamePtr    ds 2                ; flame graphics for the tree band (or Zeros)
BurnTree    ds 1                ; tree being struck/burnt (0-2), $FF = none
BurnTimer   ds 1
TreeAlive   ds 1                ; bit n set = tree n still standing
NextStrike  ds 1
Tree        ds TREE_BYTES       ; per row: PF0L PF1L PF2L PF0R PF1R PF2R

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
; TREE_ROW colour, row, lines -- one tree row from RAM, with the bolt (P1) and
; flames (P0, VDELP0 so the late write is safe) overlaid.  Y = line in band.
        MAC TREE_ROW
        ldx #{3}
.line   sta WSYNC
        lda #{1}                ; 2
        sta COLUPF              ; 5   (in HBLANK)
        lda (BoltPtr2),y        ; 10
        sta GRP1                ; 13
        lda Tree+{2}*6+0        ; 16
        sta PF0                 ; 19
        lda Tree+{2}*6+1        ; 22
        sta PF1                 ; 25
        lda Tree+{2}*6+2        ; 28
        sta PF2                 ; 31
        lda (FlamePtr),y        ; 36
        sta GRP0                ; 39  (buffered; shown from the next GRP1 write)
        lda Tree+{2}*6+3        ; 42
        sta PF0                 ; 45  right PF0 (28..49)
        lda Tree+{2}*6+4        ; 48
        sta PF1                 ; 51  right PF1 (39..54)
        lda Tree+{2}*6+5        ; 54
        sta PF2                 ; 57  right PF2 (50..65)
        iny                     ; 59
        dex                     ; 61
        bne .line               ; 64
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
        sta BurnTimer
        sta Phase
        sta Count
        sta TreeAlive
        ldx #TREE_BYTES-1
.clear  sta Tree,x
        dex
        bpl .clear
        lda #$FF
        sta BurnTree
        lda #CLOUD_WHITE
        sta CloudColor
        lda #SKY_DAY
        sta SkyColor
        lda #CLOUD_STEP
        sta Timer
        jsr HideBolt
        jsr HideFlame
        lda #STATE_INTRO
        sta State
        rts

        SUBROUTINE
InitTrees
        ldx #TREE_BYTES-1
.copy   lda TreeInit,x
        sta Tree,x
        dex
        bpl .copy
        lda #7
        sta TreeAlive
        rts

HideBolt
        lda #<Zeros
        sta BoltPtr
        sta BoltPtr2
        lda #>Zeros
        sta BoltPtr+1
        sta BoltPtr2+1
        rts

HideFlame
        lda #<Zeros
        sta FlamePtr
        lda #>Zeros
        sta FlamePtr+1
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

; Start a lightning strike.  A = sprite x, Y = 0 for a tree (flames follow),
; 1 for the ground (bolt continues through the tree band).
        SUBROUTINE
StartStrike
        sty Tmp
        pha
        ldx #1
        jsr PosObject           ; P1 = bolt
        pla
        ldy Tmp
        bne .ground
        ldx #0
        jsr PosObject           ; P0 = flames, same place
.ground
        sta WSYNC
        sta HMOVE
        lda #BOLT_FRAMES
        sta BoltTimer
        lda #FLASH_STRIKE
        sta FlashTimer
        lda #<BoltGfx
        sta BoltPtr
        lda #>BoltGfx
        sta BoltPtr+1
        ldy Tmp
        beq .treeMode
        lda #<(BoltGfx+SKY_LINES)
        sta BoltPtr2
        lda #>(BoltGfx+SKY_LINES)
        sta BoltPtr2+1
.treeMode
        sta HMCLR               ; >24 cycles after HMOVE
        rts

; Erase canopy row X of tree BurnTree from the RAM playfield.
        SUBROUTINE
EraseRow
        ldy BurnTree
        lda Mul6,y
        sta Tmp
        lda Mul6,x
        tax
        ldy Tmp
        lda #6
        sta Tmp
.loop   lda Tree,x
        and TreeMask,y
        sta Tree,x
        inx
        iny
        dec Tmp
        bne .loop
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

        ; bolt countdown; when it ends a struck tree starts burning
        lda BoltTimer
        beq .noBolt
        dec BoltTimer
        bne .noBolt
        jsr HideBolt
        lda BurnTree
        bmi .noBolt
        lda #BURN_FRAMES
        sta BurnTimer
.noBolt
        jsr BurnLogic

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
; Burning tree: erase canopy rows in stages, animate the flames.
        SUBROUTINE
BurnLogic
        lda BurnTimer
        bne .burning
        rts
.burning
        dec BurnTimer
        lda BurnTimer
        cmp #BURN_STAGE1
        bne .st2
        ldx #0
        jsr EraseRow
.st2    lda BurnTimer
        cmp #BURN_STAGE2
        bne .st3
        ldx #1
        jsr EraseRow
.st3    lda BurnTimer
        cmp #BURN_STAGE3
        bne .st4
        ldx #2
        jsr EraseRow
        ldx #3
        jsr EraseRow
        ldx BurnTree
        lda TreeAlive
        and TreeBitOff,x
        sta TreeAlive
.st4    lda BurnTimer
        bne .flameAnim
        lda #$FF                ; burnt out
        sta BurnTree
        jsr HideFlame
        lda #END_PAUSE
        ldx TreeAlive
        beq .setNext
        lda Rand
        and #$7F
        clc
        adc #MIN_GAP
.setNext
        sta NextStrike
        rts
.flameAnim
        lda Frame
        lsr
        lsr
        and #3
        tax
        lda FlameLo,x
        sta FlamePtr
        lda FlameHi,x
        sta FlamePtr+1
        ldx #FLAME_COLOR_A
        lda Frame
        and #1
        beq .fc
        ldx #FLAME_COLOR_B
.fc     stx COLUP0
        rts

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
        lda Rand
        and #1
        tax
        lda GroundX,x
        ldy #1
        jmp StartStrike
.toMain
        jsr InitTrees
        lda #STATE_MAIN
        sta State
        lda #FIRST_STRIKE
        sta NextStrike
.done   rts

;------------------------------------------------------------------------------
        SUBROUTINE
MainLogic
        jsr RandomFlash
        lda BoltTimer
        ora BurnTimer
        bne .done               ; a strike is in progress
        dec NextStrike
        bne .done
        lda TreeAlive
        beq .allBurnt
.pick   jsr NextRand            ; pick a random living tree
        lda Rand
        and #3
        cmp #3
        beq .pick
        tax
        lda TreeAlive
        and TreeBit,x
        beq .pick
        stx BurnTree
        lda TreeX,x
        ldy #0
        jmp StartStrike
.allBurnt
        lda #STATE_TITLE
        sta State
.done   rts

;------------------------------------------------------------------------------
        SUBROUTINE
SceneKernel
        lda SkyNow
        sta COLUBK
        lda CloudNow
        sta COLUPF
        ldx #SKY_TOP_LINES
        jsr SkipLines

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

        ; tree band: Y counts 0..TREE_LINES-1 for the bolt and flame tables
        ldy #0
        TREE_ROW CANOPY_COLOR, 0, CANOPY_LINES
        TREE_ROW CANOPY_COLOR, 1, CANOPY_LINES
        TREE_ROW CANOPY_COLOR, 2, CANOPY_LINES
        TREE_ROW CANOPY_COLOR, 3, CANOPY_LINES
        TREE_ROW TRUNK_COLOR, 4, TRUNK_LINES

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
Mul6        .byte 0,6,12,18,24
TreeBit     .byte $01,$02,$04
TreeBitOff  .byte $FE,$FD,$FB
TreeX       .byte 26,74,122     ; sprite x (8 wide) centred on tree columns 7,19,31
GroundX     .byte 50,98         ; between the trees
FlameLo     .byte <Flame0,<Flame1,<Flame2,<Flame3
FlameHi     .byte >Flame0,>Flame1,>Flame2,>Flame3

        align 256               ; keep text tables in one page (no page-cross cycles)
        include "rainstorm_text.inc"

        align 256
Zeros       ds SKY_LINES        ; blank sprite data; must cover the longest band
        include "rainstorm_gfx.inc"

        echo "ROM bytes free:", ($FFFC - *)d

        org $FFFC
        .word Reset
        .word Reset
