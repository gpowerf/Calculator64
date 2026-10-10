;---------------------------------------------------------------
; Calculator - a GUI64 app
;
; A 32-bit signed integer calculator for GUI64 2.1.
; Operations: + - * / (integer division), +/-, C (clear), =.
; Input: mouse (buttons) or keyboard (0-9, + - * /, = or
; RETURN, C/c for clear).
;
; Build: acme -o calculator.gui Calculator.asm (see build.sh)
;---------------------------------------------------------------

!source "gui64.inc.asm"

!zone Constants
WT_CALC         = 50            ; app window types start at 50
ID_MENU_FILE    = 10            ; menu IDs start at 10
ID_MENU_HELP    = 11

; Action codes (digits are 0..9)
KEY_ADD         = 20
KEY_SUB         = 21
KEY_MUL         = 22
KEY_DIV         = 23
KEY_EQUAL       = 24
KEY_CLEAR       = 25
KEY_SIGN        = 26
KEY_POINT       = 27

; GUI64 runtime internals (see GUI64 Constants_win.asm)
ControlPressed  = $84           ; nonzero while the runtime tracks a press
IsLBtnPressed   = $7d           ; physical left mouse button (IRQ driver)
bFirePressed    = $7e           ; joystick fire, alt. left button

*=$b000
AppStart
!zone Start
                cld                     ; ensure binary mode
                lda #WT_CALC
                sta Param0
                jsr GUI_FindWndByType   ; app already running?
                bcs +                   ; yes: bring window to front
                ldx #<Wnd_Calc
                ldy #>Wnd_Calc
                jsr GUI_CreateWindowEx
                jsr GUI_GetDesign
                beq ++                  ; WIN design
                dec WindowHeight        ; MAC: menubar not in window
                jsr GUI_UpdateWindow
++              jsr GUI_SelectControl0  ; menubar: set menu titles
                ldx #<Str_Menubar
                ldy #>Str_Menubar
                lda #2
                jsr GUI_SetCtrlStringList
                jsr GUI_SelectControl1  ; display label: set string
                ldx #<Str_Display
                ldy #>Str_Display
                jsr GUI_SetCtrlString
                jmp ShowNumber          ; display "0"
+               stx Param0              ; window handle from FindWndByType
                jmp GUI_SelectTopWindow

!source "calc_math.asm"

!zone WndProc
CalcWndProc     jsr GUI_StdWndProc      ; must always be called first
                lda wndParam1
                bpl +                   ; dialog mode ($ff): ignore
                rts
+
                beq cw_normal
                jmp cw_menu             ; menu mode
cw_normal       ; ----- normal mode -----
                lda wndParam0
                cmp #EC_KEYPRESS
                beq cw_key
                cmp #EC_LBTNRELEASE
                beq cw_release
                cmp #EC_LBTNPRESS
                beq cw_press
                jsr CheckStale          ; mousemove, dblclick, wheel, ...
                jmp cw_rts
cw_press        jsr GUI_IsInCurControl
                bcc cw_hit              ; not a scanned control: hit-test
                ldx ControlType
                cpx #CT_BUTTON
                bne cw_rts
                ldy ControlIndex
                lda KeyForIdx,y
                pha
                lda ControlIndex
                sta cp_keep
                jsr ClearOthers         ; release any other stuck button
                pla
                jmp Dispatch
cw_hit          jsr HitTestButtons      ; GUI64 v2.1 misses ctrls 16..18
                bcc cw_rts
                pha
                txa
                jsr SetPressedA         ; mark it pressed so it animates
                lda #1                  ; let the runtime deliver the
                sta ControlPressed      ; release event to us as usual
                txa
                sta cp_keep
                jsr ClearOthers
                pla
                jmp Dispatch
cw_release      jsr ClearAllPressed     ; runtime leaves buttons pressed
                jmp GUI_RepaintCurWindow
cw_key          jsr CheckStale
                jmp KeyPet
                ; ----- menu mode -----
cw_menu         lda wndParam0
                cmp #EC_LBTNPRESS
                bne cw_rts
                jsr GUI_IsInCurMenu
                bcc cw_rts
                jsr GUI_GetCurMenuID
                cmp #ID_MENU_FILE
                beq cw_filemenu
                lda CurMenuItem         ; Help menu
                bne cw_rts
                ldx #<Str_About
                ldy #>Str_About
                jsr GUI_ShowMessage
                rts
cw_filemenu     lda CurMenuItem
                bne cw_rts
                jsr GUI_KillCurWindow
                jmp GUI_Repaint
cw_rts          rts

