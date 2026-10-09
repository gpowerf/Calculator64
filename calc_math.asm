;---------------------------------------------------------------
; calc_math.asm
; GUI64 Calculator - decimal math module
;
; Numbers are 9 significant decimal digits plus a power-of-ten
; exponent. A number occupies 11 bytes:
;
;   +0      sign       (0 = positive, 1 = negative)
;   +1..9   mantissa   d1 d2 ... d9, most significant first,
;                      one digit (0..9) per byte
;   +10     exponent   signed byte, -99..99
;
;   value = 0.d1 d2 ... d9 * 10^exponent
;
; Normalized numbers have d1 != 0; the only unnormalized value is
; zero (all digits 0, sign and exponent 0).
;
; All arithmetic is decimal (digit-per-byte); no binary fractions
; are involved. Results keep 9 significant digits and are rounded
; half-up on the first dropped digit.
;
; Exponents are limited to -99..99; anything outside signals the
; error through the carry.
;---------------------------------------------------------------

NUM_SIGN        = 0
NUM_DIG         = 1
NUM_EXP         = 10
NUM_LEN         = NUM_EXP+1
EXPMAX          = 99
EXPMIN          = -99

;---------------------------------------------------------------
; Variables
;---------------------------------------------------------------
!zone CalcVars
NUM1            !fill NUM_LEN,0
NUM2            !fill NUM_LEN,0
Sign1 = NUM1+NUM_SIGN
Sign2 = NUM2+NUM_SIGN

ErrorFlag       !byte 0
Entering        !byte 0
DIGITVAL        !byte 0
Op              !byte 0
OPSET           !byte 0
DBGF            !byte 0
OPTMP           !byte 0
SSIGN           !byte 0          ; effective sign of 2nd operand
EMAX            !byte 0
SD              !byte 0
SignT           !byte 0
MCARRY          !byte 0
M_LEN           !byte 0
E16L            !byte 0
E16H            !byte 0
T0              !byte 0
T1              !byte 0
T2              !byte 0
T3              !byte 0
T4              !byte 0

; entry buffer
ENT_SIGN        !byte 0
ENT_LEN         !byte 0
ENT_DEC         !byte 0          ; digits entered after the point
ENT_DOT         !byte 0
ENT_FIRST       !byte 0
ENT_DIG         !fill 9,0

; scratch
DA              !fill 9,0        ; aligned mantissa of NUM1
DB              !fill 9,0        ; aligned mantissa of NUM2
DC              !fill 10,0       ; add/sub result (DC[0] = carry)
ACC             !fill 18,0       ; multiply accumulator (least sig first)
QD              !fill 11,0       ; division quotient digits
RCUR            !fill 10,0       ; division running remainder
BPAD            !fill 10,0       ; divisor padded to 10 digits
STRBUF          !fill 20,0

Str_Display     !fill 16,$20     ; 16-char display buffer
                !byte 0
Str_ErrorTxt    !pet "ERROR",0

; 10x10 decimal products
MULTAB
!for i, 0, 9 {
!for j, 0, 9 {
                !byte i*j
}
}
;---------------------------------------------------------------

;---------------------------------------------------------------
; ZeroNum: (ZP_FB) = 0
;---------------------------------------------------------------
ZeroNum         lda #0
                ldy #NUM_LEN-1
-               sta (ZP_FB),y
                dey
                bpl -
                rts

;---------------------------------------------------------------
; CopyNum: (ZP_FB) -> (ZP_FD)
;---------------------------------------------------------------
CopyNum         ldy #NUM_LEN-1
-               lda (ZP_FB),y
                sta (ZP_FD),y
                dey
                bpl -
                rts

;---------------------------------------------------------------
; CopyN2N1: NUM1 = NUM2 (whole 11-byte structure)
;---------------------------------------------------------------
CopyN2N1        ldx #NUM_LEN-1
-               lda NUM2,x
                sta NUM1,x
                dex
                bpl -
                rts

