# ビルド

## 必要なもの

- Swift 6（Xcode のコマンドラインツール）
- [uv](https://docs.astral.sh/uv/)（meson と ninja をビルド用の venv に入れるのに使う）と `pkg-config`
- `coax`（`.app` に同梱するときは、ビルド済みのディレクトリを `COAX_DIR` で渡す）

## 手順

```sh
./scripts/build-deps.sh                          # libmpv と依存ライブラリを .deps/prefix に作る（初回のみ）
swift build                                      # 開発用（.deps のライブラリを読む）
COAX_DIR=../coax ./scripts/bundle.sh             # dist/CoaxPlayer.app を作る
```

開発中は `swift run` で起動できる。

```sh
swift run CoaxPlayer --coax ../coax/coax

# チューナーを使わずに選局の経路を試す（coax の代わりに TS を流すスクリプト）
FAKE_TS=/path/to/file.ts swift run CoaxPlayer --coax "$PWD/scripts/fake-coax.sh" --scan /path/to/scan.json --ch 27
```

`scripts/fake-coax.sh` は、`FAKE_TS` のファイルを流し、coax と同じ形の受信状態と番組の行も出す。

## build-deps.sh

次のものを、公式の配布元から取得して SHA-256 を照合し、`.deps/prefix` にビルドする。Homebrew のものは使わない。

- FFmpeg 9.0.2。MPEG-TS、H.264、MPEG-2 映像、AAC と VideoToolbox のみ。録画の変換のために ffmpeg コマンド、MP4 の書き出し、AAC のエンコーダーも。一覧のプレビューのために rawvideo の書き出しも
- libaribcaption 1.1.2（字幕の解読と描画。CoreText で描く）
- libplacebo、libass ほか
- mpv 0.41.0（libmpv のみ、`-Dgpl=false`）

mpv は Cocoa を外すと、音声出力が使う `osdep/utils-mac.c` がコンパイルされず、Foundation もリンクされない（リンクは通るが、その関数を呼んだ時点で落ちる）。
そのため `meson.build` を書き換えて足し、最後に未解決の参照（`nm -m` の `dynamically looked up`）が残っていないことを確かめる。

GPL の部品を含めないので、同梱するライブラリは LGPL などの条件で配布できる（`coaxd` は GPL-2.0-only なので、同梱するときはその条件に従う）。
最低対応 OS は `MACOSX_DEPLOYMENT_TARGET`（既定 13.0）で変えられる。

## bundle.sh

- 参照しているライブラリを `.deps` からたどって `Contents/Frameworks` に集め、参照先を `@rpath` に書き換える
- `COAX_DIR` を渡すと、coax と coaxd を `Contents/MacOS` に入れる（coax は同じ場所の coaxd を起動する）。録画の変換と一覧のプレビューに使う ffmpeg は常に入れる
- 同梱するライブラリと coax のライセンスの全文を `Contents/Resources/licenses/` に入れる
- アイコン `Resources/AppIcon.icns` を入れる。アイコンは `swift scripts/make-icon.swift` で描き直せる（CoreGraphics で描き、`sips` と `iconutil` で .icns にする）
- 既定ではアドホック署名する。`SIGN_IDENTITY` を渡すと、その証明書で hardened runtime とタイムスタンプ付きで署名する（配布には、さらに公証が要る）
- アプリの版は `bundle.sh` の `VERSION` に置く。変えるときは `CHANGELOG.md` もそろえる
- 最後に、外部のライブラリへの参照が残っていないことを確かめる

## coax の版

`coax tune` の `--stats` と `--program`、スキャン結果の局ロゴの情報を使う。どれも fork（[bellx2/coax](https://github.com/bellx2/coax)）の `coaxplayer` ブランチにある機能で、上流の coax にはまだ無い。
`coaxplayer` ブランチは、上流の main にこれらの変更を乗せたもの。上流に追従するときもこのブランチを更新し、リリースごとに `coaxplayer-v<版>` のタグを付ける。
`bundle.sh` の `COAX_DIR` には、このブランチでビルドした coax を渡す。

## リリース（release.sh）

署名と公証をした zip を GitHub Releases に上げ、tap の Cask を更新するところまでを 1 回で行う。Developer ID Application の証明書と、公証の認証情報が要る。

```sh
# 公証の認証情報をキーチェーンに入れる（初回のみ。Apple ID とアプリ用パスワード、または API キー）
xcrun notarytool store-credentials CoaxPlayer

SIGN_IDENTITY="Developer ID Application: 名前 (チームID)" COAX_DIR=../coax ./scripts/release.sh
```

1. 公開できる状態かを先に確かめる
   - `CHANGELOG.md` に `## <版> - <日付>` の項がある（`未リリース` のままなら止める）
   - 作業ツリーに変更が無く、main を push 済みで、`v<版>` のタグがまだ無い
   - `COAX_DIR` の coax が `coaxplayer` ブランチで、変更が無く、bellx2/coax に push 済み
   - tap（`brew tap bellx2/tap`）に変更が無い
2. `COAX_DIR` で coax と coaxd をビルドし、`bundle.sh` で署名した `.app` を作る
3. zip にして公証に出し（`notarytool submit --wait`）、通ったら公証の結果を `.app` に付けて（`stapler staple`）zip を作り直す
4. `dist/` に zip、その `.sha256`、Cask（`coaxplayer.rb`）、リリースノートを作る。リリースノートは `CHANGELOG.md` の項と、同梱した coax のソースへのリンク（coaxd は GPL-2.0-only のため）
5. 確認のあと、bellx2/coax に `coaxplayer-v<版>` のタグを付けて push し、GitHub Releases に `v<版>` を作って zip を上げ、tap の `Casks/coaxplayer.rb` を更新してコミット・push する

版を上げるときは、`bundle.sh` の `VERSION` と `CHANGELOG.md` の項をそろえる。