;---------------------------------------------------------------
; GUI64 v2.1 draws every pressed button with the same shared
; charset chars (240..255). If a second button is still marked
; pressed, both show the last generated label (e.g. a pressed 7
; displays "1"). Drop the pressed flag on every control except
; the one just clicked.
; Expects the clicked control to be the current one; A is kept.
;---------------------------------------------------------------
;---------------------------------------------------------------
; ClearOthers: drop the pressed flag on every control except
; cp_keep (preserves A)
;---------------------------------------------------------------
ClearOthers     pha
                ldx #0
co_lp           cpx cp_keep
                beq co_next
                txa
                jsr CancelPressedA
co_next         inx
                cpx WindowNumCtrls
                bcc co_lp
                pla
                rts
cp_keep         !byte 0
cp_action       !byte 0

;---------------------------------------------------------------
; ClearAllPressed: drop the pressed flag on every control
; (called on mouse release so buttons pop back up)
;---------------------------------------------------------------
ClearAllPressed ldx #0
cap_lp          txa
                jsr CancelPressedA
                inx
                cpx WindowNumCtrls
                bcc cap_lp
                rts

;---------------------------------------------------------------
; CheckStale: unstick a lost mouse release. GUI64 delivers events
; through a single exit_code byte that the IRQ overwrites, so the
; release can be lost while this app repaints after a press. The
; button then stays marked pressed (drawn from the shared charset
; chars 240-255), and the next pressed button makes it display
; the wrong label until a repaint. With no mouse/fire button
; physically held, nothing can legitimately be pressed: drop the
; stale flag(s) and the runtime's press tracking.
;---------------------------------------------------------------
CheckStale      lda IsLBtnPressed
                ora bFirePressed
                bne cs_rts              ; button held: the press is real
                lda ControlPressed
                beq cs_rts              ; runtime tracks no press
                ldx #0
cs_scan         txa
                jsr HeapPtrA
                ldy #7
                lda ($fb),y
                and #BIT_CTRL_ISPRESSED
                bne cs_purge
                inx
                cpx WindowNumCtrls
                bcc cs_scan
                lda #0                  ; flags already clean
                sta ControlPressed
cs_rts          rts
cs_purge        lda #0                  ; release never coming: unstick
                sta ControlPressed
                jsr ClearAllPressed
                jmp GUI_RepaintCurWindow

;---------------------------------------------------------------
; Direct control-heap access. GUI64 v2.1's GUI_SelectControl
; drops a carry for indices >= 16 (asl x4 then clc), selecting
; the wrong control, so address the heap ourselves:
;   entry = WindowCtrlPtr + index*16, flag byte at +7
;---------------------------------------------------------------
HeapPtrA        sta $fd                 ; save index (tmp)
                lda WindowCtrlPtr
                sta $fb
                lda WindowCtrlPtr+1
                sta $fc
                lda $fd
                asl
                asl
                asl
                asl                     ; A = index*16, C = bit 8
                bcc hp_nc1
                inc $fc
hp_nc1          clc
                adc $fb
                sta $fb
                bcc hp_nc2
                inc $fc
hp_nc2          rts

SetPressedA     jsr HeapPtrA
                ldy #7
                lda ($fb),y
                ora #BIT_CTRL_ISPRESSED
                sta ($fb),y
                rts

CancelPressedA  jsr HeapPtrA
                ldy #7
                lda ($fb),y
                and #($ff - BIT_CTRL_ISPRESSED)
                sta ($fb),y
                rts

;---------------------------------------------------------------
; GUI64 v2.1's mouse scan stops after 16 controls, so the window's
; last three buttons ("3" = ctrl 16, "=" = ctrl 17, "0" = ctrl 18)
; never match. Hit-test them against MousePosInWndX/Y (the same
; client-area coordinates the runtime compares).
; OUT: C=1, A=action code, X=control index (16..18) on hit.
;      C=0 otherwise.
;---------------------------------------------------------------
HitTestButtons  ldx #3
ht_loop         lda MousePosInWndX
                cmp HitTestX,x
                bcc ht_next
                sbc HitTestX,x
                cmp HitTestW,x
                bcs ht_next
                lda MousePosInWndY
                cmp HitTestY,x
                bcc ht_next
                sbc HitTestY,x
                cmp HitTestH,x
                bcs ht_next
                lda HitTestAct,x
                pha
                txa
                clc
                adc #16                 ; ctrl index = 16 + table slot
                tax
                pla
                sec
                rts
ht_next         dex
                bpl ht_loop
                clc
                rts
HitTestX        !byte 11, 16, 1, 6      ; "3" "=" "0" "." x (client)
HitTestY        !byte 11, 11, 14, 14
HitTestW        !byte 5, 5, 5, 5
HitTestH        !byte 3, 3, 3, 3
HitTestAct      !byte 3, KEY_EQUAL, 0, KEY_POINT

