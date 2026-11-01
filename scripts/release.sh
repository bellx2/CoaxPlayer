#!/usr/bin/env bash
# 配布用の zip と Homebrew の Cask を作る。
# Developer ID で署名した .app を公証に出し、通ったら公証の結果を .app に付けて zip にする。
#
#   SIGN_IDENTITY="Developer ID Application: 名前 (チームID)" COAX_DIR=../coax ./scripts/release.sh
#
# 公証の認証情報は、先に `xcrun notarytool store-credentials CoaxPlayer` でキーチェーンに入れておく
# （プロファイル名は NOTARY_PROFILE で変えられる）。
# 出力: dist/CoaxPlayer_<版>_macos-arm64.zip とその .sha256、dist/coaxplayer.rb（tap の Casks/ に置く）
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${SIGN_IDENTITY:?Developer ID Application の証明書の名前を SIGN_IDENTITY に入れてください}"
: "${COAX_DIR:?同梱する coax のディレクトリを COAX_DIR に入れてください}"
NOTARY_PROFILE=${NOTARY_PROFILE:-CoaxPlayer}
VERSION=$(sed -n 's/^VERSION=//p' "$ROOT/scripts/bundle.sh")
APP=$ROOT/dist/CoaxPlayer.app
ZIP=$ROOT/dist/CoaxPlayer_${VERSION}_macos-arm64.zip

# 版が CHANGELOG.md にあるかを先に確かめる（リリースノートの書き忘れを防ぐ）
grep -q "^## $VERSION" "$ROOT/CHANGELOG.md" || { echo "CHANGELOG.md に $VERSION の項がありません" >&2; exit 1; }

SIGN_IDENTITY=$SIGN_IDENTITY COAX_DIR=$COAX_DIR "$ROOT/scripts/bundle.sh"
codesign --verify --deep --strict --verbose=2 "$APP"

# 公証には zip で出す。通ったら .app に結果を付け、付けた .app で zip を作り直す
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "$SHA256  $(basename "$ZIP")" > "$ZIP.sha256"

cat > "$ROOT/dist/coaxplayer.rb" <<CASK
cask "coaxplayer" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/bellx2/CoaxPlayer/releases/download/v#{version}/CoaxPlayer_#{version}_macos-arm64.zip"
  name "CoaxPlayer"
  desc "Player for terrestrial digital TV received with coax"
  homepage "https://github.com/bellx2/CoaxPlayer"

  depends_on arch: :arm64
  depends_on macos: ">= :ventura"

  app "CoaxPlayer.app"

  zap trash: [
    "~/Library/Application Support/CoaxPlayer",
    "~/Library/Preferences/jp.bellx2.CoaxPlayer.plist",
  ]
end
CASK

echo "$ZIP"
echo "$ROOT/dist/coaxplayer.rb"
