#!/bin/zsh
set -eu

project_dir="${0:A:h:h}"
timestamp="$(date +%Y%m%d-%H%M%S)"
app_path="$project_dir/dist/ProxyApps-$timestamp.app"
contents_path="$app_path/Contents"
export CLANG_MODULE_CACHE_PATH="/tmp/localproxy-clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/localproxy-swiftpm-module-cache"

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"

swift build \
  --package-path "$project_dir" \
  --disable-sandbox \
  -c release \
  --product LocalProxyApp

cp "$project_dir/.build/release/LocalProxyApp" "$contents_path/MacOS/LocalProxy"
cp "$project_dir/Resources/LocalProxy-Info.plist" "$contents_path/Info.plist"
chmod 755 "$contents_path/MacOS/LocalProxy"

codesign --force --sign - --timestamp=none "$app_path"

echo "$app_path"
