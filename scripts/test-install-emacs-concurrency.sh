#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
INSTALLER=$SCRIPT_DIR/install-emacs.sh
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/yagarto-install-lock-tests.XXXXXX")
BACKGROUND_PIDS=

cleanup() {
    for cleanup_pid in $BACKGROUND_PIDS; do
        kill "$cleanup_pid" 2>/dev/null || true
        wait "$cleanup_pid" 2>/dev/null || true
    done
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

wait_for_path() {
    wait_path=$1
    wait_count=0
    while [ ! -e "$wait_path" ]; do
        wait_count=$((wait_count + 1))
        [ "$wait_count" -lt 100 ] || fail "等待路径超时：$wait_path"
        sleep 0.05
    done
}

wait_for_absence() {
    wait_path=$1
    wait_count=0
    while [ -e "$wait_path" ]; do
        wait_count=$((wait_count + 1))
        [ "$wait_count" -lt 100 ] || fail "等待路径删除超时：$wait_path"
        sleep 0.05
    done
}

assert_single_block() {
    block_file=$1
    [ "$(grep -F -c ';; YAGARTO Mac integration BEGIN' "$block_file")" -eq 1 ] \
        || fail "并发安装产生重复配置块：$block_file"
    [ "$(grep -F -c ';; YAGARTO Mac integration END' "$block_file")" -eq 1 ] \
        || fail "并发安装产生不完整配置块：$block_file"
}

# The first process pauses on its first marker read.  That read must already be
# protected by the same-directory lock; the second process must wait, then
# re-check the marker and finish idempotently.
SERIAL_DIR=$TEMP_ROOT/'中文 并发目录'
mkdir -p "$SERIAL_DIR/bin"
SERIAL_INIT=$SERIAL_DIR/'我的 init.el'
SERIAL_LOCK=$SERIAL_DIR/.yagarto-mac-init.lock
SERIAL_READY=$SERIAL_DIR/grep-ready
SERIAL_RELEASE=$SERIAL_DIR/grep-release
REAL_GREP=$(command -v grep)
printf '%s\n' ';; existing' >"$SERIAL_INIT"
ln -s "$SCRIPT_DIR/test-fixtures/pausing-grep.sh" "$SERIAL_DIR/bin/grep"
(
    # The lock must stay private even when the caller has an unsafe umask.
    umask 000
    YAGARTO_TEST_LOCK_DIR=$SERIAL_LOCK \
    YAGARTO_TEST_READY_FILE=$SERIAL_READY \
    YAGARTO_TEST_RELEASE_FILE=$SERIAL_RELEASE \
    YAGARTO_TEST_REAL_GREP=$REAL_GREP \
    PATH="$SERIAL_DIR/bin:$PATH" \
        "$INSTALLER" --install --yes --init-file "$SERIAL_INIT" \
        >"$SERIAL_DIR/first.out" 2>"$SERIAL_DIR/first.err"
) &
first_pid=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $first_pid"
wait_for_path "$SERIAL_READY"
[ -d "$SERIAL_LOCK" ] || fail '首次读取标记前未持有 init 锁'
serial_lock_permissions=$(LC_ALL=C ls -ld "$SERIAL_LOCK")
case "$serial_lock_permissions" in
    ?????w????*|????????w?*) fail 'init 锁受调用者不安全 umask 影响' ;;
esac
"$INSTALLER" --install --yes --init-file "$SERIAL_INIT" \
    >"$SERIAL_DIR/second.out" 2>"$SERIAL_DIR/second.err" &
second_pid=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $second_pid"
sleep 0.1
kill -0 "$second_pid" 2>/dev/null \
    || fail '第二个安装进程未等待首个进程释放锁'
: >"$SERIAL_RELEASE"
if ! wait "$first_pid"; then
    fail "首个并发安装失败：$(cat "$SERIAL_DIR/first.err")"
fi
if ! wait "$second_pid"; then
    fail "第二个并发安装失败：$(cat "$SERIAL_DIR/second.err")"
