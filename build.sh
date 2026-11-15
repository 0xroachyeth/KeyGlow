#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) KeyGlow.app, installs it to ~/Applications,
# and makes dist/KeyGlow.zip for sharing.
set -e
cd "$(dirname "$0")"
VERSION=${VERSION:-1.0}
APP=build/KeyGlow.app
rm -rf build dist && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources dist
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos13.0 KeyGlow.swift -o build/KeyGlow-$arch
done
lipo -create build/KeyGlow-arm64 build/KeyGlow-x86_64 -output $APP/Contents/MacOS/KeyGlow
cp assets/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>KeyGlow</string>
<key>CFBundleDisplayName</key><string>KeyGlow</string>
<key>CFBundleIdentifier</key><string>io.github.0xroachyeth.keyglow</string>
<key>CFBundleExecutable</key><string>KeyGlow</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>KeyGlow measures how loud your Mac's audio is so the Music effect can pulse to the beat. Nothing is recorded.</string>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>KeyGlow</string>
  <key>CFBundleURLSchemes</key><array><string>keyglow</string></array>
</dict></array>
<key>NSMicrophoneUsageDescription</key><string>KeyGlow listens to sound so the Music effect can pulse your keyboard backlight.</string>
</dict></plist>
PLIST
codesign --force --sign - $APP
ditto -c -k --keepParent $APP dist/KeyGlow.zip
pkill -x KeyGlow 2>/dev/null || true
rm -rf ~/Applications/KeyGlow.app && cp -R $APP ~/Applications/
echo "Installed ~/Applications/KeyGlow.app and built dist/KeyGlow.zip"
