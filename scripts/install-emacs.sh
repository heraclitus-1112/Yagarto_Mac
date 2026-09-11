#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
EMACS_DIRECTORY=$REPOSITORY_ROOT/emacs
BEGIN_MARKER=';; YAGARTO Mac integration BEGIN'
END_MARKER=';; YAGARTO Mac integration END'

usage() {
    printf '%s\n' \
        '用法：install-emacs.sh --print' \
        '      install-emacs.sh --install [--init-file 绝对路径] [--yes]' \
        '' \
        '  --print           只打印可手动加入 init 文件的 Emacs Lisp 片段。' \
        '  --install         安装片段；默认必须在 TTY 输入完整的 yes。' \
        '  --init-file PATH  指定 init 文件；PATH 必须是安全的绝对路径。' \
        '  --yes             显式跳过交互确认，适合调用者主动选择的自动化。' \
        '  -h, --help        显示此帮助。'
}

die() {
    printf '错误：%s\n' "$1" >&2
    exit 2
}

elisp_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

print_snippet() {
    escaped_directory=$(elisp_escape "$EMACS_DIRECTORY")
    printf '%s\n' \
        "$BEGIN_MARKER" \
        "(add-to-list 'load-path \"$escaped_directory\")" \
        "(require 'yagarto-mac-mode)" \
        "(add-hook 'asm-mode-hook #'yagarto-mac-mode)" \
        "$END_MARKER"
}

default_init_file() {
    [ -n "${HOME:-}" ] || die 'HOME 未设置；请用 --init-file 指定文件。'
    if [ -e "$HOME/.emacs" ] || [ -L "$HOME/.emacs" ]; then
        printf '%s\n' "$HOME/.emacs"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf '%s\n' "$XDG_CONFIG_HOME/emacs/init.el"
    else
        printf '%s\n' "$HOME/.emacs.d/init.el"
    fi
}

validate_init_file() {
    target=$1
    newline='
'
    [ -n "$target" ] || die 'init 文件路径不能为空。'
    case "$target" in
        /*) ;;
        *) die 'init 文件必须使用绝对路径。' ;;
    esac
    case "$target" in
        /|"${HOME:-__unset_home__}") die '拒绝把危险目录当作 init 文件。' ;;
        *"$newline"*) die 'init 文件路径不能包含换行符。' ;;
    esac
    [ ! -L "$target" ] || die "拒绝符号链接 init 文件：$target"
    if [ -e "$target" ] && [ ! -f "$target" ]; then
        die "init 目标不是普通文件：$target"
    fi
    parent=$(dirname "$target")
    if [ -e "$parent" ] && [ ! -d "$parent" ]; then
        die "init 父路径不是目录：$parent"
    fi
}

MODE=
INIT_FILE=
ASSUME_YES=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --print)
            [ -z "$MODE" ] || die '--print 与其他操作模式不能同时使用。'
            MODE=print
            shift
            ;;
        --install)
            [ -z "$MODE" ] || die '--install 与其他操作模式不能同时使用。'
            MODE=install
            shift
            ;;
        --init-file)
            [ "$#" -ge 2 ] || die '--init-file 缺少路径。'
            INIT_FILE=$2
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知选项：$1"
            ;;
    esac
done

case "$MODE" in
    print)
        [ "$ASSUME_YES" -eq 0 ] || die '--yes 只能与 --install 一起使用。'
        [ -z "$INIT_FILE" ] || die '--init-file 只能与 --install 一起使用。'
        print_snippet
        exit 0
        ;;
    install) ;;
    '')
        usage
        exit 0
        ;;
    *) die '内部操作模式无效。' ;;
esac

if [ -z "$INIT_FILE" ]; then
    INIT_FILE=$(default_init_file)
fi
validate_init_file "$INIT_FILE"

begin_count=0
end_count=0
if [ -f "$INIT_FILE" ]; then
    begin_count=$(grep -F -c "$BEGIN_MARKER" "$INIT_FILE" || true)
    end_count=$(grep -F -c "$END_MARKER" "$INIT_FILE" || true)
fi
if [ "$begin_count" -eq 1 ] && [ "$end_count" -eq 1 ]; then
    printf '已安装，无需修改：%s\n' "$INIT_FILE"
    exit 0
fi
if [ "$begin_count" -ne 0 ] || [ "$end_count" -ne 0 ]; then
    die "检测到不完整或重复的 YAGARTO Mac 标记，请手动检查：$INIT_FILE"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die '无 TTY，未修改 init 文件；请在终端确认，或显式提供 --yes。'
    printf '将修改 Emacs init 文件：%s\n输入 yes 继续：' "$INIT_FILE" >&2
    answer=
    IFS= read -r answer || true
    if [ "$answer" != yes ]; then
        printf '%s\n' '已取消，未修改任何文件。'
        exit 0
    fi
fi

parent=$(dirname "$INIT_FILE")
if [ ! -d "$parent" ]; then
    mkdir -p "$parent" || die "无法创建 init 目录：$parent"
fi

temporary=$parent/.yagarto-mac-init.$$
[ ! -e "$temporary" ] && [ ! -L "$temporary" ] \
    || die "临时文件已存在，请重试：$temporary"
(umask 077; set -C; : >"$temporary") \
    || die "无法安全创建临时文件：$temporary"
trap 'rm -f "$temporary"' EXIT HUP INT TERM

if [ -f "$INIT_FILE" ]; then
    cp -p "$INIT_FILE" "$temporary" || die '无法复制原 init 文件。'
    backup=$INIT_FILE.yagarto-mac.bak
    if [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
        cp -p "$INIT_FILE" "$backup" || die "无法创建备份：$backup"
    fi
    printf '\n' >>"$temporary"
fi
print_snippet >>"$temporary"
printf '\n' >>"$temporary"

[ ! -L "$INIT_FILE" ] || die "安装期间 init 文件变成符号链接，已中止：$INIT_FILE"
mv -f "$temporary" "$INIT_FILE" || die "无法原子更新 init 文件：$INIT_FILE"
trap - EXIT HUP INT TERM
printf '已安装 YAGARTO Mac Emacs 集成：%s\n' "$INIT_FILE"
