/* SPDX-License-Identifier: GPL-3.0-or-later */

.syntax unified
.cpu arm7tdmi
.arm

.section .data.numbers, "aw", %progbits
.align 2
.global numbers
.type numbers, %object
numbers:
    .word   10, 20, 30, 40, 50
.size numbers, . - numbers

.section .note.GNU-stack, "", %progbits
