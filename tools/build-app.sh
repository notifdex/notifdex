#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${NOTIFDEX_UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --arch arm64 --arch x86_64 --product Notifdex
    notifdex_bin_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c release --product Notifdex
    notifdex_bin_dir="$(swift build -c release --show-bin-path)"
fi
notifdex_app_dir="$PWD/dist/Notifdex.app"
rm -rf "$notifdex_app_dir"
mkdir -p "$notifdex_app_dir/Contents/MacOS" "$notifdex_app_dir/Contents/Resources"
install -m 755 "$notifdex_bin_dir/Notifdex" "$notifdex_app_dir/Contents/MacOS/Notifdex"
cp Sources/NotifdexCore/schema.sql "$notifdex_app_dir/Contents/Resources/schema.sql"
cat > "$notifdex_app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Notifdex</string>
    <key>CFBundleDisplayName</key><string>Notifdex</string>
    <key>CFBundleIdentifier</key><string>com.notifdex.mac</string>
    <key>CFBundleExecutable</key><string>Notifdex</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.notifdex.mac "$notifdex_app_dir"
codesign --verify --deep --strict "$notifdex_app_dir"
"$notifdex_app_dir/Contents/MacOS/Notifdex" --self-check
echo "Built $notifdex_app_dir"