;---------------------------------------------------------------
; IsZeroNum: (ZP_FB); Z=1 if mantissa is all zero
;---------------------------------------------------------------
IsZeroNum       ldy #NUM_DIG
                lda #0
-               ora (ZP_FB),y
                iny
                cpy #NUM_DIG+9
                bne -
                cmp #0                  ; Z from the accumulated digits
                rts

;---------------------------------------------------------------
; SetPtrNum1 / SetPtrNum2: ZP_FB = NUM1 / NUM2
;---------------------------------------------------------------
SetPtrNum1      lda #<NUM1
                sta ZP_FB
                lda #>NUM1
                sta ZP_FC
                rts
SetPtrNum2      lda #<NUM2
                sta ZP_FB
                lda #>NUM2
                sta ZP_FC
                rts

;---------------------------------------------------------------
; ChkExp: A = exponent, C=1 if outside -99..99
;---------------------------------------------------------------
ChkExp          cmp #$80
                bcc ce_pos
                ; negative: valid -99..-1 = $9d..$ff
                cmp #(EXPMIN & $ff)
                bcs ce_ok
                jmp ce_bad
ce_pos          cmp #EXPMAX+1
                bcs ce_bad
ce_ok           clc
                rts
ce_bad          sec
                rts

;---------------------------------------------------------------
; ShrArr: right shift the 9-byte array at (ZP_FB) by X digits
; (digits shifted out are dropped)
;---------------------------------------------------------------
ShrArr          stx SD
                cpx #9
                bcs sr_clr
                lda #8
                sta T1                  ; i = 8
sr_lp           lda T1
                sec
                sbc SD
                bcc sr_fill
                tay
                lda (ZP_FB),y
                sta T0
                ldy T1
                lda T0
                sta (ZP_FB),y
                dec T1
                bpl sr_lp
                rts
sr_fill         ldy T1
                lda #0
                sta (ZP_FB),y
                dec T1
                bpl sr_fill
                rts
sr_clr          ldy #8
                lda #0
-               sta (ZP_FB),y
                dey
                bpl -
                rts

;---------------------------------------------------------------
; ShlArr: left shift the 9-byte array at (ZP_FB) by X digits
;---------------------------------------------------------------
ShlArr          cpx #0
                beq sl_done
                stx SD
                lda #0
                sta T1                  ; i = 0
sl_lp           lda T1
                clc
                adc SD
                cmp #9
                bcs sl_zero
                tay
                lda (ZP_FB),y
                sta T0
                ldy T1
                lda T0
                sta (ZP_FB),y
                inc T1
                jmp sl_lp
sl_zero         ldy T1
                lda #0
                sta (ZP_FB),y
                inc T1
                lda T1
                cmp #9
                bne sl_zero
sl_done         rts

;---------------------------------------------------------------
; Entry buffer
;---------------------------------------------------------------
EntReset        lda #0
                sta ENT_SIGN
                sta ENT_LEN
                sta ENT_DEC
                sta ENT_DOT
                ldx #8
-               sta ENT_DIG,x
                dex
                bpl -
                rts

AccumDigit      ldx ENT_LEN
                cpx #9
                bcs ad_rts              ; buffer full, ignore
                sta ENT_DIG,x
                inc ENT_LEN
                lda ENT_DOT
                beq ad_rts
                inc ENT_DEC
ad_rts          rts

AccumPoint      lda ENT_DOT
                bne ap_rts
                lda #1
                sta ENT_DOT
ap_rts          rts

;---------------------------------------------------------------
; CommitEntry: NUM2 = entry value
;---------------------------------------------------------------
CommitEntry     lda #0
                sta Sign2
                ldx #0
ce_scn          cpx ENT_LEN
                beq ce_zero
                lda ENT_DIG,x
                bne ce_found
                inx
                jmp ce_scn
ce_found        stx ENT_FIRST
                lda ENT_SIGN
                sta Sign2
                ldy #NUM_DIG
