/* SPDX-License-Identifier: GPL-3.0-or-later */

.syntax unified
.cpu arm7tdmi
.arm

.section .text.start, "ax", %progbits
.align 2
.global start
.type start, %function
start:
    mov     r0, #7
    cmp     r0, #5
    mrs     r2, cpsr
    bgt     .Lgreater

    mov     r1, #0
    b       .Lhalt

.Lgreater:
    mov     r1, #1

.Lhalt:
    b       .Lhalt
.size start, . - start

.section .note.GNU-stack, "", %progbits
