#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"
architecture="$(uname -m)"
output="$root/outputs/CodexCleaner.app"

usage() {
  printf 'Usage: %s [--arch arm64|x86_64] [--output path.app]\n' "$0"
}

while (( $# )); do
  case "$1" in
    --arch)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      architecture="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
 done

case "$architecture" in
  arm64|x86_64) ;;
  *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 2 ;;
esac
case "$output" in
  *.app) ;;
  *) printf 'Output must end with .app\n' >&2; exit 2 ;;
esac

version="$(cat VERSION)"
build_number="$(cat BUILD_NUMBER)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[0-9]+$ ]] || {
  printf 'VERSION or BUILD_NUMBER is invalid\n' >&2
  exit 2
}
output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output="$output_parent/$(basename "$output")"
if [[ -e "$output" || -L "$output" ]]; then
  [[ -d "$output" && ! -L "$output" ]] || { printf 'Output is not a regular app directory: %s\n' "$output" >&2; exit 2; }
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist" 2>/dev/null || true)
  [[ "$bundle_id" == 'local.codex.cleaner' ]] || { printf 'Refusing to overwrite an unrelated app: %s\n' "$output" >&2; exit 2; }
fi

swift build -c release --triple "$architecture-apple-macosx14.0"
bin_dir="$(swift build -c release --triple "$architecture-apple-macosx14.0" --show-bin-path)"
stage_root="$(mktemp -d "$output_parent/.codex-cleaner-build.XXXXXXXX")"
cleanup() {
  if [[ -d "$stage_root/previous.app" && ! -e "$output" ]]; then
    mv "$stage_root/previous.app" "$output"
  fi
  rm -rf "$stage_root"
}
trap cleanup EXIT
app_dir="$stage_root/CodexCleaner.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CodexCleaner" "$app_dir/Contents/MacOS/CodexCleaner"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Codex Cleaner</string>
  <key>CFBundleDisplayName</key><string>Codex Cleaner</string>
  <key>CFBundleIdentifier</key><string>local.codex.cleaner</string>
  <key>CFBundleExecutable</key><string>CodexCleaner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [[ -e "$output" ]]; then
  mv "$output" "$stage_root/previous.app"
fi
mv "$app_dir" "$output"
printf 'Built %s (%s, %s+%s)\n' "$output" "$architecture" "$version" "$build_number"