ce_cpy          cpx ENT_LEN
                beq ce_pad
                lda ENT_DIG,x
                sta NUM2,y
                inx
                iny
                jmp ce_cpy
ce_pad          cpy #NUM_DIG+9
                beq ce_exp
                lda #0
                sta NUM2,y
                iny
                jmp ce_pad
ce_exp          lda ENT_LEN
                sec
                sbc ENT_FIRST
                sec
                sbc ENT_DEC
                sta NUM2+NUM_EXP
                rts
ce_zero         lda #0
                sta NUM2+NUM_EXP
                ldx #8
-               sta NUM2+NUM_DIG,x
                dex
                bpl -
                rts

;---------------------------------------------------------------
; ClearCalc: reset all calculator state
;---------------------------------------------------------------
ClearCalc       jsr SetPtrNum1
                jsr ZeroNum
                jsr SetPtrNum2
                jsr ZeroNum
                lda #0
                sta ErrorFlag
                jmp EntReset

;---------------------------------------------------------------
; CmpMag: compare mantissas of (ZP_FB) and (ZP_FD)
; C=1 if A >= B
;---------------------------------------------------------------
CmpMag          ldy #0
                ldx #9
-               lda (ZP_FB),y
                cmp (ZP_FD),y
                bne +
                iny
                dex
                bne -
+               rts

;---------------------------------------------------------------
; AddMag: DC = DA + DB (digit arrays, 10 bytes, carry in DC[0])
;---------------------------------------------------------------
AddMag          ldx #8
                clc
am_lp           lda DA,x
                adc DB,x
                cmp #10
                bcc am_st
                sbc #10
                jmp am_st2
am_st           clc
am_st2          sta DC+1,x
                dex
                bpl am_lp
                lda #0
                adc #0                  ; carry out
                sta DC
                rts

;---------------------------------------------------------------
; SubMag: DC+1..9 = DA - DB (assumes DA >= DB)
;---------------------------------------------------------------
SubMag          ldx #8
                sec
-               lda DA,x
                sbc DB,x
                bcs +
                adc #10
                clc                     ; keep the borrow for the next digit
+               sta DC+1,x
                dex
                bpl -
                rts

;---------------------------------------------------------------
; SwapDADB: exchange DA and DB
;---------------------------------------------------------------
SwapDADB        ldx #8
-               lda DA,x
                sta T0
                lda DB,x
                sta DA,x
                lda T0
                sta DB,x
                dex
                bpl -
                rts

;---------------------------------------------------------------
; IncMant2: increment NUM2 mantissa; C=1 on carry out
;---------------------------------------------------------------
IncMant2        ldx #8
-               inc NUM2+NUM_DIG,x
                lda NUM2+NUM_DIG,x
                cmp #10
                bcc inc_ok
                lda #0
                sta NUM2+NUM_DIG,x
                dex
                bpl -
                sec
                rts
inc_ok          clc
                rts

;---------------------------------------------------------------
; Compute: A = op (1 add, 2 sub, 3 mul, 4 div)
; NUM2 = NUM1 op NUM2; C=1 on error, C=0 on success
;---------------------------------------------------------------
Compute         sta OPTMP
                cmp #3
                beq j_mul
                cmp #4
                beq j_div
                ; ---- add / sub ----
                lda Sign2
                ldx OPTMP
                cpx #2
                bne +
                eor #1                  ; subtraction flips operand 2
+               sta SSIGN
                jmp AddSub
j_mul           jmp MulNum
j_div           jmp DivNum

;---------------------------------------------------------------
; AddSub
;---------------------------------------------------------------
AddSub          jsr SetPtrNum1
                jsr IsZeroNum
                bne as_n1nz
                ; NUM1 = 0 -> result is +/- NUM2
                jsr SetPtrNum2
                jsr IsZeroNum
                bne +
                lda #0                  ; 0 +/- 0 = +0
                sta Sign2
                clc
                rts
