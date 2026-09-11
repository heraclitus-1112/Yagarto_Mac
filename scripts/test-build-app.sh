#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=$("$script_directory/build-app.sh" Debug)
test "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1
test -x "$output/Contents/MacOS/YagartoMacApp"
test "$(plutil -extract CFBundleIdentifier raw -o - "$output/Contents/Info.plist")" = "org.yagarto.mac.app"
test -f "$output/Contents/Resources/examples/arm7tdmi/array-addressing/yagarto.json"
test -f "$output/Contents/Resources/examples/arm7tdmi/array-addressing/array-addressing.s"
test ! -e "$output/Contents/Resources/examples/arm7tdmi/array-addressing/.yagarto"
printf '%s\n' "$output"
