/* SPDX-License-Identifier: GPL-3.0-or-later */

.syntax unified
.cpu cortex-m4
.thumb

.equ RCC_AHB1ENR, 0x40023830
.equ GPIOD_MODER, 0x40020C00
.equ GPIOD_BSRR,  0x40020C18

.section .text.main, "ax", %progbits
.align 2
.global main
.thumb_func
.type main, %function
main:
    ldr     r0, =RCC_AHB1ENR
    ldr     r1, [r0]
    orr     r1, r1, #(1 << 3)
    str     r1, [r0]
    ldr     r1, [r0]

    ldr     r0, =GPIOD_MODER
    ldr     r1, [r0]
    ldr     r2, =0x03000000
    bic     r1, r1, r2
    ldr     r2, =0x01000000
    orr     r1, r1, r2
    str     r1, [r0]

    ldr     r0, =GPIOD_BSRR
    movw    r1, #(1 << 12)
    str     r1, [r0]

.Lled_on:
    b       .Lled_on
.size main, . - main

.section .note.GNU-stack, "", %progbits