+               lda SSIGN
                sta Sign2
                clc
                rts
as_n1nz         jsr SetPtrNum2
                jsr IsZeroNum
                bne as_both
                ; NUM2 = 0 -> result is NUM1
                jsr SetPtrNum1
                lda #<NUM2
                sta ZP_FD
                lda #>NUM2
                sta ZP_FE
                jsr CopyNum
                clc
                rts
as_both         ; EMAX = max(e1,e2)  (signed compare)
                lda NUM1+NUM_EXP
                cmp NUM2+NUM_EXP
                bvc +
                eor #$80
+               bmi as_e2big
                lda NUM1+NUM_EXP
                sta EMAX
                jmp as_align
as_e2big        lda NUM2+NUM_EXP
                sta EMAX
as_align        ; DA / DB = mantissas
                ldx #8
-               lda NUM1+NUM_DIG,x
                sta DA,x
                lda NUM2+NUM_DIG,x
                sta DB,x
                dex
                bpl -
                ; align both to EMAX
                lda EMAX
                sec
                sbc NUM1+NUM_EXP
                tax
                lda #<DA
                sta ZP_FB
                lda #>DA
                sta ZP_FC
                jsr ShrArr
                lda EMAX
                sec
                sbc NUM2+NUM_EXP
                tax
                lda #<DB
                sta ZP_FB
                lda #>DB
                sta ZP_FC
                jsr ShrArr
                ; same effective sign?
                lda NUM1+NUM_SIGN
                cmp SSIGN
                bne as_sub
                ; ---- magnitudes add ----
                jsr AddMag
                lda DC
                beq as_nocarry
                ; carry: digits = DC[0..8], exp = EMAX+1
                ldx #0
-               lda DC,x
                sta NUM2+NUM_DIG,x
                inx
                cpx #9
                bne -
                lda EMAX
                clc
                adc #1
                jsr ChkExp
                bcc +
                jmp as_err
+               sta NUM2+NUM_EXP
                jmp as_sign1
as_nocarry      ldx #0
-               lda DC+1,x
                sta NUM2+NUM_DIG,x
                inx
                cpx #9
                bne -
                lda EMAX
                sta NUM2+NUM_EXP
as_sign1        lda NUM1+NUM_SIGN
                sta Sign2
                clc
                rts
as_sub          ; ---- magnitudes subtract ----
                lda #<DA
                sta ZP_FB
                lda #>DA
                sta ZP_FC
                lda #<DB
                sta ZP_FD
                lda #>DB
                sta ZP_FE
                jsr CmpMag
                bcc as_swap
                jsr SubMag              ; DA - DB
                lda NUM1+NUM_SIGN
                sta SignT
                jmp as_renorm
as_swap         jsr SwapDADB
                jsr SubMag              ; DB - DA
                lda SSIGN
                sta SignT
as_renorm       ; leading zeros -> shift left
                ldx #0
ar_fnd          cpx #9
                beq as_zero
                lda DC+1,x
                bne ar_have
                inx
                jmp ar_fnd
ar_have         stx SD
                lda #<DC+1
                sta ZP_FB
                lda #>DC+1
                sta ZP_FC
                jsr ShlArr
                ldx #8
-               lda DC+1,x
                sta NUM2+NUM_DIG,x
                dex
                bpl -
                lda EMAX
                sec
                sbc SD
                jsr ChkExp
                bcc +
                jmp as_err
+               sta NUM2+NUM_EXP
                lda SignT
                sta Sign2
                clc
                rts
as_zero         lda #0
                sta Sign2
                sta NUM2+NUM_EXP
                ldx #8
-               sta NUM2+NUM_DIG,x
                dex
                bpl -
                clc
                rts
as_err          sec
                rts

;---------------------------------------------------------------
; MulNum: NUM2 = NUM1 * NUM2
;---------------------------------------------------------------
MulNum          jsr SetPtrNum1
                jsr IsZeroNum
                bne +
                jmp mul_zero
