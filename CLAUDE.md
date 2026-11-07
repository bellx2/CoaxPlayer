# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

CoaxPlayer は、coax（USB の ISDB-T チューナーを扱う CLI）で受信した地上デジタル放送を見るための macOS 用プレーヤー（SwiftUI + libmpv）。利用者向けの説明は README.md、詳細は docs/ にある。

- docs/architecture.md: 内部の構成、選局・字幕・局ロゴ・録画・描画の流れ
- docs/build.md: ビルド、`.app` の組み立て、リリースの手順
- docs/usage.md: 画面の操作と起動引数
- docs/decoder.md: 外部デコーダー（フルセグ）のつなぎ方

## コマンド

```sh
./scripts/build-deps.sh                  # libmpv・FFmpeg・libaribcaption を .deps/prefix にビルド（初回のみ。swift build の前に必須）
swift build                              # 開発用ビルド（.deps/prefix のライブラリを読む）
swift run CoaxPlayer --coax ../coax/coax # 起動

# チューナー無しで選局の経路を試す（scripts/fake-coax.sh が FAKE_TS を流し、coax と同じ形の stderr 行を出す）
FAKE_TS=testdata/oneseg-ch27.ts swift run CoaxPlayer --coax "$PWD/scripts/fake-coax.sh" --scan /path/to/scan.json --ch 27

COAX_DIR=../coax ./scripts/bundle.sh     # dist/CoaxPlayer.app を作る（既定はアドホック署名）
```

- テストターゲットとリンターは無い。動作確認は fake-coax.sh か実機で行う。`testdata/`（gitignore 済み）にワンセグ・フルセグ・字幕入りの TS がある
- リリースは `scripts/release.sh`（署名・公証・GitHub Releases・tap の Cask 更新まで一括）。前提条件は docs/build.md を参照

## 構成の要点

- 依存ライブラリは Homebrew のものを使わず、`scripts/build-deps.sh` で `.deps/prefix` に自前ビルドする。`Package.swift` はそこを `-I`/`-L` と rpath で参照し、`.app` では `Contents/Frameworks` から読む。mpv は `-Dgpl=false` で、GPL の部品を同梱しない
- `Sources/CMpv`・`Sources/CAribCaption` は system library target。本体は `Sources/CoaxPlayer` の単一の executable target で、Swift 言語モードは v5
- 再生の流れ: `PlayerModel` が `coax tune --ch N --stats --program` を子プロセス（`CoaxProcess`）で起動し（外部デコーダーがあればその stdin につなぐ）、`StreamTee` が出力を読んで `fdclose://` で mpv に渡す。同じ中継で、録画の書き出し、字幕の PES（`CaptionExtractor`）、局ロゴ（`LogoExtractor`）を取り出す。ファイルの再生はこの中継を通らないため、字幕も局ロゴも出ない
- coax の stderr の行は UI の情報源になる。`now` の行は今の番組、それ以外は受信状態として表示する
- 描画は mpv のソフトウェアレンダラで IOSurface 付き CVPixelBuffer に描き、CALayer の contents にする。字幕は mpv に描かせず（`sid=no`）、libaribcaption で別レイヤーに実ピクセル数で描く
- 設定でチューナーを PIX-DT295 にすると、pix-userland の `pix-ts` の出力を `coax tune --input -` に流す（`PixUserland.swift`、docs/dt295.md）。pixd の起動と終了もアプリが受け持つ
- 使っている `coax tune --stats/--program/--input` とスキャン結果の局ロゴ情報は、fork（bellx2/coax）の `coaxplayer` ブランチにしか無い。上流の coax では動かない

## 関連リポジトリ（../coax と ../libaribb25）

### ../coax（bellx2/coax、Go）

- 上流 Till0196/coax の fork。remote は `origin`（bellx2）と `upstream`（Till0196）。CoaxPlayer 用の変更は `coaxplayer` ブランチに乗せる（`upstream/main..coaxplayer` で差分を確認できる）
- `coax` はクライアント CLI、`coaxd` はチューナーを管理するデーモン（GPL-2.0-only）。`coax` は同じディレクトリの `coaxd` を自動で起動する
- ビルドは `go build -o coax ./cmd/coax && go build -o coaxd ./cmd/coaxd`（`CGO_ENABLED=0` で可）。開発中は `swift run CoaxPlayer --coax ../coax/coax`、`.app` には `COAX_DIR=../coax ./scripts/bundle.sh` で同梱する
- CoaxPlayer が新しく coax の機能を必要とするときは、`coaxplayer` ブランチに足す。上流に追従するときもこのブランチを更新し、リリースごとに `coaxplayer-v<版>` のタグを付ける（`release.sh` が、ブランチ・変更なし・push 済みであることを確かめてからタグを付ける）

### ../libaribb25（bellx2/libaribb25、C/CMake）

- フルセグのスクランブル解除に使う外部デコーダー（`arib-b25-stream-test`）。上流 tsukumijima/libaribb25 の fork で、`macos` ブランチに macOS 向けのビルド手順だけを足している（コードは上流のまま）
- `.app` には同梱しない。利用者が `brew install bellx2/tap/libaribb25` で入れ、アプリは `--decoder` も設定も無いとき `/opt/homebrew/bin/arib-b25-stream-test` を使う
- ビルドは `scripts/build-macos.sh`（cmake・meson・ninja・curl が必要）。pcsc-lite を静的リンクし、接続先のソケットは環境変数 `PCSCLITE_CSOCK_NAME`（アプリが `coax pcsc` のソケットを渡す）で選ぶ。`macos-` で始まるタグを push すると、GitHub Actions がビルド済みアーカイブを Releases に上げる
- PAT の無い TS（ワンセグだけ）では何も出力しないので、ワンセグはデコーダーを通さない

## ブランチとリリースの流れ

- main は公開している版だけを指す。普段の作業は `develop` で行い、機能ごとに `feat/xxx` を develop から切って `git merge --no-ff` で戻す。小さい変更は develop に直接コミットしてよい
- 変更は CHANGELOG.md の `## 未リリース` に追記していく
- リリースすると決めたら、develop で `scripts/bundle.sh` の `VERSION` を上げ、`## 未リリース` を `## <版> - <日付>` に直してコミット・push する。続けて `git switch main && git merge --ff-only develop && git push` し、main で `scripts/release.sh` を実行する（`release.sh` は HEAD が origin/main と同じことを確かめる）
- coax の変更が要るときは、../coax でも `coaxplayer` から作業用ブランチを切る。リリース前に `coaxplayer` へマージして push しておく
- 急ぎの修正は main から `fix/xxx` を切ってリリースし、そのあと main を develop にマージする。その後の develop から main へのマージが早送りにならなければ `--no-ff` にする
- コミット・マージ・push は指示があったときだけ行う

## 文書と版の決まり

- 版は `scripts/bundle.sh` の `VERSION` に置く。上げるときは CHANGELOG.md の `## <版> - <日付>` とそろえる。リリース前の変更は CHANGELOG.md の `## 未リリース` に足す
- README.md はです・ます調、docs/ はだ・である調で書く
- 仕様や起動引数を変えたら、docs/usage.md・docs/architecture.md の該当箇所も直す
