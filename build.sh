#!/bin/zsh
# Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
# Rebuilds Redline.app from src/main.swift and installs it in /Applications.
set -e
cd "$(dirname "$0")"
mkdir -p build preview
swiftc -swift-version 5 -O -o build/Redline src/main.swift -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement -framework CoreWLAN -framework CoreAudio -framework AudioToolbox -framework Accelerate
./build/Redline --render "$PWD/preview"
APP="build/Redline.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Redline "$APP/Contents/MacOS/Redline"
# The fan helper and its one-time set-up script travel inside the app. Nothing here has administrator rights until the owner runs the set-up.
clang -O2 -Wall -o build/redline-fan src/fan.c -framework IOKit -framework CoreFoundation
cp build/redline-fan "$APP/Contents/Resources/redline-fan"
cat > "$APP/Contents/Resources/Enable fan control.command" <<'F'
#!/bin/zsh
# Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor.
H="$(dirname "$0")/redline-fan"
echo "Redline fan control"
echo "This copies one small helper to /Library/Application Support/Redline and lets it act for the system."
echo "The helper can do two things only: run both fans at their rated maximum, or hand them back to macOS."
echo "macOS will now ask for your Mac password (it is not shown while you type)."
sudo mkdir -p "/Library/Application Support/Redline" && sudo install -o root -g wheel -m 4755 "$H" "/Library/Application Support/Redline/redline-fan" \
  && echo "Done. The FANS switch in Redline now works. You can close this window." || echo "Not installed."
F
chmod +x "$APP/Contents/Resources/Enable fan control.command"
cat > "$APP/Contents/Resources/Remove fan control.command" <<'F'
#!/bin/zsh
"/Library/Application Support/Redline/redline-fan" auto 2>/dev/null
sudo rm -rf "/Library/Application Support/Redline" && echo "Fan helper removed. The fans are back with macOS."
F
chmod +x "$APP/Contents/Resources/Remove fan control.command"
rm -rf build/icon.iconset; mkdir build/icon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s preview/icon_1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) preview/icon_1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 Ali Razavi. All rights reserved.</string>
<key>NSAudioCaptureUsageDescription</key><string>Redline moves its backdrop with the music your Mac is playing. The sound is not recorded or sent anywhere.</string>
<key>CFBundleName</key><string>Redline</string>
<key>CFBundleDisplayName</key><string>Redline</string>
<key>CFBundleIdentifier</key><string>local.redline</string>
<key>CFBundleExecutable</key><string>Redline</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
codesign --force --sign - "$APP"
pkill -x Redline 2>/dev/null || true
rm -rf "/Applications/Redline.app"
cp -R "$APP" "/Applications/Redline.app"
echo "installed"
