#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)

if [ -n "${EMACS:-}" ]; then
    EMACS_BIN=$EMACS
elif [ -x /Applications/Emacs.app/Contents/MacOS/Emacs ]; then
    EMACS_BIN=/Applications/Emacs.app/Contents/MacOS/Emacs
elif command -v emacs >/dev/null 2>&1; then
    EMACS_BIN=$(command -v emacs)
else
    printf '%s\n' '错误：找不到 Emacs；请设置 EMACS=/path/to/emacs。' >&2
    exit 1
fi

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/yagarto-emacs-tests.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

cp "$REPOSITORY_ROOT/emacs/yagarto-mac-mode.el" "$TEMP_ROOT/yagarto-mac-mode.el"
"$EMACS_BIN" --batch -Q -L "$TEMP_ROOT" \
    --eval '(setq byte-compile-error-on-warn t)' \
    -f batch-byte-compile "$TEMP_ROOT/yagarto-mac-mode.el"

"$EMACS_BIN" --batch -Q \
    -L "$REPOSITORY_ROOT/emacs" \
    -L "$REPOSITORY_ROOT/emacs/tests" \
    -l yagarto-mac-mode-tests.el \
    -f ert-run-tests-batch-and-exit
