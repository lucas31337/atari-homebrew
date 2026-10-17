;==============================================================================
; BANK 0 of RAINSTORM (file offset 0): the TIATracker music player and the songs.
; Included by rainstorm.asm, which defines the tt_* variables and the stubs'
; bank-1 halves.  Both banks start with the same stubs at the same addresses:
; bank 1's MusicPlay/MusicStart do sta BANK0, the CPU then fetches the next
; instruction from here, and sta BANK1 below returns it to bank 1's rts.
; A power-up in this bank runs Reset's sta BANK1 and continues in bank 1.
;==============================================================================
        seg Bank0
        org $1000
        rorg $F000
        ds 3                    ; $F000 MusicPlay:  sta BANK0 (bank 1)
        jsr tt_Player           ; $F003
        sta BANK1               ; $F006
        ds 1                    ; $F009             rts (bank 1)
        ds 3                    ; $F00A MusicStart: sta BANK0 (bank 1)
        jsr MusicInit           ; $F00D
        sta BANK1               ; $F010
        ds 1                    ; $F013             rts (bank 1)
Reset0  sta BANK1               ; $F014 Reset: the same instruction in both banks

; A = song number (SONG_*): start it from its first row.  The channels stay
; silent until the song's first notes.
MusicInit
        tay
        lda SongC0,y
        sta tt_cur_pat_index_c0
        lda SongC1,y
        sta tt_cur_pat_index_c1
        lda #0
        sta tt_timer            ; the next MusicPlay fetches the first row
        sta tt_cur_note_index_c0
        sta tt_cur_note_index_c1
        sta tt_cur_ins_c0       ; no note yet (TT_STARTS_WITH_NOTES = 0)
        sta tt_cur_ins_c1
        sta AUDV0
        sta AUDV1
        rts

        include "rainstorm_music.inc"   ; TT_* flags, instruments, patterns, sequences
        include "tt_player.asm"         ; tt_Player (written to be inlined: no rts of its own)
        rts

        echo "Bank 0 bytes free:", ($FFF8 - *)d

        rend
        org $1FFC
        rorg $FFFC
        .word Reset0
        .word Reset0
        rend
