#!/usr/bin/env bash
set -euo pipefail

# Build the Tether executable and wrap it in a proper .app bundle so that
# LSUIElement (status-bar only) is honored by the macOS launcher.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

config="${1:-release}"
build_path="$here/build"

echo "==> swift build -c $config (--build-path $build_path)"
swift build -c "$config" --build-path "$build_path"

bin_path="$(swift build -c "$config" --build-path "$build_path" --show-bin-path)"
app_dir="$build_path/Tether.app"
contents="$app_dir/Contents"

echo "==> assembling $app_dir"
rm -rf "$app_dir"
mkdir -p "$contents/MacOS" "$contents/Resources"

cp "$bin_path/Tether" "$contents/MacOS/Tether"
cp "$here/Resources/Info.plist" "$contents/Info.plist"

# Copy any non-plist files from Resources/ into the bundle (e.g. AppIcon.icns).
shopt -s nullglob
for f in "$here"/Resources/*; do
  [[ "$(basename "$f")" == "Info.plist" ]] && continue
  cp "$f" "$contents/Resources/"
done
shopt -u nullglob

# Ad-hoc code sign so launchd will trust it locally.
codesign --force --sign - "$app_dir" >/dev/null 2>&1 || true

echo "==> built: $app_dir"
echo "Launch with: open $app_dir"
