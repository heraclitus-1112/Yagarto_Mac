#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

command -v arm-none-eabi-as >/dev/null
command -v arm-none-eabi-ld >/dev/null
command -v arm-none-eabi-objcopy >/dev/null
command -v arm-none-eabi-objdump >/dev/null
command -v arm-none-eabi-gdb >/dev/null
command -v qemu-system-arm >/dev/null

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)

swift test --package-path "$project_root" -c debug \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
  --filter BackendE2ETests/testRequiredQEMUMachinesWhenQEMUIsInstalled

swift test --package-path "$project_root" -c debug \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
  --filter ARM7QEMUFallbackE2ETests
