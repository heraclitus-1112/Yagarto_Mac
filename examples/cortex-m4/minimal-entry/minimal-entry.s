/* SPDX-License-Identifier: GPL-3.0-or-later */

.syntax unified
.cpu cortex-m4
.thumb

.section .text.main, "ax", %progbits
.align 2
.global main
.thumb_func
.type main, %function
main:
    mrs     r0, xpsr
    mrs     r1, msp
    mrs     r2, psp
    mrs     r3, control
    mrs     r4, primask
    movs    r5, #42

.Lhalt:
    b       .Lhalt
.size main, . - main

.section .note.GNU-stack, "", %progbits
