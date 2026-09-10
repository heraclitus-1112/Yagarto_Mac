/* SPDX-License-Identifier: GPL-3.0-or-later */
ENTRY(start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x8000, LENGTH = 64K
}

SECTIONS
{
    .text :
    {
        KEEP(*(.vectors))
        *(.text*)
        *(.rodata*)
    } > RAM

    .data :
    {
        *(.data*)
    } > RAM

    .bss (NOLOAD) :
    {
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        __bss_end__ = .;
    } > RAM
}
