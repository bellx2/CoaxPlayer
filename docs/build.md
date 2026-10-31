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

- FFmpeg 9.0.2。MPEG-TS、H.264、MPEG-2 映像、AAC と VideoToolbox のみ。録画の MP4 化のために ffmpeg コマンド、MP4 の書き出し、AAC のエンコーダーも
- libaribcaption 1.1.2（字幕の解読と描画。CoreText で描く）
- libplacebo、libass ほか
- mpv 0.41.0（libmpv のみ、`-Dgpl=false`）

mpv は Cocoa を外すと、音声出力が使う `osdep/utils-mac.c` がコンパイルされず、Foundation もリンクされない（リンクは通るが、その関数を呼んだ時点で落ちる）。
そのため `meson.build` を書き換えて足し、最後に未解決の参照（`nm -m` の `dynamically looked up`）が残っていないことを確かめる。

GPL の部品を含めないので、同梱するライブラリは LGPL などの条件で配布できる（`coaxd` は GPL-2.0-only なので、同梱するときはその条件に従う）。
最低対応 OS は `MACOSX_DEPLOYMENT_TARGET`（既定 13.0）で変えられる。

## bundle.sh

- 参照しているライブラリを `.deps` からたどって `Contents/Frameworks` に集め、参照先を `@rpath` に書き換える
- `COAX_DIR` を渡すと、coax と coaxd を `Contents/MacOS` に入れる（coax は同じ場所の coaxd を起動する）。録画の MP4 化に使う ffmpeg は常に入れる
- 同梱するライブラリと coax のライセンスの全文を `Contents/Resources/licenses/` に入れる
- 既定ではアドホック署名する。`SIGN_IDENTITY` を渡すと、その証明書で署名する（配布には、さらに公証が要る）
- 最後に、外部のライブラリへの参照が残っていないことを確かめる

## coax の版

`coax tune` の `--stats` と `--program` を使う。どちらも fork（[bellx2/coax](https://github.com/bellx2/coax)）のブランチにある機能で、上流の coax にはまだ無い。
`bundle.sh` の `COAX_DIR` には、それを含めてビルドした coax を渡す。
