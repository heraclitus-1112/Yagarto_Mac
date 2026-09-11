#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu
umask 077

# GDB 16 deprecated ARM sim and GDB 17 removed sim/arm from the release
# archive. 15.2 is the newest release that still builds the ARM simulator
# without carrying an out-of-tree copy of the removed backend.
GDB_VERSION=15.2
GDB_ARCHIVE="gdb-${GDB_VERSION}.tar.xz"
GDB_URL="https://ftp.gnu.org/gnu/gdb/${GDB_ARCHIVE}"
SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
COMPATIBILITY_PATCH="${SCRIPT_DIRECTORY}/patches/gdb-15.2-macos26.patch"

usage() {
    cat <<EOF
用法：
  bootstrap-gdb-sim.sh --prefix DIR --sha256 HEX [--archive FILE]
  bootstrap-gdb-sim.sh --verify-gdb FILE

构建并安装带 ARM simulator 的 GNU GDB ${GDB_VERSION}。

必填：
  --prefix DIR     显式安装前缀
  --sha256 HEX     ${GDB_ARCHIVE} 的预期 SHA-256（64 位十六进制）

可选：
  --archive FILE   使用本地 ${GDB_ARCHIVE}，避免下载
  --verify-gdb FILE
                   仅对已安装的 GDB 执行完整 ARM7 simulator 自测
  -h, --help       显示帮助

固定来源：${GDB_URL}
EOF
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
    usage
    exit 0
fi

INSTALL_PREFIX=
EXPECTED_SHA256=
LOCAL_ARCHIVE=
VERIFY_GDB=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || { echo "--prefix 缺少目录参数。" >&2; exit 2; }
            INSTALL_PREFIX=$2
            shift 2
            ;;
        --sha256)
            [ "$#" -ge 2 ] || { echo "--sha256 缺少校验值。" >&2; exit 2; }
            EXPECTED_SHA256=$2
            shift 2
            ;;
        --archive)
            [ "$#" -ge 2 ] || { echo "--archive 缺少文件参数。" >&2; exit 2; }
            LOCAL_ARCHIVE=$2
            shift 2
            ;;
        --verify-gdb)
            [ "$#" -ge 2 ] || { echo "--verify-gdb 缺少可执行文件参数。" >&2; exit 2; }
            VERIFY_GDB=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数：$1" >&2
            exit 2
            ;;
    esac
done

WORK_DIRECTORY=
ACTIVE_PID=
WATCHDOG_PID=
LAUNCHING=
PENDING_SIGNAL_NUMBER=
PENDING_SIGNAL_NAME=
RECEIVED_SIGNAL_NUMBER=
RECEIVED_SIGNAL_NAME=
SUPERVISED_TIMED_OUT=
SUPERVISOR_PID=$$
cleanup() {
    if [ -n "$WORK_DIRECTORY" ] && [ -d "$WORK_DIRECTORY" ]; then
        rm -rf "$WORK_DIRECTORY"
    fi
}
trap cleanup EXIT

