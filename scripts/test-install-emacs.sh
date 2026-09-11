#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
INSTALLER=$SCRIPT_DIR/install-emacs.sh
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/yagarto-install-tests.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

HELP_OUTPUT=$($INSTALLER --help)
printf '%s' "$HELP_OUTPUT" | grep -q -- '--print' || fail 'help 缺少 --print'
printf '%s' "$HELP_OUTPUT" | grep -q -- '--install' || fail 'help 缺少 --install'
printf '%s' "$HELP_OUTPUT" | grep -q -- '--init-file' || fail 'help 缺少 --init-file'

PRINT_OUTPUT=$($INSTALLER --print)
printf '%s' "$PRINT_OUTPUT" | grep -q "require 'yagarto-mac-mode" \
    || fail '--print 未打印 require 片段'
printf '%s' "$PRINT_OUTPUT" | grep -q '用法：' \
    && fail '--print 混入了帮助文本'

NO_CONFIRM=$TEMP_ROOT/no-confirm.el
if $INSTALLER --install --init-file "$NO_CONFIRM" </dev/null \
    >"$TEMP_ROOT/no-confirm.out" 2>"$TEMP_ROOT/no-confirm.err"; then
    fail '非 TTY 且无 --yes 时不应成功'
fi
[ ! -e "$NO_CONFIRM" ] || fail '非 TTY 无确认时修改了 init 文件'

DECLINE=$TEMP_ROOT/decline.el
if [ -x /usr/bin/script ]; then
    printf 'no\n' | /usr/bin/script -q /dev/null \
        "$INSTALLER" --install --init-file "$DECLINE" \
        >"$TEMP_ROOT/decline.out" 2>"$TEMP_ROOT/decline.err" || true
    [ ! -e "$DECLINE" ] || fail 'TTY 中拒绝后仍修改了 init 文件'
else
    printf '%s\n' 'SKIP: 系统无 script，无法自动覆盖 TTY decline。'
fi

SAFE_DIR=$TEMP_ROOT/'中文 配置'
mkdir -p "$SAFE_DIR"
INIT_FILE=$SAFE_DIR/'我的 init.el'
printf '%s\n' ';; 原有配置' >"$INIT_FILE"
$INSTALLER --install --yes --init-file "$INIT_FILE" >/dev/null
FIRST_SUM=$(cksum <"$INIT_FILE")
$INSTALLER --install --yes --init-file "$INIT_FILE" >/dev/null
SECOND_SUM=$(cksum <"$INIT_FILE")
[ "$FIRST_SUM" = "$SECOND_SUM" ] || fail '重复安装改变了 init 文件'
[ "$(grep -c 'YAGARTO Mac integration BEGIN' "$INIT_FILE")" -eq 1 ] \
    || fail '安装片段不是单例'
grep -q ';; 原有配置' "$INIT_FILE" || fail '安装覆盖了原有配置'
[ -f "$INIT_FILE.yagarto-mac.bak" ] || fail '首次安装未创建备份'

SYMLINK_TARGET=$TEMP_ROOT/target.el
SYMLINK_INIT=$TEMP_ROOT/link.el
printf '%s\n' ';; target' >"$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_INIT"
if $INSTALLER --install --yes --init-file "$SYMLINK_INIT" >/dev/null 2>&1; then
    fail '符号链接 init 文件应被拒绝'
fi
[ "$(cat "$SYMLINK_TARGET")" = ';; target' ] || fail '符号链接目标被修改'

NON_FILE=$TEMP_ROOT/not-a-file
mkdir "$NON_FILE"
if $INSTALLER --install --yes --init-file "$NON_FILE" >/dev/null 2>&1; then
    fail '非普通文件目标应被拒绝'
fi

HARDLINK_INIT=$TEMP_ROOT/hardlink.el
HARDLINK_ALIAS=$TEMP_ROOT/hardlink-alias.el
printf '%s\n' ';; hardlink original' >"$HARDLINK_INIT"
ln "$HARDLINK_INIT" "$HARDLINK_ALIAS"
if $INSTALLER --install --yes --init-file "$HARDLINK_INIT" >/dev/null 2>&1; then
    fail '具有多个硬链接的 init 文件应被拒绝'
fi
[ "$(cat "$HARDLINK_ALIAS")" = ';; hardlink original' ] \
    || fail '拒绝硬链接目标时修改了共享 inode'

WRITABLE_INIT=$TEMP_ROOT/world-writable.el
printf '%s\n' ';; unsafe permissions' >"$WRITABLE_INIT"
chmod 0666 "$WRITABLE_INIT"
if $INSTALLER --install --yes --init-file "$WRITABLE_INIT" >/dev/null 2>&1; then
    fail '组或其他用户可写的 init 文件应被拒绝'
fi
[ "$(cat "$WRITABLE_INIT")" = ';; unsafe permissions' ] \
    || fail '拒绝不安全权限时修改了 init 文件'

if $INSTALLER --install --yes --init-file / >/dev/null 2>&1; then
    fail '危险根路径应被拒绝'
fi

DEFAULT_HOME=$TEMP_ROOT/default-home
mkdir -p "$DEFAULT_HOME"
DEFAULT_TARGET=$TEMP_ROOT/default-target.el
printf '%s\n' ';; default target' >"$DEFAULT_TARGET"
ln -s "$DEFAULT_TARGET" "$DEFAULT_HOME/.emacs"
if HOME="$DEFAULT_HOME" XDG_CONFIG_HOME= \
    $INSTALLER --install --yes >/dev/null 2>&1; then
    fail '默认 ~/.emacs 为符号链接时应拒绝，而不是改写另一个 init'
fi
[ ! -e "$DEFAULT_HOME/.emacs.d/init.el" ] \
    || fail '拒绝默认符号链接时仍创建了备用 init'

printf '%s\n' 'install-emacs shell tests: PASS'
