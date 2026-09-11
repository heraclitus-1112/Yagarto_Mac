/* SPDX-License-Identifier: GPL-3.0-or-later */
.syntax unified
.cpu cortex-m4
.thumb

.section .isr_vector, "a", %progbits
.align 2
.global __isr_vector
__isr_vector:
    .word 0x20400000
    .word Reset_Handler
    .rept 14
    .word 0
    .endr

.section .text.Reset_Handler, "ax", %progbits
.align 2
.thumb_func
.global Reset_Handler
.type Reset_Handler, %function
Reset_Handler:
    ldr r0, =__data_load__
    ldr r1, =__data_start__
    ldr r2, =__data_end__
.Lcopy_data:
    cmp r1, r2
    bcs .Lprepare_bss
    ldrb r3, [r0], #1
    strb r3, [r1], #1
    b .Lcopy_data

.Lprepare_bss:
    ldr r1, =__bss_start__
    ldr r2, =__bss_end__
    movs r3, #0
.Lzero_bss:
    cmp r1, r2
    bcs .Lcall_entry
    strb r3, [r1], #1
    b .Lzero_bss

.Lcall_entry:
    bl __yagarto_entry
    b .
.size Reset_Handler, . - Reset_Handler
