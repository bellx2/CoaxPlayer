#!/usr/bin/env bash
# リリースする。署名と公証をした zip を GitHub Releases に上げ、tap の Cask を更新する。
#
#   SIGN_IDENTITY="Developer ID Application: 名前 (チームID)" COAX_DIR=../coax ./scripts/release.sh
#
# 前もって要るもの:
#   - 公証の認証情報（`xcrun notarytool store-credentials CoaxPlayer`。プロファイル名は NOTARY_PROFILE で変えられる）
#   - CHANGELOG.md の `## <版> - <日付>` の項（bundle.sh の VERSION と同じ版）
#   - main を push 済みで、作業ツリーに変更が無いこと
#   - COAX_DIR の coax が coaxplayer ブランチで、bellx2/coax に push 済みであること
#     （coaxd は GPL なので、同梱した版に coaxplayer-v<版> のタグを付けてソースを示す）
#   - tap（bellx2/homebrew-tap）を `brew tap bellx2/tap` で入れてあること
# 出力: dist/CoaxPlayer_<版>_macos-arm64.zip とその .sha256、dist/coaxplayer.rb
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${SIGN_IDENTITY:?Developer ID Application の証明書の名前を SIGN_IDENTITY に入れてください}"
: "${COAX_DIR:?同梱する coax のディレクトリを COAX_DIR に入れてください}"
COAX_DIR=$(cd "$COAX_DIR" && pwd)
NOTARY_PROFILE=${NOTARY_PROFILE:-CoaxPlayer}
VERSION=$(sed -n 's/^VERSION=//p' "$ROOT/scripts/bundle.sh")
TAG=v$VERSION
COAX_TAG=coaxplayer-v$VERSION
APP=$ROOT/dist/CoaxPlayer.app
ZIP=$ROOT/dist/CoaxPlayer_${VERSION}_macos-arm64.zip
CASK=$ROOT/dist/coaxplayer.rb
TAP=$(brew --repository bellx2/tap)

fail() {
  echo "$1" >&2
  exit 1
}

# 公証は数分かかるので、公開できない状態なら先に止める
heading=$(grep "^## $VERSION " "$ROOT/CHANGELOG.md" || true)
[ -n "$heading" ] || fail "CHANGELOG.md に $VERSION の項がありません"
case $heading in *未リリース*) fail "CHANGELOG.md の $VERSION の項に日付を入れてください" ;; esac
[ -z "$(git -C "$ROOT" status --porcelain)" ] || fail "作業ツリーに変更があります"
git -C "$ROOT" fetch -q origin
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] || fail "HEAD が origin/main と違います（push してください）"
! git -C "$ROOT" ls-remote --exit-code --tags origin "$TAG" >/dev/null || fail "$TAG はもうあります"
[ -z "$(git -C "$COAX_DIR" status --porcelain --untracked-files=no)" ] || fail "COAX_DIR に変更があります"
[ "$(git -C "$COAX_DIR" branch --show-current)" = coaxplayer ] || fail "COAX_DIR が coaxplayer ブランチではありません"
COAX_COMMIT=$(git -C "$COAX_DIR" rev-parse HEAD)
git -C "$COAX_DIR" fetch -q origin
[ "$COAX_COMMIT" = "$(git -C "$COAX_DIR" rev-parse origin/coaxplayer)" ] || fail "COAX_DIR の HEAD が bellx2/coax の coaxplayer と違います（push してください）"
! git -C "$COAX_DIR" ls-remote --exit-code --tags origin "$COAX_TAG" >/dev/null || fail "bellx2/coax に $COAX_TAG はもうあります"
[ -d "$TAP/Casks" ] || fail "tap がありません（brew tap bellx2/tap）"
[ -z "$(git -C "$TAP" status --porcelain)" ] || fail "tap に変更があります"

# 同梱する coax は、示すソースと同じものにするため、ここでビルドする
(cd "$COAX_DIR" && go build -o coax ./cmd/coax && go build -o coaxd ./cmd/coaxd)
COAX_VERSION=$("$COAX_DIR/coax" version)

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

cat > "$CASK" <<EOF
cask "coaxplayer" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/bellx2/CoaxPlayer/releases/download/v#{version}/CoaxPlayer_#{version}_macos-arm64.zip"
  name "CoaxPlayer"
  desc "Player for terrestrial digital TV received with coax"
  homepage "https://github.com/bellx2/CoaxPlayer"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "CoaxPlayer.app"

  zap trash: [
    "~/Library/Application Support/CoaxPlayer",
    "~/Library/Preferences/jp.bellx2.CoaxPlayer.plist",
  ]
end
EOF

# リリースノートは CHANGELOG.md の項と、同梱した coax のソースの在りか
NOTES=$ROOT/dist/release-notes.md
{
  awk -v v="$VERSION" '$0 ~ "^## " v " " {f=1; next} /^## / {f=0} f' "$ROOT/CHANGELOG.md"
  echo
  echo "同梱の coax: ${COAX_VERSION}（ソース: https://github.com/bellx2/coax/tree/${COAX_TAG}）"
} > "$NOTES"

echo
echo "公開するもの:"
echo "  GitHub Releases: bellx2/CoaxPlayer ${TAG}（$(basename "$ZIP")）"
echo "  coax のタグ: bellx2/coax ${COAX_TAG}（${COAX_COMMIT}）"
echo "  Cask: $TAP/Casks/coaxplayer.rb"
read -r -p "公開しますか [y/N] " answer
[ "$answer" = y ] || fail "公開を中止しました（作ったものは dist/ に残っています）"

git -C "$COAX_DIR" tag -a "$COAX_TAG" -m "CoaxPlayer $VERSION に同梱した coax" "$COAX_COMMIT"
git -C "$COAX_DIR" push -q origin "$COAX_TAG"

gh release create "$TAG" "$ZIP" "$ZIP.sha256" -R bellx2/CoaxPlayer \
  --target "$(git -C "$ROOT" rev-parse HEAD)" --title "CoaxPlayer $VERSION" --notes-file "$NOTES"

# 初めて置くときと、版を上げるときでコミットの説明を分ける
if [ -e "$TAP/Casks/coaxplayer.rb" ]; then
  message="chore: CoaxPlayer $VERSION の Cask 更新"
else
  message="feat: CoaxPlayer $VERSION の Cask 追加"
fi
cp "$CASK" "$TAP/Casks/coaxplayer.rb"
git -C "$TAP" add Casks/coaxplayer.rb
git -C "$TAP" commit -q -m "$message"
git -C "$TAP" push -q

echo "公開しました: brew install --cask bellx2/tap/coaxplayer"
