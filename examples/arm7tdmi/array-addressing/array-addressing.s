/* SPDX-License-Identifier: GPL-3.0-or-later */

.syntax unified
.cpu arm7tdmi
.arm

.section .text.start, "ax", %progbits
.align 2
.global start
.type start, %function
start:
    ldr     r0, =numbers
    mov     r1, #3
    ldr     r2, [r0, r1, lsl #2]

.Lhalt:
    b       .Lhalt
.size start, . - start

.section .data.numbers, "aw", %progbits
.align 2
numbers:
    .word   10, 20, 30, 40, 50

.section .note.GNU-stack, "", %progbits