+               jsr SetPtrNum2
                jsr IsZeroNum
                bne +
                jmp mul_zero
+               lda NUM1+NUM_SIGN
                eor NUM2+NUM_SIGN
                sta SignT
                ; mantissas
                ldx #8
-               lda NUM1+NUM_DIG,x
                sta DA,x
                lda NUM2+NUM_DIG,x
                sta DB,x
                dex
                bpl -
                ; ACC = 0
                ldx #17
                lda #0
-               sta ACC,x
                dex
                bpl -
                ; schoolbook multiply
                lda #8
                sta T4                  ; k
mn_k            ldy T4
                lda DA,y
                sta T0
                asl
                asl
                asl
                clc
                adc T0
                adc T0                  ; DA[k]*10
                sta T1
                lda #0
                sta MCARRY
                lda #8
                sta T2                  ; l
mn_l            ldy T2
                lda T1
                clc
                adc DB,y
                tay
                lda MULTAB,y            ; DA[k]*DB[l]
                sta T3
                lda #16
                sec
                sbc T4
                sec
                sbc T2
                sta T0                  ; ACC index k'+l'
                tay
                lda ACC,y
                clc
                adc T3
                adc MCARRY
                ldx #0
mn_red          cmp #10
                bcc mn_st
                sbc #10
                inx
                jmp mn_red
mn_st           sta ACC,y
                stx MCARRY
                dec T2
                bpl mn_l
                ; propagate the row's final carry into ACC[17-k]
                lda #17
                sec
                sbc T4
                tay
                lda MCARRY
                beq mn_kdone
mn_prop         clc
                adc ACC,y
                cmp #10
                bcc mn_pst
                sbc #10
                sta ACC,y
                lda #1
                iny
                cpy #18
                bcs mn_kdone
                jmp mn_prop
mn_pst          sta ACC,y
mn_kdone        dec T4
                bmi mn_kend
                jmp mn_k
mn_kend         ; find most significant digit
                ldy #17
mn_fnd          lda ACC,y
                bne mn_have
                dey
                bpl mn_fnd
                jmp mul_zero
mn_have         sty T4                  ; h
                ; digits d1..d9 = ACC[h], ACC[h-1], ...
                ldx #0
mn_dig          tya
                bmi mn_pad
                lda ACC,y
                jmp mn_put
mn_pad          lda #0
mn_put          sta NUM2+NUM_DIG,x
                inx
                cpx #9
                beq mn_rnd
                dey
                jmp mn_dig
mn_rnd          lda T4
                sec
                sbc #9
                bmi mn_exp
                tay
                lda ACC,y
                cmp #5
                bcc mn_exp
                jsr IncMant2
                bcc mn_exp
                ; 999999999 + 1 -> 100000000 * 10^1
                lda #1
                sta NUM2+NUM_DIG
                ldx #1
-               lda #0
                sta NUM2+NUM_DIG,x
                inx
                cpx #9
                bne -
                inc E16L
mn_exp          ; exp = e1 + e2 - 17 + h
                lda NUM1+NUM_EXP
                ldx #0
                cmp #$80
                bcc +
                ldx #$ff
+               clc
                adc NUM2+NUM_EXP
                sta E16L
                txa
                adc #0
                sta E16H
                ; sign-extend and add (h-17)
                lda T4
                sec
                sbc #17
                ldx #0
                cmp #$80
                bcc +
                ldx #$ff
+               clc
                adc E16L
                sta E16L
                txa
                adc E16H
                sta E16H
                jsr ChkE16
                bcs mul_err
                lda E16L
                sta NUM2+NUM_EXP
                lda SignT
                sta Sign2
                clc
                rts
mul_err         sec
                rts
mul_zero        lda #0
                sta Sign2
                sta NUM2+NUM_EXP
                ldx #8
-               sta NUM2+NUM_DIG,x
                dex
                bpl -
                clc
                rts

