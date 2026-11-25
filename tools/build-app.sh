#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

notifdex_version="${NOTIFDEX_VERSION:-0.1.0}"
notifdex_build_number="${NOTIFDEX_BUILD_NUMBER:-1}"
notifdex_signing_identity="${NOTIFDEX_SIGNING_IDENTITY:-}"
notifdex_expected_team_id="${NOTIFDEX_EXPECTED_TEAM_ID:-}"

if [[ ! "$notifdex_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    echo "Invalid NOTIFDEX_VERSION: $notifdex_version" >&2
    exit 1
fi

if [[ ! "$notifdex_build_number" =~ ^[0-9]+$ ]] || [[ "$notifdex_build_number" == "0" ]]; then
    echo "Invalid NOTIFDEX_BUILD_NUMBER (must be a positive integer): $notifdex_build_number" >&2
    exit 1
fi

if [[ "${NOTIFDEX_UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --arch arm64 --product Notifdex
    notifdex_arm_dir="$(swift build -c release --arch arm64 --show-bin-path)"
    swift build -c release --arch x86_64 --product Notifdex
    notifdex_intel_dir="$(swift build -c release --arch x86_64 --show-bin-path)"
    notifdex_bin_dir="$PWD/.build/notifdex-universal"
    mkdir -p "$notifdex_bin_dir"
    lipo -create "$notifdex_arm_dir/Notifdex" "$notifdex_intel_dir/Notifdex" -output "$notifdex_bin_dir/Notifdex"
else
    swift build -c release --product Notifdex
    notifdex_bin_dir="$(swift build -c release --show-bin-path)"
fi

notifdex_app_dir="$PWD/dist/Notifdex.app"
rm -rf "$notifdex_app_dir"
mkdir -p "$notifdex_app_dir/Contents/MacOS" "$notifdex_app_dir/Contents/Resources"
install -m 755 "$notifdex_bin_dir/Notifdex" "$notifdex_app_dir/Contents/MacOS/Notifdex"
cp Sources/NotifdexCore/*.sql "$notifdex_app_dir/Contents/Resources/"
cp -R templates "$notifdex_app_dir/Contents/Resources/"

if [[ -f Resources/Icons/AppIcon.png ]]; then
    cp Resources/Icons/AppIcon.png "$notifdex_app_dir/Contents/Resources/AppIcon.png"
    notifdex_iconset="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$notifdex_iconset"
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz" Resources/Icons/AppIcon.png --out "$notifdex_iconset/icon_${sz}x${sz}.png" >/dev/null
        sz2=$((sz * 2))
        sips -z "$sz2" "$sz2" Resources/Icons/AppIcon.png --out "$notifdex_iconset/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$notifdex_iconset" -o "$notifdex_app_dir/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$notifdex_iconset")"
fi

cat > "$notifdex_app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Notifdex</string>
    <key>CFBundleDisplayName</key><string>Notifdex</string>
    <key>CFBundleIdentifier</key><string>com.notifdex.mac</string>
    <key>CFBundleExecutable</key><string>Notifdex</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${notifdex_version}</string>
    <key>CFBundleVersion</key><string>${notifdex_build_number}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

if [[ -n "$notifdex_signing_identity" ]]; then
    echo "Signing $notifdex_app_dir with Developer ID identity (hardened runtime + timestamp)"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$notifdex_signing_identity" \
        --identifier com.notifdex.mac \
        "$notifdex_app_dir"
    codesign --verify --deep --strict --verbose=2 "$notifdex_app_dir"

    if [[ -n "$notifdex_expected_team_id" ]]; then
        designated_req="$(codesign -d -r - "$notifdex_app_dir" 2>&1)"
        if ! grep -Fq 'identifier "com.notifdex.mac"' <<<"$designated_req"; then
            echo "Designated requirement missing bundle identifier com.notifdex.mac" >&2
            echo "$designated_req" >&2
            exit 1
        fi
        if ! grep -Fq "subject.OU] = ${notifdex_expected_team_id}" <<<"$designated_req"; then
            echo "Designated requirement missing expected Team ID ${notifdex_expected_team_id}" >&2
            echo "$designated_req" >&2
            exit 1
        fi
    fi
else
    codesign --force --sign - --identifier com.notifdex.mac "$notifdex_app_dir"
    codesign --verify --deep --strict "$notifdex_app_dir"
fi

echo "Checking packaged SQLite resources and replay behavior"
"$notifdex_app_dir/Contents/MacOS/Notifdex" --self-check
echo "Built $notifdex_app_dir (version $notifdex_version, build $notifdex_build_number)"
