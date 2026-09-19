#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

usage() {
  echo "用法：scripts/build-app.sh [Debug|Release]" >&2
}

configuration="${1:-Debug}"
case "$configuration" in
  Debug) swift_configuration="debug" ;;
  Release) swift_configuration="release" ;;
  *) usage; exit 2 ;;
esac

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
dist_directory="$project_root/dist/$configuration"
derived_data="$project_root/DerivedData/YagartoMacApp-$configuration"
app_path="$dist_directory/YagartoMacApp.app"
build_log="$derived_data/xcodebuild.log"
expected_marketing_version=$(plutil -extract CFBundleShortVersionString raw -o - "$project_root/App/Info.plist")
expected_build_version=$(plutil -extract CFBundleVersion raw -o - "$project_root/App/Info.plist")
mkdir -p "$dist_directory" "$derived_data"

xcode_status=0
xcodebuild \
  -project "$project_root/YagartoMacApp.xcodeproj" \
  -scheme YagartoMacApp \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build >"$build_log" 2>&1 || xcode_status=$?

if [ "$xcode_status" -eq 0 ]; then
  built_app="$derived_data/Build/Products/$configuration/YagartoMacApp.app"
  test -x "$built_app/Contents/MacOS/YagartoMacApp"
  rm -rf -- "$app_path"
  ditto "$built_app" "$app_path"
elif grep -Eq 'required plug-in failed to load|xcodebuild failed to load a required plug-in|DVTPlugInLoading' "$build_log"; then
  echo "警告：本机 Xcode 插件无法加载，改用 SwiftPM 生成无 Developer ID 签名的等价 .app；详情：$build_log" >&2
  swift build --package-path "$project_root" -c "$swift_configuration" --product YagartoMacApp \
    -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
    -Xswiftc -gnone >&2
  binary_directory=$(swift build --package-path "$project_root" -c "$swift_configuration" --show-bin-path)
  staging_directory=$(mktemp -d "$dist_directory/.YagartoMacApp.XXXXXX")
  trap 'rm -rf -- "$staging_directory"' EXIT HUP INT TERM
  staging_app="$staging_directory/YagartoMacApp.app"
  mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
  cp "$project_root/App/Info.plist" "$staging_app/Contents/Info.plist"
  cp "$binary_directory/YagartoMacApp" "$staging_app/Contents/MacOS/YagartoMacApp"
  resource_bundle="$binary_directory/YagartoMac_YagartoCore.bundle"
  if [ -d "$resource_bundle" ]; then
    ditto "$resource_bundle" "$staging_app/Contents/Resources/YagartoMac_YagartoCore.bundle"
  fi
  bundled_example="$staging_app/Contents/Resources/examples/arm7tdmi/array-addressing"
  mkdir -p "$bundled_example"
  cp "$project_root/examples/arm7tdmi/array-addressing/array-addressing.s" "$bundled_example/array-addressing.s"
  cp "$project_root/examples/arm7tdmi/array-addressing/numbers.s" "$bundled_example/numbers.s"
  cp "$project_root/examples/arm7tdmi/array-addressing/yagarto.json" "$bundled_example/yagarto.json"
  cp "$project_root/examples/arm7tdmi/array-addressing/README.md" "$bundled_example/README.md"
  chmod 0755 "$staging_app/Contents/MacOS/YagartoMacApp"
  rm -rf -- "$app_path"
  mv "$staging_app" "$app_path"
  trap - EXIT HUP INT TERM
  rm -rf -- "$staging_directory"
else
  cat "$build_log" >&2
  echo "Xcode 应用构建失败（状态 $xcode_status）。" >&2
  exit "$xcode_status"
fi

embedded_resource_bundle="$app_path/Contents/Resources/YagartoMac_YagartoCore.bundle"
root_resource_bundle="$app_path/YagartoMac_YagartoCore.bundle"
if [ -d "$embedded_resource_bundle" ]; then
  rm -rf -- "$root_resource_bundle"
  ditto "$embedded_resource_bundle" "$root_resource_bundle"
fi

plutil -lint "$app_path/Contents/Info.plist" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")" = "org.yagarto.mac.app"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")" = "$expected_marketing_version"
test "$(plutil -extract CFBundleVersion raw -o - "$app_path/Contents/Info.plist")" = "$expected_build_version"
test -x "$app_path/Contents/MacOS/YagartoMacApp"
if [ -f "$root_resource_bundle/arm7tdmi.ld" ]; then
  :
else
  test -f "$root_resource_bundle/Contents/Resources/arm7tdmi.ld"
fi
test -f "$app_path/Contents/Resources/examples/arm7tdmi/array-addressing/yagarto.json"
test -f "$app_path/Contents/Resources/examples/arm7tdmi/array-addressing/numbers.s"
echo "$app_path"