process_group_has_live_members() {
    group_to_check=$1
    ps -axo pgid=,stat= 2>/dev/null | awk -v group="$group_to_check" '
        $1 == group && $2 !~ /^Z/ { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

wait_for_process_group() {
    group_to_wait_for=$1
    wait_iteration=0
    while [ "$wait_iteration" -lt 4 ]; do
        if ! process_group_has_live_members "$group_to_wait_for"; then
            return 0
        fi
        /bin/sleep 0.05
        wait_iteration=$((wait_iteration + 1))
    done
    ! process_group_has_live_members "$group_to_wait_for"
}

stop_watchdog() {
    if [ -n "$WATCHDOG_PID" ]; then
        kill -TERM -- "-${WATCHDOG_PID}" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=
    fi
}

reap_active_process_group() {
    if [ -z "$ACTIVE_PID" ]; then
        return 0
    fi
    if ! wait_for_process_group "$ACTIVE_PID"; then
        kill -TERM -- "-${ACTIVE_PID}" 2>/dev/null || true
        if ! wait_for_process_group "$ACTIVE_PID"; then
            kill -KILL -- "-${ACTIVE_PID}" 2>/dev/null || true
            wait_for_process_group "$ACTIVE_PID" || true
        fi
    fi
    wait "$ACTIVE_PID" 2>/dev/null || true
}

record_signal() {
    signal_name=$1
    signal_number=$2
    if [ -z "$RECEIVED_SIGNAL_NUMBER" ]; then
        RECEIVED_SIGNAL_NAME=$signal_name
        RECEIVED_SIGNAL_NUMBER=$signal_number
    fi
    if [ -n "$ACTIVE_PID" ]; then
        kill -"$signal_name" -- "-${ACTIVE_PID}" 2>/dev/null || true
    elif [ -n "$LAUNCHING" ]; then
        if [ -z "$PENDING_SIGNAL_NUMBER" ]; then
            PENDING_SIGNAL_NAME=$signal_name
            PENDING_SIGNAL_NUMBER=$signal_number
        fi
    else
        trap '' HUP INT TERM
        exit $((128 + signal_number))
    fi
}

record_timeout() {
    SUPERVISED_TIMED_OUT=1
    if [ -n "$ACTIVE_PID" ]; then
        kill -TERM -- "-${ACTIVE_PID}" 2>/dev/null || true
    fi
}

trap 'record_signal HUP 1' HUP
trap 'record_signal INT 2' INT
trap 'record_signal TERM 15' TERM
trap 'record_timeout' ALRM

exercise_launch_gap_test_hook() {
    command_name=$1
    requested_target=${YAGARTO_BOOTSTRAP_TEST_LAUNCH_TARGET:-}
    requested_signal=${YAGARTO_BOOTSTRAP_TEST_SIGNAL_DURING_LAUNCH:-}
    ready_file=${YAGARTO_BOOTSTRAP_TEST_LAUNCH_READY_FILE:-}
    if [ -z "$requested_target" ] || [ "$command_name" != "$requested_target" ]; then
        return 0
    fi
    case "$requested_signal" in
        HUP|INT|TERM) ;;
        *) return 0 ;;
    esac
    if [ -n "$ready_file" ]; then
        hook_iteration=0
        while [ ! -f "$ready_file" ] && [ "$hook_iteration" -lt 200 ]; do
            /bin/sleep 0.01
            hook_iteration=$((hook_iteration + 1))
        done
    fi
    kill -"$requested_signal" "$SUPERVISOR_PID"
}

run_supervised_with_timeout() {
    supervised_timeout=$1
    shift
    RECEIVED_SIGNAL_NUMBER=
    RECEIVED_SIGNAL_NAME=
    SUPERVISED_TIMED_OUT=
    PENDING_SIGNAL_NUMBER=
    PENDING_SIGNAL_NAME=

    # POSIX monitor mode assigns this background job its own process group.
    # Turn it off immediately so the non-interactive shell stays quiet.
    LAUNCHING=1
    set -m
    "$@" &
    launched_pid=$!
    exercise_launch_gap_test_hook "$1"
    ACTIVE_PID=$launched_pid
    LAUNCHING=
    set +m

    if [ -n "$PENDING_SIGNAL_NUMBER" ]; then
        kill -"$PENDING_SIGNAL_NAME" -- "-${ACTIVE_PID}" 2>/dev/null || true
        trap '' HUP INT TERM
        reap_active_process_group
        ACTIVE_PID=
        exit $((128 + PENDING_SIGNAL_NUMBER))
    fi

    if [ "$supervised_timeout" -gt 0 ]; then
        set -m
        (
            /bin/sleep "$supervised_timeout"
            kill -ALRM "$SUPERVISOR_PID" 2>/dev/null || true
        ) &
        WATCHDOG_PID=$!
        set +m
    fi

    if wait "$ACTIVE_PID" 2>/dev/null; then
        supervised_status=0
    else
        supervised_status=$?
    fi

    stop_watchdog
    if [ -n "$RECEIVED_SIGNAL_NUMBER" ]; then
        trap '' HUP INT TERM
        reap_active_process_group
        ACTIVE_PID=
        exit $((128 + RECEIVED_SIGNAL_NUMBER))
    fi
    if [ -n "$SUPERVISED_TIMED_OUT" ]; then
        trap '' HUP INT TERM
        reap_active_process_group
        ACTIVE_PID=
        trap 'record_signal HUP 1' HUP
        trap 'record_signal INT 2' INT
        trap 'record_signal TERM 15' TERM
        echo "受控命令执行超时（${supervised_timeout} 秒）。" >&2
        return 124
    fi

    ACTIVE_PID=
    return "$supervised_status"
}

