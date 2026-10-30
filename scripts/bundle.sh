#!/usr/bin/env bash
# dist/CoaxPlayer.app を作る。libmpv と依存ライブラリを Contents/Frameworks に入れ、
# 参照先を @rpath に書き換えて、Homebrew などが無い Mac でも動くようにする。
# COAX_DIR を指定すると、そこにある coax と coaxd も同梱する。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB=$ROOT/.deps/prefix/lib
APP=$ROOT/dist/CoaxPlayer.app
NAME=CoaxPlayer

cd "$ROOT"
swift build -c release --product "$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"
# 録画の TS から MP4 を作るのに使う
cp "$ROOT/.deps/prefix/bin/ffmpeg" "$APP/Contents/MacOS/ffmpeg"

if [ -n "${COAX_DIR:-}" ]; then
  # coax は同じ場所にある coaxd を起動する
  cp "$COAX_DIR/coax" "$COAX_DIR/coaxd" "$APP/Contents/MacOS/"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>jp.bellx2.coax-swiftui</string>
  <key>CFBundleName</key><string>CoaxPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 参照をたどって、.deps のライブラリを全部 Frameworks に集める
queue=("$APP/Contents/MacOS/$NAME" "$APP/Contents/MacOS/ffmpeg")
while [ ${#queue[@]} -gt 0 ]; do
  file=${queue[0]}
  queue=("${queue[@]:1}")
  for dep in $(otool -L "$file" | awk 'NR>1 {print $1}'); do
    base=$(basename "$dep")
    case "$dep" in
      "$LIB"/* | @rpath/*) ;;
      *) continue ;;
    esac
    [ -f "$LIB/$base" ] || continue
    target=$APP/Contents/Frameworks/$base
    if [ ! -f "$target" ]; then
      cp -L "$LIB/$base" "$target"
      chmod u+w "$target"
      install_name_tool -id "@rpath/$base" "$target"
      queue+=("$target")
    fi
    install_name_tool -change "$dep" "@rpath/$base" "$file" 2>/dev/null
  done
done

# 開発用の .deps への rpath は配布物に要らない
install_name_tool -delete_rpath "$LIB" "$APP/Contents/MacOS/$NAME" 2>/dev/null || true
install_name_tool -delete_rpath "$LIB" "$APP/Contents/MacOS/ffmpeg" 2>/dev/null || true
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/ffmpeg"
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
done

# 書き換えで署名が壊れるので、ライブラリから順に署名し直す（ここではアドホック署名）
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"/Contents/Frameworks/*.dylib
for exe in "$APP"/Contents/MacOS/*; do
  [ "$exe" = "$APP/Contents/MacOS/$NAME" ] || codesign --force --sign "${SIGN_IDENTITY:--}" "$exe"
done
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

# 外部への参照が残っていないことを確かめる（ファイル名の行は除く）
if otool -L "$APP"/Contents/MacOS/$NAME "$APP"/Contents/MacOS/ffmpeg "$APP"/Contents/Frameworks/*.dylib | grep -v ":$" | grep -E "/opt/homebrew|/usr/local|$ROOT"; then
  echo "外部のライブラリへの参照が残っています" >&2
  exit 1
fi
du -sh "$APP"
