/* SPDX-License-Identifier: GPL-3.0-or-later */

.syntax unified
.cpu arm7tdmi
.arm

.section .text.start, "ax", %progbits
.align 2
.global start
.type start, %function
start:
    ldr     sp, =stack_top
    mov     r0, #20
    mov     r1, #22
    bl      add_preserving_r4

.Lhalt:
    b       .Lhalt
.size start, . - start

.align 2
.type add_preserving_r4, %function
add_preserving_r4:
    stmdb   sp!, {r4, lr}
    mov     r4, r1
    add     r0, r0, r4
    ldmia   sp!, {r4, pc}
.size add_preserving_r4, . - add_preserving_r4

.section .bss.stack, "aw", %nobits
.align 3
stack_area:
    .space  256
stack_top:

.section .note.GNU-stack, "", %progbits
