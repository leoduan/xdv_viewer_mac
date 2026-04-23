#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

product_name="XDVNativeViewer"
bundle_name="${product_name}.app"
release_dir="$repo_root/.build/release"
bundle_dir="$release_dir/$bundle_name"
binary_path="$release_dir/$product_name"
module_cache_dir="$repo_root/.build/module-cache"
plist_template="$repo_root/packaging/Info.plist"

cd "$repo_root"

mkdir -p "$release_dir" "$module_cache_dir"

swiftc \
  -O \
  -module-cache-path "$module_cache_dir" \
  Sources/main.swift \
  -o "$binary_path" \
  -framework AppKit \
  -framework WebKit \
  -framework PDFKit

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir/Contents/MacOS"
cp "$plist_template" "$bundle_dir/Contents/Info.plist"
cp "$binary_path" "$bundle_dir/Contents/MacOS/$product_name"
chmod +x "$bundle_dir/Contents/MacOS/$product_name"

echo "Created release app:"
echo "$bundle_dir"
