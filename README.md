# coax-player

[coax](https://github.com/bellx2/coax) で受信した地上デジタル放送を見るための、macOS 用のプレーヤー（SwiftUI + libmpv）。

- チャンネルのスキャンと一覧からの選局
- ワンセグ・フルセグの再生
- 選局した TS を、外部のデコーダーに通してから再生する
- ARIB 字幕の表示
- 録画（TS と、主音声だけの MP4）
- 見ているチャンネル（局ロゴ付き）と今の番組を、映像のすぐ下に表示する
- ワンセグの高精細化（ノイズ除去と超解像、macOS 26 以降）

libmpv と依存ライブラリは `.app` に同梱するので、Homebrew などは要らない。

## 動作環境

- Apple Silicon の Mac、macOS 13 以降
- coax が対応する USB 接続の ISDB-T チューナー（動作確認は Sony CECH-ZD1 J）
- `coax`（`.app` に同梱するか、PATH 上に置くか、`--coax` で指定する）。`--stats` と `--program` を持つ版が要る（[docs/build.md](docs/build.md#coax-の版)）

## 使い方

`CoaxPlayer.app` を起動する。

1. 設定画面（⌘,）の「チャンネルスキャン」で範囲（地上 UHF 13〜52、ケーブル）を選び、「スキャン開始」を押す。結果は `~/Library/Application Support/coax-player/scan.json` に保存され、左にチャンネル一覧が出る
2. 一覧のチャンネルを押すと選局して再生する

再生中は、映像のすぐ下にチャンネル（局ロゴと局名）と今の番組（放送時間と番組名）を出す。局ロゴは放送で数分おきに送られてくるので、初めて見るチャンネルではしばらく出ない。一度受け取ったものは `~/Library/Application Support/coax-player/logos/` に保存し、次からはすぐ出す。

左のボタン:

| ボタン | 動作 |
| --- | --- |
| 停止 | 再生を止める |
| 録画 / 録画停止 | 再生中の番組を `~/Movies/coax/` に録画する。止めると、同じ名前の主音声だけの MP4 も作る |
| 字幕 | 字幕の表示を切り替える（既定は表示） |
| ワンセグ | フルセグを見られるときも、ワンセグにする |

字幕・ワンセグの設定は、チャンネルを替えても保つ。
一覧を作り直すときも、設定画面からスキャンし直す。途中で中止したときは、次は続きから調べる。

### 起動引数

```sh
# 起動と同時に 27ch を再生する
CoaxPlayer --ch 27

# 外部のデコーダーを指定する
CoaxPlayer --decoder /path/to/decoder.sh

# 録画した TS ファイルを再生する
CoaxPlayer /path/to/file.ts
```

| 引数 | 意味 |
| --- | --- |
| `--coax <path>` | 起動する coax のパス。省略時は実行ファイルと同じ場所の `coax`、無ければ PATH 上の `coax` |
| `--scan <path>` | チャンネル一覧にする `coax scan` の結果。無ければここに作る。省略時は `~/Library/Application Support/coax-player/scan.json` |
| `--decoder <path>` | 選局した TS を通す外部のデコーダー（下の「外部デコーダー」）。設定画面の指定より優先する |
| `--ch <n>` | 起動直後にこのチャンネルを再生する（`scan.json` にあるもの） |
| `--record` | `--ch` で選局したものを、そのまま録画する |
| `--debug` | mpv のログと、1 秒ごとの状態（再生位置、描画フレーム数など）を stderr に出す |
| `<file>` | ファイルを再生する（`--ch` が無いとき） |

`.app` の中の実行ファイルは `CoaxPlayer.app/Contents/MacOS/CoaxPlayer`。

## 外部デコーダー

選局した TS を、利用者が用意した外部のコマンド（デコーダー）に通してから再生・録画できる。デコーダーはこのアプリには含まれない。
設定画面（⌘,）の「外部デコーダー」で選ぶか、起動引数 `--decoder` で指定する。どちらも無ければ、Homebrew で入れた `/opt/homebrew/bin/arib-b25-stream-test` があれば自動で使う。

つなぎ方は [docs/decoder.md](docs/decoder.md) にある。

## ビルド

```sh
./scripts/build-deps.sh                          # libmpv と依存ライブラリを .deps/prefix に作る（初回のみ）
swift build                                      # 開発用
COAX_DIR=../coax ./scripts/bundle.sh             # dist/CoaxPlayer.app を作る
```

必要なものと詳細は [docs/build.md](docs/build.md)、内部の構成は [docs/architecture.md](docs/architecture.md) にある。

## 既知の制限

- 衛星放送（ISDB-S）のスキャンと選局には対応していない
- チャンネルは `scan.json` にあるものからしか選べない
- 字幕は MP4 に入らない（TS には残る）。ファイルの再生では字幕を出さない
- Apple Silicon のみ。Intel Mac 向けのバイナリは作っていない

## ライセンス

このリポジトリのコードは MIT ライセンス（[LICENSE](LICENSE)）。
`.app` に同梱する FFmpeg・mpv などのライブラリはそれぞれの条件（LGPL-2.1-or-later ほか）に従う。一覧は [NOTICE](NOTICE) にある。
`bundle.sh` は、これらのライセンスの全文（`COAX_DIR` を渡したときは coax のものも）を `.app` の `Contents/Resources/licenses/` に入れる。