!zone Actions
ActDigit        sta DIGITVAL
                lda ErrorFlag
                bne ad_err
                lda Entering
                bne ad_acc
                jsr EntReset            ; start a new entry
                lda #1
                sta Entering
ad_acc          lda DIGITVAL
                jsr AccumDigit
                jmp ShowNumber
ad_err          lda #1
                sta ErrorFlag
                jmp ShowError

ActPoint        lda ErrorFlag
                bne ap_done
                lda Entering
                bne ax_pacc
                jsr EntReset
                lda #1
                sta Entering
ax_pacc          jsr AccumPoint
                jmp ShowNumber
ap_done          rts

ActOp           sta OPSET
                lda ErrorFlag
                bne ao_rts
                lda Entering
                beq ao_have
                jsr CommitEntry         ; NUM2 = entry
                lda #0
                sta Entering
ao_have         lda Op
                beq ao_commit
                lda Op                  ; chained calculation:
                jsr Compute             ; NUM2 = NUM1 op NUM2
                bcs ao_err
ao_commit       jsr CopyN2N1            ; NUM1 = NUM2
                lda OPSET
                sta Op
                jmp ShowNumber
ao_err          lda #1
                sta ErrorFlag
                jmp ShowError
ao_rts          rts

ActEqual        lda ErrorFlag
                bne ae_rts
                lda Entering
                beq ae_have
                jsr CommitEntry
                lda #0
                sta Entering
ae_have         lda Op
                beq ae_show
                jsr Compute
                bcs ae_err
                lda #0
                sta Op
ae_show         lda #0
                sta Entering
                jmp ShowNumber
ae_err          lda #1
                sta ErrorFlag
                jmp ShowError
ae_rts          rts

ActClear        jsr ClearCalc
                lda #0
                sta ErrorFlag
                sta Op
                sta Entering
                jmp ShowNumber

ActSign         lda ErrorFlag
                bne as_rts
                lda Entering
                beq as_num
                lda ENT_SIGN
                eor #$01
                sta ENT_SIGN
                jmp ShowNumber
as_num          lda Sign2
                eor #$01
                sta Sign2
                jmp ShowNumber
as_rts          rts

;---------------------------------------------------------------
; Display helpers
;---------------------------------------------------------------
ShowNumber      lda Entering
                beq sn_num
                jsr EntToStr
                jmp GUI_RepaintCurWindow
sn_num          jsr SetPtrNum2
                jsr NumToStr
                jmp GUI_RepaintCurWindow

ShowError       ldx #15
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
                jmp GUI_RepaintCurWindow

!zone Dispatch
; A = action code (0..9 digit, 20..26 special)
Dispatch        tay
                lda DispLo,y
                sta dp_jmp+1
                lda DispHi,y
                sta dp_jmp+2
                tya                     ; restore action code for handlers
dp_jmp          jmp $ffff
dp_rts          rts

DispLo          !byte <ActDigit,<ActDigit,<ActDigit,<ActDigit,<ActDigit
                !byte <ActDigit,<ActDigit,<ActDigit,<ActDigit,<ActDigit
                !byte <dp_rts,<dp_rts,<dp_rts,<dp_rts,<dp_rts
                !byte <dp_rts,<dp_rts,<dp_rts,<dp_rts,<dp_rts
                !byte <SpAdd,<SpSub,<SpMul,<SpDiv,<SpEqual,<SpClear,<SpSign,<SpPoint
DispHi          !byte >ActDigit,>ActDigit,>ActDigit,>ActDigit,>ActDigit
                !byte >ActDigit,>ActDigit,>ActDigit,>ActDigit,>ActDigit
                !byte >dp_rts,>dp_rts,>dp_rts,>dp_rts,>dp_rts
                !byte >dp_rts,>dp_rts,>dp_rts,>dp_rts,>dp_rts
                !byte >SpAdd,>SpSub,>SpMul,>SpDiv,>SpEqual,>SpClear,>SpSign,>SpPoint

SpAdd           lda #1
                jmp ActOp
SpSub           lda #2
                jmp ActOp
SpMul           lda #3
                jmp ActOp
SpDiv           lda #4
                jmp ActOp
SpEqual         jmp ActEqual
SpClear         jmp ActClear
SpSign          jmp ActSign
SpPoint         jmp ActPoint

;---------------------------------------------------------------
; Keyboard: PETSCII -> action
;---------------------------------------------------------------
KeyPet          lda ProgramMode
                bne kp_rts              ; keys only in normal mode
                lda actkey
                cmp #$30                ; "0".."9"
                bcc kp_ops
                cmp #$3a
                bcs kp_ops
                sec
                sbc #$30
                jmp Dispatch
kp_ops          cmp #$2b                ; "+"
                bne kp_n1
                lda #KEY_ADD
                jmp Dispatch
