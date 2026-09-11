/* SPDX-License-Identifier: GPL-3.0-or-later */
ENTRY(Reset_Handler)

MEMORY
{
    CODE (rx)  : ORIGIN = 0x00000000, LENGTH = 4M
    RAM (rwx)   : ORIGIN = 0x20000000, LENGTH = 0x003FF000
    STACK (rw)  : ORIGIN = 0x203FF000, LENGTH = 4K
}

_estack = ORIGIN(STACK) + LENGTH(STACK);
__stack_limit__ = ORIGIN(STACK);

SECTIONS
{
    .text :
    {
        KEEP(*(.isr_vector))
        KEEP(*(.vectors))
        *(.text*)
        *(.rodata*)
    } > CODE

    .bss (NOLOAD) :
    {
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        __bss_end__ = .;
    } > RAM

    .noinit (NOLOAD) :
    {
        *(.noinit*)
    } > RAM

    .data :
    {
        __data_start__ = .;
        *(.data*)
        INPUT_SECTION_FLAGS (SHF_ALLOC & SHF_WRITE) *(*)
        __data_end__ = .;
    } > RAM AT > CODE
    __data_load__ = LOADADDR(.data);
}
