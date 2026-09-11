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
        *(.text .text.* .gnu.linkonce.t.*)
        *(.rodata .rodata.* .gnu.linkonce.r.*)
        *(.glue_7 .glue_7t .vfp11_veneer .v4_bx)
        *(.init .fini)
    } > CODE

    .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } > CODE
    .ARM.exidx : { *(.ARM.exidx* .gnu.linkonce.armexidx.*) } > CODE
    .iplt : { *(.iplt) } > CODE
    .rel.iplt : { *(.rel.iplt) } > CODE

    .bss (NOLOAD) :
    {
        __bss_start__ = .;
        *(.bss .bss.* .gnu.linkonce.b.*)
        *(.sbss .sbss.* .gnu.linkonce.sb.*)
        *(COMMON)
        __bss_end__ = .;
    } > RAM

    .noinit (NOLOAD) :
    {
        *(.noinit .noinit.*)
    } > RAM

    .data :
    {
        __data_start__ = .;
        *(.data .data.* .gnu.linkonce.d.*)
        *(.sdata .sdata.* .gnu.linkonce.s.*)
        *(.preinit_array .preinit_array.*)
        *(.init_array .init_array.*)
        *(.fini_array .fini_array.*)
        *(.ctors .ctors.* .dtors .dtors.*)
        *(.jcr .got .got.* .igot .igot.*)
        __data_end__ = .;
    } > RAM AT > CODE
    __data_load__ = LOADADDR(.data);

    .stab              0 : { *(.stab) }
    .stabstr           0 : { *(.stabstr) }
    .stab.excl         0 : { *(.stab.excl) }
    .stab.exclstr      0 : { *(.stab.exclstr) }
    .stab.index        0 : { *(.stab.index) }
    .stab.indexstr     0 : { *(.stab.indexstr) }
    .debug             0 : { *(.debug) }
    .line              0 : { *(.line) }
    .debug_srcinfo     0 : { *(.debug_srcinfo) }
    .debug_sfnames     0 : { *(.debug_sfnames) }
    .debug_aranges     0 : { *(.debug_aranges) }
    .debug_pubnames    0 : { *(.debug_pubnames) }
    .debug_info        0 : { *(.debug_info .gnu.linkonce.wi.*) }
    .debug_abbrev      0 : { *(.debug_abbrev) }
    .debug_line        0 : { *(.debug_line .debug_line.*) }
    .debug_frame       0 : { *(.debug_frame) }
    .debug_str         0 : { *(.debug_str) }
    .debug_loc         0 : { *(.debug_loc) }
    .debug_macinfo     0 : { *(.debug_macinfo) }
    .debug_weaknames   0 : { *(.debug_weaknames) }
    .debug_funcnames   0 : { *(.debug_funcnames) }
    .debug_typenames   0 : { *(.debug_typenames) }
    .debug_varnames    0 : { *(.debug_varnames) }
    .debug_pubtypes    0 : { *(.debug_pubtypes) }
    .debug_ranges      0 : { *(.debug_ranges) }
    .debug_addr        0 : { *(.debug_addr) }
    .debug_line_str    0 : { *(.debug_line_str) }
    .debug_loclists    0 : { *(.debug_loclists) }
    .debug_macro       0 : { *(.debug_macro) }
    .debug_names       0 : { *(.debug_names) }
    .debug_rnglists    0 : { *(.debug_rnglists) }
    .debug_str_offsets 0 : { *(.debug_str_offsets) }
    .debug_sup         0 : { *(.debug_sup) }
    .comment           0 : { *(.comment) }
    .gnu.build.attributes 0 : { *(.gnu.build.attributes .gnu.build.attributes.*) }
    .ARM.attributes    0 : { KEEP(*(.ARM.attributes)) }
    .gnu.attributes    0 : { KEEP(*(.gnu.attributes)) }
    .note.gnu.arm.ident 0 : { KEEP(*(.note.gnu.arm.ident)) }

    /DISCARD/ :
    {
        *(.note.GNU-stack)
        *(.gnu_debuglink)
        *(.gnu.lto_*)
        *(.gnu_object_only)
    }
}
