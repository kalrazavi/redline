#!/bin/zsh
# Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
# Rebuilds Redline.app from src/main.swift and installs it in /Applications. The Touch Bar part (Glowstrip) is built here too and lives inside Redline.app.
set -e
cd "$(dirname "$0")"
# Signing: with the owner's own local certificate ("Ali Razavi Local Code Signing", in the login keychain, made on this Mac),
# macOS recognises a rebuilt Redline and Touch Bar part as the same apps, so the Accessibility and sound permissions stay on.
# Without it (another Mac) the apps are signed ad hoc, and every rebuild counts as a new app for those permissions.
SIGN="-"; security find-identity -p codesigning 2>/dev/null | grep -q "Ali Razavi Local Code Signing" && SIGN="Ali Razavi Local Code Signing"
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
echo "The helper can do only this: run both fans at their rated maximum or hand them back to macOS, and switch macOS Low Power Mode on or off (ECO)."
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
# The Touch Bar part (Glowstrip, src/touchbar.swift) travels inside Redline.app and is started and stopped by Redline.
# It is rebuilt only when its source changed: macOS treats every rebuilt copy as a new app, and the Accessibility switch
# for its Esc key then has to be turned off and on again. If it cannot be built on this Mac, Redline is installed without it.
G="build/Glowstrip.app"; GB="$G/Contents/MacOS/Glowstrip"
if [ ! -x "$GB" ] || [ src/touchbar.swift -nt "$GB" ] || [ src/touchbar-bridge.h -nt "$GB" ]; then
  if swiftc -swift-version 5 -O -o build/Glowstrip src/touchbar.swift -import-objc-header src/touchbar-bridge.h -F /System/Library/PrivateFrameworks -framework AppKit -framework CoreAudio -framework AudioToolbox -framework QuartzCore -framework ServiceManagement -framework DFRFoundation -framework DisplayServices -framework CoreBrightness -framework MediaRemote -framework login; then
    mkdir -p preview/touchbar; ./build/Glowstrip --render "$PWD/preview/touchbar"
    rm -rf "$G"; mkdir -p "$G/Contents/MacOS"
    cp build/Glowstrip "$GB"
    cat > "$G/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 Ali Razavi. All rights reserved.</string>
<key>NSAudioCaptureUsageDescription</key><string>Glowstrip dims and brightens its glow with the music your Mac is playing. The sound is not recorded or sent anywhere.</string>
<key>CFBundleName</key><string>Glowstrip</string>
<key>CFBundleDisplayName</key><string>Glowstrip</string>
<key>CFBundleIdentifier</key><string>local.glowstrip</string>
<key>CFBundleExecutable</key><string>Glowstrip</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
    codesign --force --sign "$SIGN" "$G"
  else
    echo "The Touch Bar part did not build on this Mac: installing Redline without it."; rm -rf "$G"
  fi
fi
if [ -d "$G" ]; then
  # sign with the local certificate if the copy was made before it existed (harmless otherwise: the identity stays the same)
  codesign -dvv "$G" 2>&1 | grep -q "Authority=$SIGN" || [ "$SIGN" = "-" ] || codesign --force --sign "$SIGN" "$G"
  mkdir -p "$APP/Contents/Helpers"; cp -Rp "$G" "$APP/Contents/Helpers/Glowstrip.app"
fi
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
<key>NSBluetoothAlwaysUsageDescription</key><string>ECO mode switches Bluetooth off to save battery and back on when you leave ECO. Redline also lists your connected Bluetooth devices.</string>
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
codesign --force --sign "$SIGN" "$APP"
pkill -x Redline 2>/dev/null || true
pkill -x Glowstrip 2>/dev/null || true
rm -rf "/Applications/Redline.app"
cp -Rp "$APP" "/Applications/Redline.app"
echo "installed"