kp_n1           cmp #$2d                ; "-"
                bne kp_n2
                lda #KEY_SUB
                jmp Dispatch
kp_n2           cmp #$2a                ; "*"
                bne kp_n3
                lda #KEY_MUL
                jmp Dispatch
kp_n3           cmp #$2f                ; "/"
                bne kp_n4
                lda #KEY_DIV
                jmp Dispatch
kp_n4           cmp #$3d                ; "="
                beq kp_eq
                cmp #$fc                ; RETURN (GUI64 actkey code)
                bne kppt
kp_eq           lda #KEY_EQUAL
                jmp Dispatch
kppt            cmp #$2e                ; "."
                bne kp_n5
                lda #KEY_POINT
                jmp Dispatch
kp_n5           cmp #$43                ; "C"
                beq kp_cl
                cmp #$63                ; "c"
                bne kp_rts
kp_cl           lda #KEY_CLEAR
                jmp Dispatch
kp_rts          rts

; Control index -> action code
KeyForIdx       !byte 255,255           ; 0 menubar, 1 display
                !byte KEY_CLEAR         ; 2  "C"
                !byte KEY_SIGN          ; 3  "+/-"
                !byte KEY_DIV           ; 4  "/"
                !byte KEY_MUL           ; 5  "*"
                !byte 7,8,9             ; 6..8  "7" "8" "9"
                !byte KEY_SUB           ; 9  "-"
                !byte 4,5,6             ; 10..12 "4" "5" "6"
                !byte KEY_ADD           ; 13 "+"
                !byte 1,2,3             ; 14..16 "1" "2" "3"
                !byte KEY_EQUAL         ; 17 "="
                !byte 0                 ; 18 "0"
                !byte KEY_POINT         ; 19 "."

!zone Data
Str_Title       !pet "Calculator",0

; Window: type, bits, x, y, width, height, title, wndproc
Wnd_Calc        !byte WT_CALC, %00100001, 8, 1, 23, 20
                !word Str_Title, CalcWndProc
; Controls (terminated by zero byte):
                ;0: menubar (x/y = pointer to menu list)
                !byte CT_MENUBAR, <MenuList, >MenuList, 0, 0
                !pet 0
                ;1: display
                !byte CT_LABEL, 6, 0, 16, 1
                !pet 0
                ;2: C
                !byte CT_BUTTON, 1, 2, 5, 3
                !pet " C ",0
                ;3: +/-
                !byte CT_BUTTON, 6, 2, 5, 3
                !pet "+/-",0
                ;4: /
                !byte CT_BUTTON, 11, 2, 5, 3
                !pet " / ",0
                ;5: *
                !byte CT_BUTTON, 16, 2, 5, 3
                !pet " * ",0
                ;6: 7
                !byte CT_BUTTON, 1, 5, 5, 3
                !pet " 7 ",0
                ;7: 8
                !byte CT_BUTTON, 6, 5, 5, 3
                !pet " 8 ",0
                ;8: 9
                !byte CT_BUTTON, 11, 5, 5, 3
                !pet " 9 ",0
                ;9: -
                !byte CT_BUTTON, 16, 5, 5, 3
                !pet " - ",0
                ;10: 4
                !byte CT_BUTTON, 1, 8, 5, 3
                !pet " 4 ",0
                ;11: 5
                !byte CT_BUTTON, 6, 8, 5, 3
                !pet " 5 ",0
                ;12: 6
                !byte CT_BUTTON, 11, 8, 5, 3
                !pet " 6 ",0
                ;13: +
                !byte CT_BUTTON, 16, 8, 5, 3
                !pet " + ",0
                ;14: 1
                !byte CT_BUTTON, 1, 11, 5, 3
                !pet " 1 ",0
                ;15: 2
                !byte CT_BUTTON, 6, 11, 5, 3
                !pet " 2 ",0
                ;16: 3
                !byte CT_BUTTON, 11, 11, 5, 3
                !pet " 3 ",0
                ;17: =
                !byte CT_BUTTON, 16, 11, 5, 3
                !pet " = ",0
                ;18: 0
                !byte CT_BUTTON, 1, 14, 5, 3
                !pet " 0 ",0
                ;19: .
                !byte CT_BUTTON, 6, 14, 5, 3
                !pet " . ",0
                ; terminating zero byte
                !byte 0

; Menus
MenuList        !word Menu_File, Menu_Help
Str_Menubar     !pet "File",0,"Help",0
; Format: ID, max string len, item count, string list
Menu_File       !pet ID_MENU_FILE,4,1,"Quit",0
Menu_Help       !pet ID_MENU_HELP,5,1,"About",0

Str_About       !pet 221,222,223," Calculator64 v1.1"
                !byte 28                ; PETSCII line separator
                !pet 224,225,226," by Guillermo Power",0