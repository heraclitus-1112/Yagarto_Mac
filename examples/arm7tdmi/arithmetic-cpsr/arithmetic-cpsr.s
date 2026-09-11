/* SPDX-License-Identifier: GPL-3.0-or-later */

.syntax unified
.cpu arm7tdmi
.arm

.section .text.start, "ax", %progbits
.align 2
.global start
.type start, %function
start:
    mov     r0, #256
    adds    r0, r0, #67
    mrs     r1, cpsr

.Lhalt:
    b       .Lhalt
.size start, . - start

.section .note.GNU-stack, "", %progbits