run_supervised() {
    run_supervised_with_timeout 0 "$@"
}

verify_installed_gdb() {
    gdb_to_verify=$1
    if [ ! -x "$gdb_to_verify" ]; then
        echo "GDB 自测目标不可执行：${gdb_to_verify}" >&2
        return 1
    fi

    arm_assembler=$(command -v arm-none-eabi-as 2>/dev/null || true)
    arm_linker=$(command -v arm-none-eabi-ld 2>/dev/null || true)
    if [ -z "$arm_assembler" ] || [ -z "$arm_linker" ]; then
        echo "完整 GDB 自测需要 arm-none-eabi-as 和 arm-none-eabi-ld。" >&2
        return 1
    fi

    if [ -z "$WORK_DIRECTORY" ]; then
        WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/yagarto-gdb.XXXXXX")
    fi
    selftest_directory="${WORK_DIRECTORY}/gdb-simulator-selftest"
    mkdir -p "$selftest_directory"
    cat > "${selftest_directory}/selftest.s" <<'EOF'
.syntax unified
.cpu arm7tdmi
.text
.global _start
.type _start, %function
_start:
    mov r0, #1
    add r0, r0, #1
1:
    b 1b
EOF
    run_supervised "$arm_assembler" -mcpu=arm7tdmi -g \
        -o "${selftest_directory}/selftest.o" \
        "${selftest_directory}/selftest.s"
    run_supervised "$arm_linker" -Ttext=0x00008000 -e _start \
        -o "${selftest_directory}/selftest.elf" \
        "${selftest_directory}/selftest.o"

    selftest_output="${selftest_directory}/gdb-output.log"
    verify_timeout=${YAGARTO_GDB_VERIFY_TIMEOUT_SECONDS:-30}
    case "$verify_timeout" in
        ''|*[!0-9]*|0)
            echo "YAGARTO_GDB_VERIFY_TIMEOUT_SECONDS 必须是正整数。" >&2
            return 1
            ;;
    esac
    run_gdb_selftest() (
        cd "$selftest_directory"
        exec "$gdb_to_verify" -q -nx -batch \
            -ex "file selftest.elf" \
            -ex "target sim" \
            -ex "load" \
            -ex "break _start" \
            -ex "run" \
            -ex "stepi" \
            -ex "info registers r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc cpsr"
    )
    if ! run_supervised_with_timeout "$verify_timeout" run_gdb_selftest \
        >"$selftest_output" 2>&1; then
        echo "安装后的 GDB 未通过完整 ARM7 simulator 自测：" >&2
        sed -n '1,160p' "$selftest_output" >&2
        return 1
    fi

    for register in r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc cpsr; do
        if ! grep -E "^[[:space:]]*${register}[[:space:]]" "$selftest_output" >/dev/null 2>&1; then
            echo "完整 GDB 自测未能读取寄存器 ${register}：" >&2
            sed -n '1,160p' "$selftest_output" >&2
            return 1
        fi
    done
    if ! grep -Ei '^[[:space:]]*r0[[:space:]]+0x0*1([[:space:]]|$)' "$selftest_output" >/dev/null 2>&1; then
        echo "完整 GDB 自测的 stepi 未得到预期 r0=1：" >&2
        sed -n '1,160p' "$selftest_output" >&2
        return 1
    fi
    echo "完整 ARM7 simulator 自测通过：target sim、ELF load、断点、单步和 r0-r12/sp/lr/pc/cpsr。"
}

if [ -n "$VERIFY_GDB" ]; then
    if [ -n "$INSTALL_PREFIX" ] || [ -n "$EXPECTED_SHA256" ] || [ -n "$LOCAL_ARCHIVE" ]; then
        echo "--verify-gdb 不能与安装参数同时使用。" >&2
        exit 2
    fi
    verify_installed_gdb "$VERIFY_GDB"
    exit 0
fi

if [ -z "$INSTALL_PREFIX" ]; then
    echo "必须显式提供 --prefix DIR。" >&2
    exit 2
fi
if [ -z "$EXPECTED_SHA256" ]; then
    echo "必须提供 --sha256 HEX；不会跳过源码校验。" >&2
    exit 2
fi
case "$EXPECTED_SHA256" in
    *[!0-9A-Fa-f]* )
        echo "--sha256 必须是 64 位十六进制 SHA-256。" >&2
        exit 2
        ;;
