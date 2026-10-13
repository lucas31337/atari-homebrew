; hello.asm - minimal 4K Atari 2600 ROM: scrolling rainbow background
        processor 6502
        include "vcs.h"
        include "macro.h"

        seg.u Vars
        org $80
Frame   ds 1

        seg Code
        org $F000

Reset   CLEAN_START

NextFrame
        VERTICAL_SYNC           ; 3 lines of VSYNC

        ldx #37                 ; 37 lines of VBLANK
VBlank  sta WSYNC
        dex
        bne VBlank
        lda #0
        sta VBLANK              ; turn beam on

        inc Frame
        ldx #192                ; 192 visible scanlines
        ldy Frame
Kernel  sty COLUBK
        sta WSYNC
        iny
        dex
        bne Kernel

        lda #2
        sta VBLANK              ; turn beam off
        ldx #30                 ; 30 lines of overscan
Overscan sta WSYNC
        dex
        bne Overscan
        jmp NextFrame

        org $FFFC
        .word Reset             ; reset vector
        .word Reset             ; IRQ/BRK vector
