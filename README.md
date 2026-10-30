# coax-swiftui

`coax tune` で選局した TS を libmpv で再生する、macOS 用の簡単なチューナー＆再生アプリの試作（SwiftUI + libmpv）。

libmpv と依存ライブラリは、放送の再生に要る最小構成で自前ビルドして `.app` に同梱する。
Homebrew などは不要で、macOS 13 以降の Apple Silicon の Mac で単独で動く。

## 必要なもの（ビルドする側）

- Swift 6（Xcode のコマンドラインツール）
- [uv](https://docs.astral.sh/uv/)（meson と ninja をビルド用の venv に入れるのに使う）と `pkg-config`
- `coax`（`.app` に同梱するか、PATH 上に置くか、`--coax` でパスを指定）

## ビルド

```sh
./scripts/build-deps.sh                          # libmpv と依存ライブラリを .deps/prefix に作る（初回のみ）
swift build                                      # 開発用（.deps のライブラリを読む）
COAX_DIR=../coax ./scripts/bundle.sh             # dist/CoaxPlayer.app を作る
```

`build-deps.sh` は coax-gpui と同じもので、FFmpeg 9.0.2（MPEG-TS、H.264、MPEG-2 映像、AAC と VideoToolbox のみ）、libplacebo、libass ほか、mpv 0.41.0（libmpv のみ、`-Dgpl=false`）をビルドする。
ソースは公式の配布元から取得して SHA-256 を照合する。
GPL の部品を含めないので、同梱するライブラリは LGPL などの条件で配布できる（`coaxd` は GPL-2.0-only なので、同梱するときはその条件に従う）。
最低対応 OS は `MACOSX_DEPLOYMENT_TARGET`（既定 13.0）で変えられる。

`bundle.sh` は、参照しているライブラリを `.deps` からたどって `Contents/Frameworks` に集め、参照先を `@rpath` に書き換えてアドホック署名する。
最後に、外部のライブラリへの参照が残っていないことを確かめる。
`SIGN_IDENTITY` を渡すと、その証明書で署名する（配布には、さらに公証が要る）。

## 実行

```sh
# 左の一覧（scan.json の受信できたチャンネル）から選んで再生する
swift run CoaxPlayer --coax /Users/bell/dev/t7b/coax/coax --scan /Users/bell/dev/t7b/coax/scan.json

# 起動と同時にチャンネルを選ぶ
swift run CoaxPlayer --coax /Users/bell/dev/t7b/coax/coax --scan /Users/bell/dev/t7b/coax/scan.json --ch 27

# 録画した TS ファイルを再生する（検証用）
swift run CoaxPlayer /path/to/file.ts

# チューナーを使わずに選局の経路を試す（coax の代わりに TS を流すスクリプト）
FAKE_TS=/path/to/file.ts swift run CoaxPlayer --coax "$PWD/scripts/fake-coax.sh" --scan /path/to/scan.json --ch 27
```

| 引数 | 意味 |
| --- | --- |
| `--coax <path>` | 起動する coax のパス。省略時は実行ファイルと同じ場所の `coax`、無ければ PATH 上の `coax` |
| `--scan <path>` | チャンネル一覧にする `coax scan` の結果。無ければここに作る。省略時は `~/Library/Application Support/coax-player/scan.json`（coax-gpui と共通） |
| `--ch <n>` | 起動直後にこのチャンネルを再生する（`scan.json` にあるもの） |
| `--debug` | mpv のログと、1 秒ごとの状態（time-pos、描画フレーム数、平均輝度など）を stderr に出す |
| `<file>` | ファイルを再生する（`--ch` が無いとき） |

## 構成

- `Sources/CMpv` — libmpv の system library target（`module.modulemap`。ヘッダーとライブラリの場所は `Package.swift` で `.deps/prefix` を指定）
- `Sources/CoaxPlayer/MPVPlayer.swift` — libmpv の初期化、ソフトウェアレンダラでの描画、イベント処理
- `Sources/CoaxPlayer/Enhancer.swift` — 高精細化（ノイズ除去と超解像、macOS 26 以降）
- `Sources/CoaxPlayer/CoaxProcess.swift` — `coax tune` と `coax scan` の子プロセス。stdout を fd で返し（tune は mpv へ）、stderr を 1 行ずつ通知
- `Sources/CoaxPlayer/Channels.swift` — `scan.json` から受信できたチャンネルを読む。スキャンで選べる範囲
- `Sources/CoaxPlayer/PlayerModel.swift` — 起動引数、再生・停止、受信状態の保持
- `Sources/CoaxPlayer/App.swift` — SwiftUI の画面と AppDelegate（終了時の後始末）。画面は coax-gpui と同じ配置と配色（左にチャンネル一覧と停止、右に映像、下に再生中のものと受信状態）
- `scripts/fake-coax.sh` — 動作確認用の coax の代わり（stats と番組の行も出す）
- `scripts/build-deps.sh` — libmpv と依存ライブラリのビルド
- `scripts/bundle.sh` — `.app` の組み立て

`scan.json` が無いとき（または受信できたチャンネルが1つも無いとき）は、左にスキャンする範囲（地上 UHF 13〜62、地上 VHF 1〜12、ケーブル C13〜C63）が並ぶ。
範囲を選んで「スキャン開始」を押すと `coax scan --discover=ISDBT --include '^(選んだ範囲)$' --output <--scan のパス>` を実行し、終わると一覧を読み込む。
実行中は画面下に進捗の行を出し、「スキャン中止」で止められる（coax は進捗を残すので、次は続きから）。

処理の流れ:

1. 一覧のチャンネルを押すと `coax tune --ch N --stats --program` を起動する。stdout のパイプを `dup` して `fdclose://N` として mpv に渡す（mpv が読み終えたら閉じる）
2. stderr の行を画面下に表示する。`now`・`next` の行（`--program`）は「今」「次」の番組として、それ以外は受信状態として最新の 1 行をそのまま出す（coax がエラーで終わったときはそのメッセージが残る）
3. mpv は `vo=libmpv` + ソフトウェアレンダラ（`MPV_RENDER_API_TYPE_SW`）で、映像の表示サイズのまま `bgra` で、IOSurface 付きの CVPixelBuffer に直接描く。それをそのまま CALayer の contents にし、拡大縮小は CALayer（縦横比を保つ）に任せる。高精細化がオンなら、その前に下の処理をかける
4. 「停止」・チャンネル切替・ウィンドウを閉じる・Ctrl-C/SIGTERM では、子プロセスへ SIGTERM を送り、3 秒で終わらなければ SIGKILL して終了を待つ

低ビットレートのワンセグで表示開始を早めるため、mpv は `demuxer-lavf-probesize=200000`、`demuxer-lavf-analyzeduration=0.5`、`cache=no`、`profile=low-latency` で動かす。

## 描画方式

ソフトウェアレンダラを選んだ。

- 対象がワンセグ（320x180、15fps）で、CPU で描いても負荷が小さい
- OpenGL は macOS で非推奨で、NSOpenGLView/CGL のコンテキスト管理とスレッドの扱いが増える。SW なら描画キュー 1 本と CALayer だけで済む
- 拡大はレイヤの補間に任せるので、ウィンドウサイズを変えても再描画は要らない
- 描く先を IOSurface にしてコピーをなくし、CPU での拡大（フルセグの 1440→1920）は `sws-scaler=bilinear` にした。フルセグ相当（MPEG-2 1440x1080i、15Mbps）で M4 Pro の 1 コアの約 26%（デコード自体は約 2%）

## 高精細化（macOS 26 以降）

左の「高精細化」がオンのとき、ワンセグのような小さな映像を VideoToolbox で次のように処理してから表示する。設定は次回の起動にも引き継ぐ。

1. 時間方向のノイズ除去（`VTTemporalNoiseFilter`、強さ 0.5）。遅れが出ないよう、後ろのフレームは待たず直前の 1 フレームだけを参照する
2. 低遅延の超解像（`VTLowLatencySuperResolutionScaler`）。対応する一番大きな倍率で拡大する（ワンセグは 4 倍の 1280x720）

- 処理は 1 フレームあたり 3 ms 前後。ワンセグでの CPU 使用率は 1 コアの約 6% から約 11% になる（M4 Pro）
- 超解像が対応しない大きさ（フルセグなど）や、macOS 25 以前では何もしない。使えない Mac ではボタン自体を出さない
- 実装は `Sources/CoaxPlayer/Enhancer.swift`

## coax の版

`coax tune` の `--stats` と `--program` を使う。どちらも fork（`bellx2/coax`）のブランチにある機能で、上流の coax にはまだ無い。`bundle.sh` の `COAX_DIR` には、それを含めてビルドした coax を渡す。

## 既知の制限

- フルセグ（1440x1080 の MPEG-2、スクランブル）は復号しないので映らない。スクランブルが無くても SW 描画は解像度に比例して重くなる
- 拡大は CALayer の補間なので、mpv のスケーラ（シェーダ）による高画質化は効かない。字幕・OSD も映像サイズで描かれる
- 停止は子プロセスの終了を待つ間（最大 3 秒）メインスレッドを止める
- アプリが SIGKILL などで強制終了した場合、子プロセスは直接は止めない。coax は stdout のパイプが閉じて書き込みに失敗した時点で終わる想定
- `estimated-vf-fps` は SW 描画では取れない（`--debug` では描画フレーム数を代わりに出す）
- Apple Silicon（arm64）のみ。Intel Mac 向けのユニバーサルバイナリは作っていない
- アイコン・メニューは最小限
- 文字入力の欄は無く、チャンネルは `scan.json` にあるものからしか選べない（coax-gpui とそろえた）
- スキャンできるのは地上波とケーブル（ISDB-T のチューナー）だけ。衛星（ISDB-S）の範囲はまだ無い
- `scan.json` を作り直す画面は無い。作り直すときはファイルを消してから起動する
