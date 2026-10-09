;---------------------------------------------------------------
; test_math.asm
; Standalone test harness for the calculator math module
; (decimal engine). Runs a table of compute tests plus some
; entry/format tests and prints all results on screen,
; two per row. Loops forever at the end.
;
; Build: acme test_math.asm -> testmath.prg
; Run:   x64 -autostart testmath.prg
;---------------------------------------------------------------

!to "testmath.prg",cbm

!source "gui64.inc.asm"

SCR             = $0400
SCRPTR          = $5d                   ; 2 zero-page bytes for the screen ptr

; BASIC stub: "10 SYS 2062"
*=$0801
                !byte $0e,$08
                !byte 10,0
                !byte $9e
                !pet "2062"
                !byte 0
                !byte 0,0

*=$080e

!zone TestHarness
                cld
                lda #<SCR
                sta SCRPTR
                lda #>SCR
                sta SCRPTR+1
                ; clear the screen
                lda #$20
                ldx #0
-               sta SCR,x
                sta SCR+250,x
                sta SCR+500,x
                sta SCR+750,x
                inx
                cpx #250
                bne -
                ; ---------------- compute tests ----------------
                lda #<TestTable
                sta ZP_5F
                lda #>TestTable
                sta ZP_60
th_loop         ldy #0
                ldx #0
-               lda (ZP_5F),y
                sta NUM1,x
                iny
                inx
                cpx #NUM_LEN
                bne -
                ldx #0
-               lda (ZP_5F),y
                sta NUM2,x
                iny
                inx
                cpx #NUM_LEN
                bne -
                lda (ZP_5F),y
                cmp #$ff
                beq th_entry
                pha
                lda #0
                sta ErrorFlag
                pla
                jsr Compute
                bcc +
                lda #1
                sta ErrorFlag
+               jsr DisplayResult
                lda ZP_5F
                clc
                adc #(2*NUM_LEN+1)
                sta ZP_5F
                bcc th_loop
                inc ZP_60
                jmp th_loop

                ; ---------------- entry / format tests ----------------
th_entry        jsr EntReset            ; t1: "1.5"
                lda #1
                jsr AccumDigit
                jsr AccumPoint
                lda #5
                jsr AccumDigit
                jsr EntToStr
                jsr PrintRow
                jsr EntReset            ; t2: ".007"
                jsr AccumPoint
                lda #0
                jsr AccumDigit
                lda #0
                jsr AccumDigit
                lda #7
                jsr AccumDigit
                jsr EntToStr
                jsr PrintRow
                jsr EntReset            ; t3: "42."
                lda #4
                jsr AccumDigit
                lda #2
                jsr AccumDigit
                jsr AccumPoint
                jsr EntToStr
                jsr PrintRow
                jsr EntReset            ; t4: commit "1.5" -> NUM2
                lda #1
                jsr AccumDigit
                jsr AccumPoint
                lda #5
                jsr AccumDigit
                jsr CommitEntry
                jsr SetPtrNum2
                jsr NumToStr
                jsr PrintRow
th_done         jmp th_done

;---------------------------------------------------------------
DisplayResult   lda ErrorFlag
                beq +
                ldx #15
                lda #$20
-               sta Str_Display,x
                dex
                bpl -
                ldx #0
-               lda Str_ErrorTxt,x
                sta Str_Display+11,x
                inx
                cpx #5
                bne -
                jmp PrintRow
+               jsr SetPtrNum2
                jsr NumToStr
                jmp PrintRow

PrintRow        ldy #0
-               lda Str_Display,y
                sta (SCRPTR),y
                iny
                cpy #16
                bne -
                lda SCRPTR
                clc
                adc #20
                sta SCRPTR
                bcc +
                inc SCRPTR+1
+               rts

;---------------------------------------------------------------
; Math module
;---------------------------------------------------------------
!source "calc_math.asm"

;---------------------------------------------------------------
;---------------------------------------------------------------
; Test table: NUM1 (11 bytes), NUM2 (11 bytes), op
; NUM = sign, 9 digits, exp
;---------------------------------------------------------------
TestTable
                ;1: 1.5 + 2.25 = 3.75
                !byte 0, 1,5,0,0,0,0,0,0,0, 1
                !byte 0, 2,2,5,0,0,0,0,0,0, 1
                !byte 1
                ;2: 0.1 + 0.2 = 0.3
                !byte 0, 1,0,0,0,0,0,0,0,0, 0
                !byte 0, 2,0,0,0,0,0,0,0,0, 0
                !byte 1
                ;3: 5 / 2 = 2.5
                !byte 0, 5,0,0,0,0,0,0,0,0, 1
                !byte 0, 2,0,0,0,0,0,0,0,0, 1
                !byte 4
                ;4: 1 / 3 = 0.333333333
                !byte 0, 1,0,0,0,0,0,0,0,0, 1
                !byte 0, 3,0,0,0,0,0,0,0,0, 1
                !byte 4
                ;5: 2 / 3 = 0.666666667
                !byte 0, 2,0,0,0,0,0,0,0,0, 1
                !byte 0, 3,0,0,0,0,0,0,0,0, 1
                !byte 4
                ;6: -7 / 2 = -3.5
                !byte 1, 7,0,0,0,0,0,0,0,0, 1
                !byte 0, 2,0,0,0,0,0,0,0,0, 1
                !byte 4
                ;7: 7 * 2.5 = 17.5
                !byte 0, 7,0,0,0,0,0,0,0,0, 1
                !byte 0, 2,5,0,0,0,0,0,0,0, 1
                !byte 3
                ;8: 0.5 * 0.5 = 0.25
                !byte 0, 5,0,0,0,0,0,0,0,0, 0
                !byte 0, 5,0,0,0,0,0,0,0,0, 0
                !byte 3
                ;9: 1 - 0.999999999 = 0.000000001
                !byte 0, 1,0,0,0,0,0,0,0,0, 1
                !byte 0, 9,9,9,9,9,9,9,9,9, 0
                !byte 2
                ;10: 999999999 + 1 = 1000000000
                !byte 0, 9,9,9,9,9,9,9,9,9, 9
                !byte 0, 1,0,0,0,0,0,0,0,0, 1
                !byte 1
                ;11: 100 / 7 = 14.2857143
                !byte 0, 1,0,0,0,0,0,0,0,0, 3
                !byte 0, 7,0,0,0,0,0,0,0,0, 1
                !byte 4
                ;12: 1 / 0 = ERROR
                !byte 0, 1,0,0,0,0,0,0,0,0, 1
                !byte 0, 0,0,0,0,0,0,0,0,0, 0
                !byte 4
                ;13: -0.5 + 0.25 = -0.25
                !byte 1, 5,0,0,0,0,0,0,0,0, 0
                !byte 0, 2,5,0,0,0,0,0,0,0, 0
                !byte 1
                ;14: 1000000 * 1000000 = 1000000000000
                !byte 0, 1,0,0,0,0,0,0,0,0, 7
                !byte 0, 1,0,0,0,0,0,0,0,0, 7
                !byte 3
                ;15: 1.23 - 1.23 = 0
                !byte 0, 1,2,3,0,0,0,0,0,0, 1
                !byte 0, 1,2,3,0,0,0,0,0,0, 1
                !byte 2
                ;16: 99999999.9 + 0.1 = 1000000000
                !byte 0, 9,9,9,9,9,9,9,9,9, 8
                !byte 0, 1,0,0,0,0,0,0,0,0, 0
                !byte 1
                ; sentinel
                !byte 0,0,0,0,0,0,0,0,0,0,0
                !byte 0,0,0,0,0,0,0,0,0,0,0
                !byte $ff
