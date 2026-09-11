#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
CLI=${YAGARTO_MAC:-$REPOSITORY_ROOT/.build/debug/yagarto-mac}

if [ ! -x "$CLI" ]; then
    printf '错误：找不到 CLI：%s；请先运行 swift build。\n' "$CLI" >&2
    exit 1
fi

READELF=${READELF:-arm-none-eabi-readelf}
OBJDUMP=${OBJDUMP:-arm-none-eabi-objdump}
NM=${NM:-arm-none-eabi-nm}
for tool in "$READELF" "$OBJDUMP" "$NM"; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '错误：找不到验证工具：%s\n' "$tool" >&2
        exit 1
    }
done

extract_entry_address() {
    awk '
        /^[[:space:]]*Entry point address:[[:space:]]*/ {
            sub(/^[[:space:]]*Entry point address:[[:space:]]*/, "")
            sub(/[[:space:]]*$/, "")
            print
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    '
}

check_example() {
    relative=$1
    profile=$2
    output=$3
    entry_symbol=$4
    cpu_arch=$5
    entry_address=$6
    directory=$REPOSITORY_ROOT/examples/$relative
    elf=$directory/.yagarto/build/$profile/$output.elf
    map=$directory/.yagarto/build/$profile/$output.map
    listing=$directory/.yagarto/build/$profile/$output.lst

    [ -f "$directory/yagarto.json" ] || {
        printf '错误：示例缺少配置：%s\n' "$relative" >&2
        return 1
    }
    [ -f "$directory/README.md" ] || {
        printf '错误：示例缺少 README：%s\n' "$relative" >&2
        return 1
    }
    (
        cd "$directory"
        "$CLI" build --format text
    )
    [ -s "$elf" ] || { printf '错误：缺少 ELF：%s\n' "$elf" >&2; return 1; }
    [ -s "$map" ] || { printf '错误：缺少 map：%s\n' "$map" >&2; return 1; }
    [ -s "$listing" ] || { printf '错误：缺少 listing：%s\n' "$listing" >&2; return 1; }
    "$READELF" -h "$elf" | grep -q 'Machine:.*ARM' \
        || { printf '错误：ELF 不是 ARM：%s\n' "$elf" >&2; return 1; }
    "$READELF" -A "$elf" | grep -q "Tag_CPU_arch: $cpu_arch" \
        || { printf '错误：ELF CPU 架构不是 %s：%s\n' "$cpu_arch" "$elf" >&2; return 1; }
    actual_entry=$("$READELF" -h "$elf" | extract_entry_address) \
        || { printf '错误：无法提取 ELF 入口：%s\n' "$elf" >&2; return 1; }
    [ "$actual_entry" = "$entry_address" ] \
        || { printf '错误：ELF 入口不是 %s（实际 %s）：%s\n' \
                    "$entry_address" "$actual_entry" "$elf" >&2; return 1; }
    "$READELF" -S "$elf" | grep -q '\.text' \
        || { printf '错误：ELF 缺少 .text：%s\n' "$elf" >&2; return 1; }
    "$READELF" -S "$elf" | grep -q '\.debug_info' \
        || { printf '错误：ELF 缺少 DWARF：%s\n' "$elf" >&2; return 1; }
    "$NM" "$elf" | grep -q "[[:space:]]$entry_symbol\$" \
        || { printf '错误：ELF 缺少入口符号 %s：%s\n' "$entry_symbol" "$elf" >&2; return 1; }
    grep -q "<$entry_symbol>" "$listing" \
        || { printf '错误：listing 缺少入口符号 %s：%s\n' "$entry_symbol" "$listing" >&2; return 1; }
}

check_example arm7tdmi/arithmetic-cpsr arm7tdmi arithmetic-cpsr start v4T 0x8000
check_example arm7tdmi/conditional-branch arm7tdmi conditional-branch start v4T 0x8000
check_example arm7tdmi/array-addressing arm7tdmi array-addressing start v4T 0x8000
check_example arm7tdmi/stack-subroutine arm7tdmi stack-subroutine start v4T 0x8000
check_example cortex-m4/minimal-entry cortex-m4 minimal-entry Reset_Handler v7E-M 0x41
check_example stm32f4-discovery/pd12-led stm32f4-discovery pd12-led Reset_Handler v7E-M 0x8000041

ARITHMETIC_ELF=$REPOSITORY_ROOT/examples/arm7tdmi/arithmetic-cpsr/.yagarto/build/arm7tdmi/arithmetic-cpsr.elf
ARITHMETIC_DISASSEMBLY=$($OBJDUMP -d "$ARITHMETIC_ELF")
printf '%s\n' "$ARITHMETIC_DISASSEMBLY" | grep -Eq 'mov[[:space:]]+r0, #256' \
    || { printf '%s\n' '错误：算术示例缺少 r0 = 256 指令。' >&2; exit 1; }
printf '%s\n' "$ARITHMETIC_DISASSEMBLY" | grep -Eq 'adds[[:space:]]+r0, r0, #67' \
    || { printf '%s\n' '错误：算术示例缺少 r0 += 67 指令。' >&2; exit 1; }

printf '%s\n' 'example build and ELF audit: PASS (r0 = 256 + 67 = 323 instruction sequence verified)'
