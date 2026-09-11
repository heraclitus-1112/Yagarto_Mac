#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

GDB_VERSION=17.2
GDB_ARCHIVE="gdb-${GDB_VERSION}.tar.xz"
GDB_URL="https://ftp.gnu.org/gnu/gdb/${GDB_ARCHIVE}"

usage() {
    cat <<EOF
用法：bootstrap-gdb-sim.sh --prefix DIR --sha256 HEX [--archive FILE]

构建并安装带 ARM simulator 的 GNU GDB ${GDB_VERSION}。

必填：
  --prefix DIR     显式安装前缀
  --sha256 HEX     ${GDB_ARCHIVE} 的预期 SHA-256（64 位十六进制）

可选：
  --archive FILE   使用本地 ${GDB_ARCHIVE}，避免下载
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

WORK_DIRECTORY=
cleanup() {
    if [ -n "$WORK_DIRECTORY" ] && [ -d "$WORK_DIRECTORY" ]; then
        rm -rf "$WORK_DIRECTORY"
    fi
}
trap cleanup EXIT HUP INT TERM

verify_archive() {
    archive_to_verify=$1
    if [ ! -f "$archive_to_verify" ]; then
        echo "源码归档不存在：${archive_to_verify}" >&2
        exit 1
    fi
    if command -v shasum >/dev/null 2>&1; then
        ACTUAL_SHA256=$(shasum -a 256 "$archive_to_verify" | awk '{print $1}')
    elif command -v sha256sum >/dev/null 2>&1; then
        ACTUAL_SHA256=$(sha256sum "$archive_to_verify" | awk '{print $1}')
    else
        echo "缺少 SHA-256 校验工具（shasum 或 sha256sum）。" >&2
        exit 1
    fi
    NORMALIZED_EXPECTED=$(printf '%s' "$EXPECTED_SHA256" | tr 'A-F' 'a-f')
    NORMALIZED_ACTUAL=$(printf '%s' "$ACTUAL_SHA256" | tr 'A-F' 'a-f')
    if [ "$NORMALIZED_ACTUAL" != "$NORMALIZED_EXPECTED" ]; then
        echo "SHA-256 校验失败：预期 ${NORMALIZED_EXPECTED}，实际 ${NORMALIZED_ACTUAL}。" >&2
        exit 1
    fi
}

if [ -n "$LOCAL_ARCHIVE" ]; then
    ARCHIVE_PATH=$LOCAL_ARCHIVE
else
    command -v curl >/dev/null 2>&1 || {
        echo "缺少 curl，无法下载固定 GDB 源码归档。" >&2
        exit 1
    }
    WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/yagarto-gdb.XXXXXX")
    ARCHIVE_PATH="${WORK_DIRECTORY}/${GDB_ARCHIVE}"
    echo "下载 ${GDB_URL}"
    curl --fail --location --proto '=https' --tlsv1.2 \
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
if command -v pkg-config >/dev/null 2>&1 \
    && pkg-config --exists gmp \
    && pkg-config --exists mpfr; then
    GDB_CPPFLAGS=$(pkg-config --cflags gmp mpfr)
    GDB_LDFLAGS=$(pkg-config --libs-only-L gmp mpfr)
elif command -v brew >/dev/null 2>&1; then
    GMP_PREFIX=$(brew --prefix gmp 2>/dev/null || true)
    MPFR_PREFIX=$(brew --prefix mpfr 2>/dev/null || true)
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

if [ -z "$WORK_DIRECTORY" ]; then
    WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/yagarto-gdb.XXXXXX")
fi
SOURCE_DIRECTORY="${WORK_DIRECTORY}/gdb-${GDB_VERSION}"
BUILD_DIRECTORY="${WORK_DIRECTORY}/build"
tar -xf "$ARCHIVE_PATH" -C "$WORK_DIRECTORY"
if [ ! -x "${SOURCE_DIRECTORY}/configure" ]; then
    echo "归档内容无效：缺少 gdb-${GDB_VERSION}/configure。" >&2
    exit 1
fi
mkdir -p "$BUILD_DIRECTORY"

echo "配置 GNU GDB ${GDB_VERSION}（target: arm-none-eabi，simulator 保持启用）"
(
    cd "$BUILD_DIRECTORY"
    env CPPFLAGS="$GDB_CPPFLAGS" LDFLAGS="$GDB_LDFLAGS" \
        "${SOURCE_DIRECTORY}/configure" \
        --target=arm-none-eabi \
        --prefix="$INSTALL_PREFIX" \
        --disable-werror
)

JOB_COUNT=$(sysctl -n hw.logicalcpu 2>/dev/null || printf '2')
case "$JOB_COUNT" in
    ''|*[!0-9]*) JOB_COUNT=2 ;;
esac
gmake -C "$BUILD_DIRECTORY" -j "$JOB_COUNT"
gmake -C "$BUILD_DIRECTORY" install

INSTALLED_GDB="${INSTALL_PREFIX}/bin/arm-none-eabi-gdb"
SIMULATOR_ALIAS="${INSTALL_PREFIX}/bin/arm-none-eabi-gdb-sim"
if [ ! -x "$INSTALLED_GDB" ]; then
    echo "安装后未找到 ${INSTALLED_GDB}。" >&2
    exit 1
fi
if ! "$INSTALLED_GDB" -q -nx -batch -ex "target sim" >/dev/null 2>&1; then
    echo "安装后的 GDB 未通过 target sim 能力验证。" >&2
    exit 1
fi
ln -sf "arm-none-eabi-gdb" "$SIMULATOR_ALIAS"

echo "已安装并验证：${SIMULATOR_ALIAS}"
echo "可设置：export YAGARTO_MAC_GDB_SIM='${SIMULATOR_ALIAS}'"