;---------------------------------------------------------------
; DivNum: NUM2 = NUM1 / NUM2
;---------------------------------------------------------------
DivNum          jsr SetPtrNum2
                jsr IsZeroNum
                bne +
                jmp div_err             ; division by zero
+               jsr SetPtrNum1
                jsr IsZeroNum
                bne +
                jmp mul_zero            ; 0 / x = +0
+               lda NUM1+NUM_SIGN
                eor NUM2+NUM_SIGN
                sta SignT
                ; mantissas
                ldx #8
-               lda NUM1+NUM_DIG,x
                sta DA,x
                lda NUM2+NUM_DIG,x
                sta DB,x
                dex
                bpl -
                ; BPAD = 0, DB
                lda #0
                sta BPAD
                ldx #8
-               lda DB,x
                sta BPAD+1,x
                dex
                bpl -
                ; RCUR = 0, DA
                lda #0
                sta RCUR
                ldx #8
-               lda DA,x
                sta RCUR+1,x
                dex
                bpl -
                ; 11 quotient digits
                ldx #0
dv_step         stx T4
                cpx #0
                beq dv_noshift          ; first step: RCUR = A already
                ; RCUR *= 10
                ldy #0
-               lda RCUR+1,y
                sta RCUR,y
                iny
                cpy #9
                bne -
                lda #0
                sta RCUR+9
dv_noshift      ; q = 0; while RCUR >= BPAD: RCUR -= BPAD; q++
                lda #0
                sta T3
dv_q            jsr CmpRcurBpad
                bcc dv_store
                jsr SubRcurBpad
                inc T3
                lda T3
                cmp #10
                bne dv_q
dv_store        ldy T4
                lda T3
                sta QD,y
                inc T4
                ldx T4
                cpx #11
                bne dv_step
                ; mantissa choice
                lda QD
                beq dv_frac
                ; q0 != 0: digits = QD[0..8], round = QD[9], exp = e1-e2+1
                ldx #0
-               lda QD,x
                sta NUM2+NUM_DIG,x
                inx
                cpx #9
                bne -
                lda QD+9
                sta T3                  ; round digit
                lda NUM1+NUM_EXP
                sec
                sbc NUM2+NUM_EXP
                clc
                adc #1
                jmp dv_round
dv_frac         ; q0 = 0: digits = QD[1..9], round = QD[10], exp = e1-e2
                ldx #0
-               lda QD+1,x
                sta NUM2+NUM_DIG,x
                inx
                cpx #9
                bne -
                lda QD+10
                sta T3
                lda NUM1+NUM_EXP
                sec
                sbc NUM2+NUM_EXP
dv_round        sta E16L                 ; new exponent (range -99..99)
                lda T3
                cmp #5
                bcc dv_chk
                jsr IncMant2
                bcc dv_chk
                ; 999999999 + 1
                lda #1
                sta NUM2+NUM_DIG
                ldx #1
-               lda #0
                sta NUM2+NUM_DIG,x
                inx
                cpx #9
                bne -
                inc E16L
dv_chk          lda E16L
                jsr ChkExp
                bcs div_err
                sta NUM2+NUM_EXP
                lda SignT
                sta Sign2
                clc
                rts
div_err         sec
                rts

;---------------------------------------------------------------
; CmpRcurBpad: C=1 if RCUR >= BPAD (10-digit arrays)
;---------------------------------------------------------------
CmpRcurBpad     ldx #0
-               lda RCUR,x
                cmp BPAD,x
                bne +
                inx
                cpx #10
                bne -
+               rts

;---------------------------------------------------------------
; SubRcurBpad: RCUR -= BPAD (assumes RCUR >= BPAD)
;---------------------------------------------------------------
SubRcurBpad     ldx #9
                sec
-               lda RCUR,x
                sbc BPAD,x
                bcs +
                adc #10
                clc                     ; keep the borrow for the next digit
