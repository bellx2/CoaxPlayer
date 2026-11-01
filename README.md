# CoaxPlayer

[coax](https://github.com/bellx2/coax) で受信した地上デジタル放送を見るための、macOS 用のプレーヤー。

- チャンネルのスキャンと、局ロゴ・今の番組つきの一覧からの選局
- ワンセグ・フルセグの再生、ARIB 字幕、二か国語（主・副音声）の切り替え
- 録画（TS と、主音声だけの MP4）

## 動作環境

- Apple Silicon の Mac、macOS 13 以降
- coax が対応する USB 接続の ISDB-T チューナー（動作確認は Sony CECH-ZD1 J）

## インストール

```sh
brew install --cask bellx2/tap/coaxplayer
```

coax と、再生に使うライブラリは `.app` に入っているので、ほかに入れるものは無い。

## 使い方

1. `CoaxPlayer.app` を起動し、設定画面（⌘,）の「チャンネルスキャン」でスキャンする
2. 一覧のチャンネルを押すと再生する。Esc か delete で一覧に戻る

数字キーでも、リモコンの番号で選局できる。詳しくは [docs/usage.md](docs/usage.md)。

フルセグを見るには、利用者が用意した外部のデコーダーを設定画面で指定する（[docs/decoder.md](docs/decoder.md)）。デコーダーはこのアプリには含まれない。

## 既知の制限

- 衛星放送（ISDB-S）には対応していない
- 字幕は MP4 に入らない（TS には残る）。ファイルの再生では字幕を出さない

## ドキュメント

- [docs/usage.md](docs/usage.md) — 画面の操作、起動引数
- [docs/decoder.md](docs/decoder.md) — 外部デコーダーのつなぎ方
- [docs/build.md](docs/build.md) — ソースからのビルド
- [docs/architecture.md](docs/architecture.md) — 内部の構成

## ライセンス

このリポジトリのコードは MIT ライセンス（[LICENSE](LICENSE)）。
`.app` に同梱する coax・FFmpeg・mpv などはそれぞれの条件に従う。一覧は [NOTICE](NOTICE)、ライセンスの全文は `.app` の `Contents/Resources/licenses/` にある。