fi
BACKGROUND_PIDS=
assert_single_block "$SERIAL_INIT"
[ ! -e "$SERIAL_LOCK" ] || fail '正常并发安装后遗留 init 锁'

# A small burst exercises repeated wait/re-check behavior rather than only a
# carefully staged pair.
BURST_DIR=$TEMP_ROOT/'高并发 配置'
mkdir -p "$BURST_DIR"
BURST_INIT=$BURST_DIR/'并发 init.el'
BURST_LOCK=$BURST_DIR/.yagarto-mac-init.lock
printf '%s\n' ';; burst existing' >"$BURST_INIT"
burst_pids=
burst_index=1
while [ "$burst_index" -le 8 ]; do
    "$INSTALLER" --install --yes --init-file "$BURST_INIT" \
        >"$BURST_DIR/$burst_index.out" 2>"$BURST_DIR/$burst_index.err" &
    burst_pid=$!
    burst_pids="$burst_pids $burst_pid"
    BACKGROUND_PIDS="$BACKGROUND_PIDS $burst_pid"
    burst_index=$((burst_index + 1))
done
burst_index=1
for burst_pid in $burst_pids; do
    if ! wait "$burst_pid"; then
        fail "高并发安装进程 $burst_index 失败：$(cat "$BURST_DIR/$burst_index.err")"
    fi
    burst_index=$((burst_index + 1))
done
BACKGROUND_PIDS=
assert_single_block "$BURST_INIT"
[ ! -e "$BURST_LOCK" ] || fail '高并发安装后遗留 init 锁'

# An abandoned lock must fail in bounded time with an actionable stale-lock
# diagnostic; it must never be silently stolen.
STALE_DIR=$TEMP_ROOT/'陈旧 锁'
mkdir -p "$STALE_DIR/.yagarto-mac-init.lock"
STALE_INIT=$STALE_DIR/init.el
printf '%s\n' ';; stale untouched' >"$STALE_INIT"
printf '%s\n' '999999:stale-token' \
    >"$STALE_DIR/.yagarto-mac-init.lock/owner"
if YAGARTO_EMACS_INSTALL_LOCK_TIMEOUT_SECONDS=1 \
    "$INSTALLER" --install --yes --init-file "$STALE_INIT" \
    >"$STALE_DIR/out" 2>"$STALE_DIR/err"; then
    fail '陈旧锁存在时安装器不应成功'
fi
grep -Eq '陈旧|超时' "$STALE_DIR/err" \
    || fail '陈旧锁失败未给出明确诊断'
[ "$(cat "$STALE_INIT")" = ';; stale untouched' ] \
    || fail '等待陈旧锁超时时修改了 init 文件'

# A trapped signal must release only the lock owned by the interrupted process.
SIGNAL_DIR=$TEMP_ROOT/'信号 锁释放'
mkdir -p "$SIGNAL_DIR/bin"
SIGNAL_INIT=$SIGNAL_DIR/'信号 init.el'
SIGNAL_LOCK=$SIGNAL_DIR/.yagarto-mac-init.lock
SIGNAL_READY=$SIGNAL_DIR/grep-ready
SIGNAL_RELEASE=$SIGNAL_DIR/grep-release
printf '%s\n' ';; signal existing' >"$SIGNAL_INIT"
ln -s "$SCRIPT_DIR/test-fixtures/pausing-grep.sh" "$SIGNAL_DIR/bin/grep"
YAGARTO_TEST_LOCK_DIR=$SIGNAL_LOCK \
YAGARTO_TEST_READY_FILE=$SIGNAL_READY \
YAGARTO_TEST_RELEASE_FILE=$SIGNAL_RELEASE \
YAGARTO_TEST_REAL_GREP=$REAL_GREP \
PATH="$SIGNAL_DIR/bin:$PATH" \
    "$INSTALLER" --install --yes --init-file "$SIGNAL_INIT" \
    >"$SIGNAL_DIR/out" 2>"$SIGNAL_DIR/err" &