esac
if [ "${#EXPECTED_SHA256}" -ne 64 ]; then
    echo "--sha256 必须是 64 位十六进制 SHA-256。" >&2
    exit 2
fi

case "$INSTALL_PREFIX" in
    /*) ;;
    *)
        echo "--prefix 必须是绝对路径。" >&2
        exit 2
        ;;
esac
case "$INSTALL_PREFIX" in
    *"
"*)
        echo "--prefix 不能包含换行符。" >&2
        exit 2
        ;;
esac

PREFIX_CANDIDATE=$INSTALL_PREFIX
PREFIX_SUFFIX=
while [ ! -e "$PREFIX_CANDIDATE" ]; do
    if [ "$PREFIX_CANDIDATE" = "/" ]; then
        break
    fi
    PREFIX_COMPONENT=${PREFIX_CANDIDATE##*/}
    PREFIX_SUFFIX="/${PREFIX_COMPONENT}${PREFIX_SUFFIX}"
    PREFIX_CANDIDATE=${PREFIX_CANDIDATE%/*}
    if [ -z "$PREFIX_CANDIDATE" ]; then
        PREFIX_CANDIDATE=/
    fi
done
if [ ! -d "$PREFIX_CANDIDATE" ]; then
    echo "--prefix 的现有祖先不是目录：${PREFIX_CANDIDATE}" >&2
    exit 2
fi
PHYSICAL_PREFIX_BASE=$(
    cd "$PREFIX_CANDIDATE" 2>/dev/null && pwd -P
) || {
    echo "无法解析 --prefix：${INSTALL_PREFIX}" >&2
    exit 2
}
INSTALL_PREFIX=$(printf '%s\n' "${PHYSICAL_PREFIX_BASE}${PREFIX_SUFFIX}" | awk -F/ '
{
    depth = 0
    for (i = 1; i <= NF; i++) {
        if ($i == "" || $i == ".") {
            continue
        }
        if ($i == "..") {
            if (depth > 0) {
                depth--
            }
            continue
        }
        component[++depth] = $i
    }
    if (depth == 0) {
        print "/"
        next
    }
    result = ""
    for (i = 1; i <= depth; i++) {
        result = result "/" component[i]
    }
    print result
}')
if [ "$INSTALL_PREFIX" = "/" ]; then
    echo "拒绝把系统根目录用作 --prefix。" >&2
    exit 2
fi

verify_archive() {
    archive_to_verify=$1
    if [ ! -f "$archive_to_verify" ]; then
        echo "源码归档不存在：${archive_to_verify}" >&2
        exit 1
    fi
    checksum_tool=
    if command -v shasum >/dev/null 2>&1; then
        checksum_tool=shasum
    elif command -v sha256sum >/dev/null 2>&1; then
        checksum_tool=sha256sum
    fi
    if [ -z "$checksum_tool" ]; then
        echo "缺少 SHA-256 校验工具（shasum 或 sha256sum）。" >&2
        exit 1
    fi

    checksum_output="${WORK_DIRECTORY}/archive-checksum.txt"
    calculate_archive_checksum() {
        if [ "$checksum_tool" = "shasum" ]; then
            exec shasum -a 256 "$archive_to_verify"
        fi
        exec sha256sum "$archive_to_verify"
    }
    if ! run_supervised calculate_archive_checksum >"$checksum_output"; then
        echo "SHA-256 工具执行失败。" >&2
        exit 1
    fi
    ACTUAL_SHA256=
    IFS=' ' read -r ACTUAL_SHA256 ignored_checksum_path <"$checksum_output" || true
    normalize_checksum() {
        printf '%s' "$1" | tr 'A-F' 'a-f'
    }
    expected_output="${WORK_DIRECTORY}/expected-checksum.txt"
    actual_output="${WORK_DIRECTORY}/actual-checksum.txt"
    run_supervised normalize_checksum "$EXPECTED_SHA256" >"$expected_output"
    run_supervised normalize_checksum "$ACTUAL_SHA256" >"$actual_output"
    NORMALIZED_EXPECTED=
    NORMALIZED_ACTUAL=
    IFS= read -r NORMALIZED_EXPECTED <"$expected_output" || true
    IFS= read -r NORMALIZED_ACTUAL <"$actual_output" || true
    if [ "$NORMALIZED_ACTUAL" != "$NORMALIZED_EXPECTED" ]; then
        echo "SHA-256 校验失败：预期 ${NORMALIZED_EXPECTED}，实际 ${NORMALIZED_ACTUAL}。" >&2
        exit 1
    fi
}

if [ -z "$WORK_DIRECTORY" ]; then
    WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/yagarto-gdb.XXXXXX")
fi

if [ -n "$LOCAL_ARCHIVE" ]; then
    ARCHIVE_PATH="${WORK_DIRECTORY}/${GDB_ARCHIVE}.verified-snapshot"
    if ! run_supervised cp "$LOCAL_ARCHIVE" "$ARCHIVE_PATH"; then
        echo "无法创建本地源码归档快照。" >&2
        exit 1
    fi
    if [ ! -f "$ARCHIVE_PATH" ] || [ -L "$ARCHIVE_PATH" ]; then
        echo "本地源码归档快照不是安全的普通文件。" >&2
        exit 1
    fi
else
    command -v curl >/dev/null 2>&1 || {
        echo "缺少 curl，无法下载固定 GDB 源码归档。" >&2
        exit 1
    }
    ARCHIVE_PATH="${WORK_DIRECTORY}/${GDB_ARCHIVE}"
    echo "下载 ${GDB_URL}"
    run_supervised curl --fail --location --proto '=https' --tlsv1.2 \
        --output "$ARCHIVE_PATH" "$GDB_URL"
fi
verify_archive "$ARCHIVE_PATH"

command -v gmake >/dev/null 2>&1 || {
    echo "缺少 gmake；请安装 GNU make（Homebrew: brew install make）。" >&2
    exit 1
}
command -v makeinfo >/dev/null 2>&1 || {
    echo "缺少 makeinfo；请安装 texinfo（Homebrew: brew install texinfo）。" >&2
    exit 1
}
command -v tar >/dev/null 2>&1 || {
    echo "缺少 tar，无法解压 GDB 源码。" >&2
    exit 1
}

GDB_CPPFLAGS=
GDB_LDFLAGS=
GMP_PREFIX=
MPFR_PREFIX=
if command -v pkg-config >/dev/null 2>&1 \
    && run_supervised pkg-config --exists gmp \
    && run_supervised pkg-config --exists mpfr; then
    pkg_cflags_output="${WORK_DIRECTORY}/pkg-cflags.txt"
    pkg_ldflags_output="${WORK_DIRECTORY}/pkg-ldflags.txt"
    gmp_prefix_output="${WORK_DIRECTORY}/gmp-prefix.txt"
    mpfr_prefix_output="${WORK_DIRECTORY}/mpfr-prefix.txt"
    run_supervised pkg-config --cflags gmp mpfr >"$pkg_cflags_output"
    run_supervised pkg-config --libs-only-L gmp mpfr >"$pkg_ldflags_output"
    run_supervised pkg-config --variable=prefix gmp >"$gmp_prefix_output"
    run_supervised pkg-config --variable=prefix mpfr >"$mpfr_prefix_output"
    IFS= read -r GDB_CPPFLAGS <"$pkg_cflags_output" || true
    IFS= read -r GDB_LDFLAGS <"$pkg_ldflags_output" || true
    IFS= read -r GMP_PREFIX <"$gmp_prefix_output" || true
    IFS= read -r MPFR_PREFIX <"$mpfr_prefix_output" || true
elif command -v brew >/dev/null 2>&1; then
    gmp_prefix_output="${WORK_DIRECTORY}/gmp-prefix.txt"
    mpfr_prefix_output="${WORK_DIRECTORY}/mpfr-prefix.txt"
    run_supervised brew --prefix gmp >"$gmp_prefix_output" 2>/dev/null || true
    run_supervised brew --prefix mpfr >"$mpfr_prefix_output" 2>/dev/null || true
    IFS= read -r GMP_PREFIX <"$gmp_prefix_output" || true
    IFS= read -r MPFR_PREFIX <"$mpfr_prefix_output" || true
    if [ -z "$GMP_PREFIX" ] || [ -z "$MPFR_PREFIX" ]; then
        echo "缺少 gmp 或 mpfr；请运行 brew install gmp mpfr。" >&2
        exit 1
    fi
    GDB_CPPFLAGS="-I${GMP_PREFIX}/include -I${MPFR_PREFIX}/include"
    GDB_LDFLAGS="-L${GMP_PREFIX}/lib -L${MPFR_PREFIX}/lib"
else
    echo "未检测到 gmp/mpfr；请通过 pkg-config 或 Homebrew 安装它们。" >&2
    exit 1
fi
if [ -z "$GMP_PREFIX" ] || [ -z "$MPFR_PREFIX" ]; then
    echo "无法确定 gmp 或 mpfr 的安装前缀。" >&2
    exit 1
fi

READLINE_CFLAGS=
READLINE_LDFLAGS=
READLINE_VERSION=
if command -v brew >/dev/null 2>&1; then
    readline_prefix_output="${WORK_DIRECTORY}/readline-prefix.txt"
    run_supervised brew --prefix readline >"$readline_prefix_output" 2>/dev/null || true
    READLINE_PREFIX=
    IFS= read -r READLINE_PREFIX <"$readline_prefix_output" || true
    if [ -n "$READLINE_PREFIX" ]; then
        READLINE_CFLAGS="-I${READLINE_PREFIX}/include"
        READLINE_LDFLAGS="-L${READLINE_PREFIX}/lib"
        readline_header="${READLINE_PREFIX}/include/readline/readline.h"
        if [ -f "$readline_header" ]; then
            readline_version_output="${WORK_DIRECTORY}/readline-version.txt"
            run_supervised awk \
                '$1 == "#define" && $2 == "RL_VERSION_MAJOR" { print $3; exit }' \
                "$readline_header" >"$readline_version_output"
            IFS= read -r READLINE_VERSION <"$readline_version_output" || true
        fi
    fi
fi
if [ -z "$READLINE_CFLAGS" ] && command -v pkg-config >/dev/null 2>&1 \
    && run_supervised pkg-config --exists readline; then
    readline_cflags_output="${WORK_DIRECTORY}/readline-cflags.txt"
    readline_ldflags_output="${WORK_DIRECTORY}/readline-ldflags.txt"
    run_supervised pkg-config --cflags readline >"$readline_cflags_output"
    run_supervised pkg-config --libs-only-L readline >"$readline_ldflags_output"
    readline_version_output="${WORK_DIRECTORY}/readline-version.txt"
    run_supervised pkg-config --modversion readline >"$readline_version_output"
    IFS= read -r READLINE_CFLAGS <"$readline_cflags_output" || true
    IFS= read -r READLINE_LDFLAGS <"$readline_ldflags_output" || true
    IFS= read -r READLINE_VERSION <"$readline_version_output" || true
fi
if [ -z "$READLINE_CFLAGS" ]; then
    echo "缺少可用的 Readline；请运行 brew install readline。" >&2
    exit 1
fi
READLINE_MAJOR=${READLINE_VERSION%%.*}
case "$READLINE_MAJOR" in
    ''|*[!0-9]*)
        echo "无法确认 Readline 版本；GDB 15.2 需要 Readline 7 或更高版本。" >&2
        exit 1
        ;;
esac
if [ "$READLINE_MAJOR" -lt 7 ]; then
    echo "Readline 版本过旧；GDB 15.2 需要 Readline 7 或更高版本。" >&2
    exit 1
fi
GDB_CPPFLAGS="${GDB_CPPFLAGS} ${READLINE_CFLAGS}"
GDB_LDFLAGS="${GDB_LDFLAGS} ${READLINE_LDFLAGS}"

SOURCE_DIRECTORY="${WORK_DIRECTORY}/gdb-${GDB_VERSION}"
BUILD_DIRECTORY="${WORK_DIRECTORY}/build"
run_supervised tar -xf "$ARCHIVE_PATH" -C "$WORK_DIRECTORY"
if [ ! -x "${SOURCE_DIRECTORY}/configure" ]; then
    echo "归档内容无效：缺少 gdb-${GDB_VERSION}/configure。" >&2
    exit 1
fi
if [ ! -f "$COMPATIBILITY_PATCH" ]; then
    echo "缺少 GDB macOS 兼容补丁：${COMPATIBILITY_PATCH}" >&2
    exit 1
fi
command -v patch >/dev/null 2>&1 || {
    echo "缺少 patch，无法应用 GDB macOS 兼容补丁。" >&2
    exit 1
}
apply_compatibility_patch() (
    cd "$SOURCE_DIRECTORY"
    exec patch --batch --forward -p1 -i "$COMPATIBILITY_PATCH"
)
run_supervised apply_compatibility_patch
mkdir -p "$BUILD_DIRECTORY"

GDB_CC=${CC:-}
GDB_CXX=${CXX:-}
if [ -z "$GDB_CC" ] && command -v gcc-15 >/dev/null 2>&1; then
    GDB_CC=$(command -v gcc-15)
fi
if [ -z "$GDB_CXX" ] && command -v g++-15 >/dev/null 2>&1; then
    GDB_CXX=$(command -v g++-15)
fi
if [ -z "$GDB_CC" ]; then
    GDB_CC=cc
fi
if [ -z "$GDB_CXX" ]; then
    GDB_CXX=c++
fi
command -v "$GDB_CC" >/dev/null 2>&1 || {
    echo "缺少 C 编译器：${GDB_CC}" >&2
    exit 1
}
command -v "$GDB_CXX" >/dev/null 2>&1 || {
    echo "缺少 C++ 编译器：${GDB_CXX}" >&2
    exit 1
}
case "$(uname -s 2>/dev/null || true)" in
    Darwin)
        GDB_SED=$(command -v gsed 2>/dev/null || true)
        ;;
    *)
        GDB_SED=$(command -v sed 2>/dev/null || true)
        ;;
esac
if [ -z "$GDB_SED" ]; then
    echo "缺少兼容的 sed；macOS 请安装 GNU sed（brew install gnu-sed）。" >&2
    exit 1
fi
COMPAT_TOOL_DIRECTORY="${WORK_DIRECTORY}/compat-tools"
mkdir -p "$COMPAT_TOOL_DIRECTORY"
run_supervised ln -s "$GDB_SED" "${COMPAT_TOOL_DIRECTORY}/sed"
BUILD_PATH="${COMPAT_TOOL_DIRECTORY}:${PATH}"
PATH="$BUILD_PATH"
export PATH
gdb_cv_readline_ok=yes
export gdb_cv_readline_ok
CPPFLAGS="$GDB_CPPFLAGS"
LDFLAGS="$GDB_LDFLAGS"
export CPPFLAGS LDFLAGS

echo "配置 GNU GDB ${GDB_VERSION}（target: arm-none-eabi，simulator 保持启用）"
configure_gdb() (
    cd "$BUILD_DIRECTORY"
    exec env PATH="$BUILD_PATH" CC="$GDB_CC" CXX="$GDB_CXX" \
        SED="$GDB_SED" CPPFLAGS="$GDB_CPPFLAGS" LDFLAGS="$GDB_LDFLAGS" \
        "${SOURCE_DIRECTORY}/configure" \
        --target=arm-none-eabi \
        --prefix="$INSTALL_PREFIX" \
        --with-gmp="$GMP_PREFIX" \
        --with-mpfr="$MPFR_PREFIX" \
        --with-system-zlib \
        --with-system-readline \
        --disable-werror \
        gdb_cv_readline_ok=yes
)
run_supervised configure_gdb

job_count_output="${WORK_DIRECTORY}/job-count.txt"
run_supervised sysctl -n hw.logicalcpu >"$job_count_output" 2>/dev/null || true
JOB_COUNT=
IFS= read -r JOB_COUNT <"$job_count_output" || true
case "$JOB_COUNT" in
    ''|*[!0-9]*) JOB_COUNT=2 ;;
esac
run_supervised gmake -C "$BUILD_DIRECTORY" -j "$JOB_COUNT"
run_supervised gmake -C "$BUILD_DIRECTORY" install

INSTALLED_GDB="${INSTALL_PREFIX}/bin/arm-none-eabi-gdb"
SIMULATOR_ALIAS="${INSTALL_PREFIX}/bin/arm-none-eabi-gdb-sim"
if [ ! -x "$INSTALLED_GDB" ]; then
    echo "安装后未找到 ${INSTALLED_GDB}。" >&2
    exit 1
fi
verify_installed_gdb "$INSTALLED_GDB"
run_supervised ln -sf "arm-none-eabi-gdb" "$SIMULATOR_ALIAS"

echo "已安装并验证：${SIMULATOR_ALIAS}"
echo "可设置：export YAGARTO_MAC_GDB_SIM='${SIMULATOR_ALIAS}'"
