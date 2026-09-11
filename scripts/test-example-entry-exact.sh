#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
TARGET=$SCRIPT_DIR/test-examples.sh
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/yagarto-entry-exact.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM
FAKE_READELF=$TEMP_ROOT/readelf

cat >"$FAKE_READELF" <<'EOF'
#!/bin/sh
set -eu

mode=$1
elf=$2
case "$mode" in
    -h)
        case "$elf" in
            *arithmetic-cpsr.elf) entry=0x80000 ;;
            *arm7tdmi*) entry=0x8000 ;;
            *cortex-m4*) entry=0x41 ;;
            *stm32f4-discovery*) entry=0x8000041 ;;
            *) exit 2 ;;
        esac
        printf '  Machine: ARM\n  Entry point address: %s\n' "$entry"
        ;;
    -A)
        case "$elf" in
            *arm7tdmi*) printf '%s\n' '  Tag_CPU_arch: v4T' ;;
            *) printf '%s\n' '  Tag_CPU_arch: v7E-M' ;;
        esac
        ;;
    -S)
        printf '%s\n' '  [ 1] .text' '  [ 2] .debug_info'
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$FAKE_READELF"

if READELF="$FAKE_READELF" "$TARGET" \
    >"$TEMP_ROOT/stdout" 2>"$TEMP_ROOT/stderr"; then
    printf '%s\n' 'FAIL: 期望 0x8000 时错误接受了 0x80000。' >&2
    exit 1
fi

grep -q '入口不是 0x8000' "$TEMP_ROOT/stderr" || {
    printf '%s\n' 'FAIL: 未从精确 entry 比较得到预期诊断。' >&2
    exit 1
}

printf '%s\n' 'exact ELF entry regression: PASS'
