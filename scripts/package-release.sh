#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "用法：scripts/package-release.sh vX.Y.Z /path/to/YagartoMacApp.app [output-directory]" >&2
  exit 2
fi

tag=$1
app_path=$2
output_directory=${3:-dist/release-assets}

if ! printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "版本标签必须是 vX.Y.Z：$tag" >&2
  exit 2
fi

version=${tag#v}
plist="$app_path/Contents/Info.plist"
binary="$app_path/Contents/MacOS/YagartoMacApp"
test -d "$app_path"
test -f "$plist"
test -x "$binary"

bundle_version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist")
if [ "$bundle_version" != "$version" ]; then
  echo "标签版本 $version 与 App 版本 $bundle_version 不一致。" >&2
  exit 1
fi

if ! file "$binary" | grep -Fq 'Mach-O 64-bit executable arm64'; then
  echo "Release App 不是 arm64 Mach-O 可执行文件：$binary" >&2
  exit 1
fi

mkdir -p "$output_directory"
archive_name="YagartoMacApp-${version}-macOS-arm64.zip"
archive_path="$output_directory/$archive_name"
checksum_path="$output_directory/SHA256SUMS.txt"

rm -f -- "$archive_path" "$checksum_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
(
  cd "$output_directory"
  shasum -a 256 "$archive_name" > SHA256SUMS.txt
)

printf '%s\n' "$archive_path"
printf '%s\n' "$checksum_path"