+               sta RCUR,x
                dex
                bpl -
                rts

;---------------------------------------------------------------
; ChkE16: C=1 if signed 16-bit E16 (E16H:E16L) outside -99..99
;---------------------------------------------------------------
ChkE16          ldx E16H
                cpx #0
                bne +
                lda E16L
                cmp #EXPMAX+1
                bcs ce16_bad
                clc
                rts
+               cpx #$ff
                bne ce16_bad
                lda E16L
                cmp #(EXPMIN & $ff)
                bcc ce16_bad
                clc
                rts
ce16_bad        sec
                rts

;---------------------------------------------------------------
; Display formatting
;---------------------------------------------------------------
ClearDisplay    ldx #15
                lda #$20
-               sta Str_Display,x
                dex
                bpl -
                lda #0
                sta Str_Display+16
                rts

PutC            sta STRBUF,x
                inx
                rts

PlaceStr        ; X = length, right-align STRBUF into Str_Display
                stx T0
                lda #16
                sec
                sbc T0
                sta T1                  ; start index
                ldy #0
ps_lp           cpy T0
                beq ps_done
                lda STRBUF,y
                ldx T1
                sta Str_Display,x
                inc T1
                iny
                jmp ps_lp
ps_done         rts

;---------------------------------------------------------------
; PutDigitY: append the number digit at index Y (ZP_FB points to
; the number); Y preserved
;---------------------------------------------------------------
PutDigitY       sty T4
                tya
                clc
                adc #NUM_DIG
                tay
                lda (ZP_FB),y
                clc
                adc #$30                ; digit -> ASCII
                jsr PutC
                ldy T4
                rts

;---------------------------------------------------------------
; NumToStr: (ZP_FB) -> Str_Display (16 chars, right aligned)
;---------------------------------------------------------------
NumToStr        jsr ClearDisplay
                jsr IsZeroNum
                bne nts_nz
                ldx #0
                lda #$30                ; "0"
                jsr PutC
                jmp PlaceStr
nts_nz          ; M_LEN = significant digits (no trailing zeros)
                lda #9
                sta M_LEN
nts_tr          ldy M_LEN
                dey
                tya
                clc
                adc #NUM_DIG
                tay
                lda (ZP_FB),y
                bne nts_have
                dec M_LEN
                jmp nts_tr
nts_have        ldy #NUM_EXP
                lda (ZP_FB),y
                sta T1                  ; exponent
                ldy #NUM_SIGN
                lda (ZP_FB),y
                sta T2                  ; sign
                ; plain length
                lda T1
                beq nts_frac_ln
                bmi nts_frac_ln
                cmp M_LEN
                bcs nts_int_ln
                lda M_LEN
                clc
                adc #1
                jmp nts_ln
nts_int_ln      lda T1
                jmp nts_ln
nts_frac_ln     lda #2
                sec
                sbc T1                  ; 2 - exponent
                clc
                adc M_LEN
nts_ln          sta T0
                ldx T2
                beq +
                inc T0
+               lda T0
                cmp #17
                bcc nts_plain
                jmp nts_sci
nts_plain       ldx #0
                lda T2
                beq +
                lda #$2d                ; "-"
                jsr PutC
+               lda T1
                beq nts_p_frac
                bmi nts_p_frac
                cmp M_LEN
                bcs nts_p_int
                sta T3                  ; 0 < E < M_LEN
                ldy #0
nts_pa          cpy T3
                beq nts_p_dot
                jsr PutDigitY
                iny
                jmp nts_pa
nts_p_dot       lda #$2e                ; "."
                jsr PutC
nts_pb          cpy M_LEN
                bne sk_1
                jmp PlaceStr
sk_1
                jsr PutDigitY
                iny
                jmp nts_pb
nts_p_int       ; E >= M_LEN: digits then zeros
                ldy #0
nts_pi1         cpy M_LEN
                beq nts_pi2
                jsr PutDigitY
                iny
                jmp nts_pi1
