/* SPDX-License-Identifier: GPL-3.0-or-later */
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
}

SECTIONS
{
    .text :
    {
        KEEP(*(.isr_vector))
        KEEP(*(.vectors))
        *(.text*)
        *(.rodata*)
    } > FLASH

    .data :
    {
        __data_start__ = .;
        *(.data*)
        __data_end__ = .;
    } > RAM AT > FLASH
    __data_load__ = LOADADDR(.data);

    .bss (NOLOAD) :
    {
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        __bss_end__ = .;
    } > RAM
}
