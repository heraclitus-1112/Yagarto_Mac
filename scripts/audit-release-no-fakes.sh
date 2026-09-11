#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "$#" -ne 1 ]; then
  echo "用法：scripts/audit-release-no-fakes.sh /path/to/YagartoMacApp.app" >&2
  exit 2
fi

app_path=$1
binary="$app_path/Contents/MacOS/YagartoMacApp"
test -x "$binary"

failed=0
for marker in \
  UITestFixture \
  UITestBuildService \
  UITestDebugService \
  ui-testing-recovery \
  '测试后端启动失败' \
  '确定性 UI 调试后端'
do
  if LC_ALL=C grep -aFq -- "$marker" "$binary"; then
    echo "Release 二进制仍包含 UI fake 标记：$marker" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then exit 1; fi
echo "Release UI fake exclusion: PASS"