signal_pid=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $signal_pid"
wait_for_path "$SIGNAL_READY"
[ -d "$SIGNAL_LOCK" ] || fail '信号测试未观察到安装器拥有锁'
kill -TERM "$signal_pid"
: >"$SIGNAL_RELEASE"
if wait "$signal_pid"; then
    fail '收到 TERM 的安装器不应报告成功'
fi
BACKGROUND_PIDS=
wait_for_absence "$SIGNAL_LOCK"
[ "$(cat "$SIGNAL_INIT")" = ';; signal existing' ] \
    || fail '信号中断后修改了 init 文件'

# If the owner token is replaced, the old process must not remove a lock that
# now belongs to someone else.
FOREIGN_DIR=$TEMP_ROOT/'owner identity'
mkdir -p "$FOREIGN_DIR/bin"
FOREIGN_INIT=$FOREIGN_DIR/init.el
FOREIGN_LOCK=$FOREIGN_DIR/.yagarto-mac-init.lock
FOREIGN_READY=$FOREIGN_DIR/grep-ready
FOREIGN_RELEASE=$FOREIGN_DIR/grep-release
printf '%s\n' ';; foreign existing' >"$FOREIGN_INIT"
ln -s "$SCRIPT_DIR/test-fixtures/pausing-grep.sh" "$FOREIGN_DIR/bin/grep"
YAGARTO_TEST_LOCK_DIR=$FOREIGN_LOCK \
YAGARTO_TEST_READY_FILE=$FOREIGN_READY \
YAGARTO_TEST_RELEASE_FILE=$FOREIGN_RELEASE \
YAGARTO_TEST_REAL_GREP=$REAL_GREP \
PATH="$FOREIGN_DIR/bin:$PATH" \
    "$INSTALLER" --install --yes --init-file "$FOREIGN_INIT" \
    >"$FOREIGN_DIR/out" 2>"$FOREIGN_DIR/err" &
foreign_pid=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $foreign_pid"
wait_for_path "$FOREIGN_READY"
printf '%s\n' '424242:foreign-token' >"$FOREIGN_LOCK/owner"
kill -TERM "$foreign_pid"
: >"$FOREIGN_RELEASE"
if wait "$foreign_pid"; then
    fail 'owner identity 测试中的 TERM 不应成功'
fi
BACKGROUND_PIDS=
[ -d "$FOREIGN_LOCK" ] || fail '旧进程错误删除了不同 token 的锁'
[ "$(cat "$FOREIGN_LOCK/owner")" = '424242:foreign-token' ] \
    || fail '旧进程篡改了不同 token 的锁 owner'
rm -f "$FOREIGN_LOCK/owner"
rmdir "$FOREIGN_LOCK"

# A write-path failure must also run the ownership-aware EXIT cleanup.
FAIL_DIR=$TEMP_ROOT/'失败 锁释放'
mkdir -p "$FAIL_DIR/bin"
FAIL_INIT=$FAIL_DIR/'失败 init.el'
FAIL_LOCK=$FAIL_DIR/.yagarto-mac-init.lock
FAIL_OBSERVED=$FAIL_DIR/cp-observed-lock
printf '%s\n' ';; failure existing' >"$FAIL_INIT"
ln -s "$SCRIPT_DIR/test-fixtures/failing-cp.sh" "$FAIL_DIR/bin/cp"
if YAGARTO_TEST_LOCK_DIR=$FAIL_LOCK \
    YAGARTO_TEST_OBSERVED_FILE=$FAIL_OBSERVED \
    PATH="$FAIL_DIR/bin:$PATH" \
    "$INSTALLER" --install --yes --init-file "$FAIL_INIT" \
    >"$FAIL_DIR/out" 2>"$FAIL_DIR/err"; then
    fail '复制失败时安装器不应成功'
fi
[ -f "$FAIL_OBSERVED" ] || fail '复制失败测试未观察到安装器持有锁'
[ ! -e "$FAIL_LOCK" ] || fail '复制失败后遗留 init 锁'
[ "$(cat "$FAIL_INIT")" = ';; failure existing' ] \
    || fail '复制失败后修改了原 init 文件'

printf '%s\n' 'install-emacs concurrency shell tests: PASS'