nts_pi2         lda M_LEN
                sta T3
nts_pi3         lda T3
                cmp T1
                bne sk_2
                jmp PlaceStr
sk_2
                lda #$30
                jsr PutC
                inc T3
                jmp nts_pi3
nts_p_frac      ; E <= 0: "0." + (-E) zeros + digits
                lda #$30
                jsr PutC
                lda #$2e
                jsr PutC
                lda #0
                sec
                sbc T1
                sta T3                  ; number of zeros
                ldy #0
nts_pf1         cpy T3
                beq nts_pf2
                lda #$30
                jsr PutC
                iny
                jmp nts_pf1
nts_pf2         ldy #0
nts_pf3         cpy M_LEN
                bne sk_3
                jmp PlaceStr
sk_3
                jsr PutDigitY
                iny
                jmp nts_pf3
nts_sci         ldx #0
                lda T2
                beq +
                lda #$2d
                jsr PutC
+               ldy #0
                jsr PutDigitY
                lda M_LEN
                cmp #2
                bcc nts_sc_e
                lda #$2e
                jsr PutC
                ldy #1
nts_sc_d        cpy M_LEN
                beq nts_sc_e
                jsr PutDigitY
                iny
                jmp nts_sc_d
nts_sc_e        lda #$45                ; "E"
                jsr PutC
                lda T1
                sec
                sbc #1
                sta T3
                bpl +
                lda #$2d
                jsr PutC
                lda #0
                sec
                sbc T3
                sta T3
+               lda T3
                cmp #100
                bcc nts_no100
                lda #$31                ; "1"
                jsr PutC
                lda T3
                sec
                sbc #100
                sta T3
nts_no100       lda T3
                cmp #10
                bcc nts_one
                lda #0
                sta T4                  ; tens counter (X holds the string index)
                lda T3
nts_tens        inc T4
                sec
                sbc #10
                cmp #10
                bcs nts_tens
                sta T3
                lda T4
                clc
                adc #$30
                jsr PutC
nts_one         lda T3
                clc
                adc #$30
                jsr PutC
                jmp PlaceStr

;---------------------------------------------------------------
; EntToStr: entry buffer -> Str_Display
;---------------------------------------------------------------
EntToStr        jsr ClearDisplay
                ldx #0
                lda ENT_SIGN
                beq +
                lda #$2d
                jsr PutC
+               lda ENT_LEN
                bne etn_go
                lda #$30
                jsr PutC
                lda ENT_DOT
                beq etn_place
                lda #$2e
                jsr PutC
etn_place       jmp PlaceStr
etn_go          lda ENT_LEN
                sec
                sbc ENT_DEC
                beq etn_frac
                bmi etn_frac
                sta T0                  ; integer digits
                ldy #0
etn_i           cpy T0
                beq etn_i_dot
                jsr PutEntDigitY
                iny
                jmp etn_i
etn_i_dot       lda ENT_DEC
                beq etn_trail
                lda #$2e
                jsr PutC
etn_f           cpy ENT_LEN
                beq etn_place
                jsr PutEntDigitY
                iny
                jmp etn_f
etn_trail       lda ENT_DOT
                beq etn_place
                lda #$2e
                jsr PutC
                jmp etn_place
etn_frac        ; "0." + zeros + all digits
                lda #$30
                jsr PutC
                lda #$2e
                jsr PutC
                lda ENT_DEC
                sec
                sbc ENT_LEN
                sta T0
                ldy #0
etn_z           cpy T0
                beq etn_z2
                lda #$30
                jsr PutC
                iny
                jmp etn_z
etn_z2          ldy #0
etn_f2          cpy ENT_LEN
                beq etn_place
                jsr PutEntDigitY
                iny
                jmp etn_f2

PutEntDigitY    sty T4
                lda ENT_DIG,y
                clc
                adc #$30                ; digit -> ASCII
                jsr PutC
                ldy T4
                rts
