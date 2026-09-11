#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

[ -d "$YAGARTO_TEST_LOCK_DIR" ] || {
    printf '%s\n' 'marker read occurred without the installer lock' >&2
    exit 91
}
: >"$YAGARTO_TEST_READY_FILE"
while [ ! -e "$YAGARTO_TEST_RELEASE_FILE" ]; do
    sleep 0.05
done
exec "$YAGARTO_TEST_REAL_GREP" "$@"
