#!/bin/zsh
# Builds "Alternative Clip.app" (universal: Apple silicon + Intel) into build/.
#   scripts/build_app.sh            build only
#   scripts/build_app.sh --install  also copy it to ~/Applications
#   scripts/build_app.sh --zip      also make build/AlternativeClip.zip for a release
set -e
cd "$(dirname "$0")/.."
# Prefer the full Xcode toolchain when it's installed (some Command Line Tools installs can't run `swift build`).
if [[ -z "$DEVELOPER_DIR" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AlternativeClip

APP="build/Alternative Clip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AlternativeClip"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R Support/en.lproj Support/ja.lproj "$APP/Contents/Resources/"

ICONSET=build/AppIcon.iconset
rm -rf $ICONSET; mkdir -p $ICONSET
swift Support/make_icon.swift $ICONSET
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"   # ad-hoc signature (no Apple Developer ID)
echo "built: $APP"

for arg in "$@"; do
  case $arg in
    --install)
      mkdir -p ~/Applications
      rm -rf ~/Applications/"Alternative Clip.app"
      cp -R "$APP" ~/Applications/
      echo "installed: ~/Applications/Alternative Clip.app" ;;
    --zip)
      rm -f build/AlternativeClip.zip
      ditto -c -k --keepParent "$APP" build/AlternativeClip.zip
      echo "zipped: build/AlternativeClip.zip" ;;
  esac
done
