/* SPDX-License-Identifier: GPL-3.0-or-later */

.syntax unified
.cpu arm7tdmi
.arm

.section .text.start, "ax", %progbits
.align 2
.global start
.type start, %function
.extern numbers
start:
    ldr     r0, =numbers
    mov     r1, #3
    ldr     r2, [r0, r1, lsl #2]

.Lhalt:
    b       .Lhalt
.size start, . - start

.section .note.GNU-stack, "", %progbits
