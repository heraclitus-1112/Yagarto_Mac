#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

allow_environment_skip=0
if [ "${1:-}" = "--allow-environment-skip" ]; then
  allow_environment_skip=1
elif [ "$#" -gt 0 ]; then
  echo "用法：scripts/test-app.sh [--allow-environment-skip]" >&2
  exit 2
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
derived_data="$project_root/DerivedData/YagartoMacApp-Tests"
test_log="$derived_data/xcodebuild-test.log"
mkdir -p "$derived_data"

swift test --package-path "$project_root" -c debug \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test --package-path "$project_root" -c release \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

xcode_status=0
xcodebuild \
  -project "$project_root/YagartoMacApp.xcodeproj" \
  -scheme YagartoMacApp \
  -derivedDataPath "$derived_data" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test >"$test_log" 2>&1 || xcode_status=$?

if [ "$xcode_status" -eq 0 ]; then
  echo "XCUITest：PASS"
elif grep -Eq 'required plug-in failed to load|xcodebuild failed to load a required plug-in|DVTPlugInLoading' "$test_log"; then
  echo "XCUITest：ENVIRONMENT BLOCKED（Xcode 必需插件无法加载；未把它计作测试通过）" >&2
  echo "日志：$test_log" >&2
  if [ "$allow_environment_skip" -ne 1 ]; then exit "$xcode_status"; fi
elif grep -Eq 'not authorized|Accessibility|UI testing is not allowed|No active GUI session' "$test_log"; then
  echo "XCUITest：ENVIRONMENT SKIP（当前 GUI/辅助功能会话不允许自动化）" >&2
  echo "日志：$test_log" >&2
  if [ "$allow_environment_skip" -ne 1 ]; then exit "$xcode_status"; fi
else
  cat "$test_log" >&2
  echo "XCUITest：FAIL（状态 $xcode_status）" >&2
  exit "$xcode_status"
fi

"$script_directory/build-app.sh" Debug
