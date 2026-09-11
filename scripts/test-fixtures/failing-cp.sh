#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

[ -d "$YAGARTO_TEST_LOCK_DIR" ] || {
    printf '%s\n' 'copy occurred without the installer lock' >&2
    exit 91
}
: >"$YAGARTO_TEST_OBSERVED_FILE"
printf '%s\n' 'injected copy failure' >&2
exit 9
