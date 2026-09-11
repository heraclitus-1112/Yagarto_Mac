#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
EMACS_DIRECTORY=$REPOSITORY_ROOT/emacs
BEGIN_MARKER=';; YAGARTO Mac integration BEGIN'
END_MARKER=';; YAGARTO Mac integration END'
LOCK_DIRECTORY=
LOCK_TOKEN=
LOCK_OWNED=0
temporary=
CONFIRMED=0

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

validate_init_path() {
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
    parent=$(dirname "$target")
    if [ -e "$parent" ] && [ ! -d "$parent" ]; then
        die "init 父路径不是目录：$parent"
    fi
}

validate_existing_init_file() {
    target=$1
    [ ! -L "$target" ] || die "拒绝符号链接 init 文件：$target"
    if [ ! -e "$target" ]; then
        return 0
    fi
    [ -f "$target" ] || die "init 目标不是普通文件：$target"

    metadata=$(LC_ALL=C ls -ldn "$target") \
        || die "无法检查 init 文件元数据：$target"
    # POSIX ls -l 的前三个字段依次是权限、硬链接数和 owner uid。
    # 文件名即使含中文或空格，也不会影响这三个固定字段。
    set -f
    set -- $metadata
    set +f
    permissions=$1
    link_count=$2
    owner_uid=$3
    case "$link_count" in
        ''|*[!0-9]*) die "无法识别 init 文件硬链接数：$target" ;;
    esac
    [ "$link_count" -eq 1 ] \
        || die "拒绝具有多个硬链接的 init 文件：$target"
    current_uid=$(id -u) || die '无法取得当前用户 uid。'
    [ "$owner_uid" = "$current_uid" ] \
        || die "init 文件不属于当前用户，拒绝修改：$target"
    case "$permissions" in
        ?????w????*|????????w?*)
            die "init 文件可被组或其他用户写入，拒绝修改：$target"
            ;;
    esac
}

release_lock() {
    [ "$LOCK_OWNED" -eq 1 ] || return 0
    recorded_token=
    if [ -f "$LOCK_DIRECTORY/owner" ] && [ ! -L "$LOCK_DIRECTORY/owner" ]; then
        IFS= read -r recorded_token <"$LOCK_DIRECTORY/owner" || true
    fi
    if [ "$recorded_token" = "$LOCK_TOKEN" ]; then
        rm -f "$LOCK_DIRECTORY/owner" || true
        rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
    elif [ -d "$LOCK_DIRECTORY" ] && [ ! -e "$LOCK_DIRECTORY/owner" ]; then
        # 覆盖 mkdir 成功、owner 写入前收到信号的极短窗口。
        rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
    fi
    LOCK_OWNED=0
}

cleanup() {
    cleanup_status=$?
    trap - EXIT
    if [ -n "$temporary" ]; then
        rm -f "$temporary" || true
    fi
    release_lock
    exit "$cleanup_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

lock_timeout_seconds() {
    timeout=${YAGARTO_EMACS_INSTALL_LOCK_TIMEOUT_SECONDS:-15}
    case "$timeout" in
        ''|*[!0-9]*) die '锁等待超时必须是正整数秒。' ;;
    esac
    [ "$timeout" -gt 0 ] || die '锁等待超时必须大于 0 秒。'
    printf '%s\n' "$timeout"
}

report_lock_timeout() {
    owner_description=未知
    owner_pid=
    if [ -f "$LOCK_DIRECTORY/owner" ] && [ ! -L "$LOCK_DIRECTORY/owner" ]; then
        IFS= read -r owner_description <"$LOCK_DIRECTORY/owner" || true
        owner_pid=${owner_description%%:*}
    fi
    case "$owner_pid" in
        ''|*[!0-9]*)
            die "等待 init 锁超时；锁 owner 无法识别，可能是陈旧锁：$LOCK_DIRECTORY"
            ;;
        *)
            if ! kill -0 "$owner_pid" 2>/dev/null; then
                die "等待 init 锁超时；检测到陈旧锁（owner ${owner_description}）：$LOCK_DIRECTORY"
            fi
            die "等待 init 锁超时；仍由进程 ${owner_pid} 持有：$LOCK_DIRECTORY"
            ;;
    esac
}

acquire_lock() {
    lock_parent=$1
    LOCK_DIRECTORY=$lock_parent/.yagarto-mac-init.lock
    LOCK_TOKEN="$$:$(date +%s)"
    timeout=$(lock_timeout_seconds)
    waited=0
    while ! (umask 077; mkdir "$LOCK_DIRECTORY") 2>/dev/null; do
        [ "$waited" -lt "$timeout" ] || report_lock_timeout
        sleep 1
        waited=$((waited + 1))
    done
    LOCK_OWNED=1
    (umask 077; printf '%s\n' "$LOCK_TOKEN" >"$LOCK_DIRECTORY/owner") \
        || die "无法记录 init 锁 owner：$LOCK_DIRECTORY"
}

confirm_installation() {
    [ "$ASSUME_YES" -ne 1 ] || return 0
    [ "$CONFIRMED" -ne 1 ] || return 0
    [ -t 0 ] || die '无 TTY，未修改 init 文件；请在终端确认，或显式提供 --yes。'
    printf '将修改 Emacs init 文件：%s\n输入 yes 继续：' "$INIT_FILE" >&2
    answer=
    IFS= read -r answer || true
    if [ "$answer" != yes ]; then
        printf '%s\n' '已取消，未修改任何文件。'
        exit 0
    fi
    CONFIRMED=1
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
validate_init_path "$INIT_FILE"

parent=$(dirname "$INIT_FILE")
# 不存在的目标没有配置内容可检查；先确认，保证拒绝/无 TTY 时连目录和
# 临时锁都不会创建。现有目标则先加锁再读取，以保留幂等快速返回。
if [ ! -e "$INIT_FILE" ] && [ ! -L "$INIT_FILE" ]; then
    confirm_installation
fi
if [ ! -d "$parent" ]; then
    mkdir -p "$parent" || die "无法创建 init 目录：$parent"
fi
acquire_lock "$parent"
validate_existing_init_file "$INIT_FILE"

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

confirm_installation

temporary=$parent/.yagarto-mac-init.$$
[ ! -e "$temporary" ] && [ ! -L "$temporary" ] \
    || die "临时文件已存在，请重试：$temporary"
(umask 077; set -C; : >"$temporary") \
    || die "无法安全创建临时文件：$temporary"

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

validate_existing_init_file "$INIT_FILE"
mv -f "$temporary" "$INIT_FILE" || die "无法原子更新 init 文件：$INIT_FILE"
temporary=
release_lock
printf '已安装 YAGARTO Mac Emacs 集成：%s\n' "$INIT_FILE"
