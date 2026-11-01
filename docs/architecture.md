# 内部の構成

## ファイル

- `Sources/CMpv` — libmpv の system library target（`module.modulemap`。ヘッダーとライブラリの場所は `Package.swift` で `.deps/prefix` を指定）
- `Sources/CAribCaption` — libaribcaption の system library target
- `Sources/CoaxPlayer/App.swift` — SwiftUI の画面と AppDelegate（終了時の後始末）。最初のページにチャンネル一覧、選ぶと映像のページ（上にボタン、映像とその下のチャンネルと番組の行）。どちらも下に受信状態の 1 行。設定画面（スキャン、外部デコーダー）
- `Sources/CoaxPlayer/PlayerModel.swift` — 起動引数、選局・停止、録画、スキャン、受信状態の保持
- `Sources/CoaxPlayer/MPVPlayer.swift` — libmpv の初期化、ソフトウェアレンダラでの描画、トラックの選択、イベント処理
- `Sources/CoaxPlayer/Enhancer.swift` — 高精細化（ノイズ除去と超解像、macOS 26 以降）
- `Sources/CoaxPlayer/CoaxProcess.swift` — `coax tune`・`coax scan`・`coax pcsc` とデコーダーの子プロセス。stdout を fd で返し（tune はデコーダーか中継へ）、stderr を 1 行ずつ通知
- `Sources/CoaxPlayer/StreamTee.swift` — coax の出力を mpv へ中継し、録画中はファイルにも書く。字幕の PES もここで取り出す
- `Sources/CoaxPlayer/CaptionExtractor.swift` — TS から、再生中の番組の字幕の PES を取り出す
- `Sources/CoaxPlayer/LogoExtractor.swift` — TS の CDT から局ロゴの PNG を取り出し、パレットを足す
- `Sources/CoaxPlayer/CaptionRenderer.swift` — 字幕を libaribcaption で解読し、映像の表示領域の実ピクセル数で描く
- `Sources/CoaxPlayer/Channels.swift` — `scan.json` から受信できたチャンネルを読む（リモコンの番号、局ロゴの在りかも）。スキャンで選べる範囲
- `scripts/build-deps.sh` — libmpv と依存ライブラリのビルド
- `scripts/bundle.sh` — `.app` の組み立て
- `scripts/fake-coax.sh` — 動作確認用の coax の代わり

## 選局と再生の流れ

1. 一覧のチャンネルを押すと `coax tune --ch N --stats --program` を起動する（デコーダーを指定していれば、その stdin につなぐ）
2. 出力は `StreamTee` が読んで、パイプ経由で `fdclose://N` として mpv に渡す（mpv が読み終えたら閉じる）。録画中はファイルにも書き、字幕の PES も取り出す
3. coax の stderr の行を画面下に表示する。`now` の行（`--program`）は今の番組として映像の下の行に出し（`next` の行は使わない）、それ以外は受信状態として最新の 1 行をそのまま出す（coax がエラーで終わったときはそのメッセージが残る）
4. 「停止」・チャンネル切替・ウィンドウを閉じる・Ctrl-C/SIGTERM では、子プロセスへ SIGTERM を送り、3 秒で終わらなければ SIGKILL して終了を待つ

一覧の今の番組は、チャンネルを順に `coax tune --ch N --program --priority -1` で選局し（視聴の選局がチューナーを奪えるよう、優先度を下げる）、`now` の行が届いたら（10 秒で届かなければあきらめて）次へ進んで集める。TS は使わないが、読まずに閉じると coax が書き込みで終わるので読み捨てる。

デバイスの状態は `coax list --tuners --json` で各デバイスを開いて確かめる。`tuners` は開けなくても型番から埋まるので、`probe_error` が無いものだけを見つかったとみなす。選局中は開けないので、確かめる前に番組の取得を止める。coax の再起動は、`pkill -x coaxd` で止めて終わるのを待ち（最大 3 秒）、coax pcsc を立て直してから確かめ直す（coaxd は次の coax が起動する）。

チャンネル一覧は、リモコンの番号（NIT の TS 情報記述子の `remote_control_key_id`）の順に、番号とサービス名を並べる。番号が無い古い `scan.json` では物理チャンネル（`27ch` など）を出す。

スキャンは設定画面から、`coax scan --discover=ISDBT --lock-timeout 3s --include '^(選んだ範囲)$' --output <--scan のパス> --restart` を実行し、終わると一覧を読み込む。
実行中は設定画面に進捗の行を出し、「中止」で止められる。coax は進捗を残すので、中止した次のスキャンだけは `--restart` を付けずに続きから調べる。

## 局ロゴ

アンテナで受けた TS には、局ロゴの PNG が CDT（PID 0x29、ARIB STD-B21）で数分おきに流れる。scan.json のサービスのロゴの情報（`logo_transmission_type` が 1 のときの `download_data_id` と `logo_id`。coax は 0 を省くので、無ければ 0）で目当てのロゴを探し、HD 大（64x36、`logo_type` 5）を使う。

1. 中継（`StreamTee.swift`）で TS を読み、CDT のセクションを組み立てる（`LogoExtractor.swift`）
2. ロゴの PNG にはパレットが無く、ARIB の共通固定色（128 色。0〜64 は不透明、65〜127 は半透明）を使う決まりなので、PLTE と tRNS を足してから画像にする
3. `~/Library/Application Support/CoaxPlayer/logos/<物理チャンネル>.png` に保存し、選局したらまずそれを出す。届いたロゴが保存したものと違えば置き換える

## mpv の設定

- 低ビットレートのワンセグで表示開始を早めるため、`demuxer-lavf-probesize=200000`、`demuxer-lavf-analyzeduration=0.5`、`cache=no`、`profile=low-latency` で動かす
- `profile=low-latency` はストリームの解析を省くが、そのままではトラックが一つも見つからないので、`demuxer-lavf-probe-info=yes` で解析させる
- フルセグは 1080i なので、インターレースの映像だけ解除する（`deinterlace=auto`。bwdif で 1 フィールドずつ出すので、約 60 フレーム/秒になる）
- 二か国語や解説の番組（デュアルモノ。左に主音声、右に副音声）は、そのままだと両方が同時に鳴る。`ad-lavc-o=dual_mono_mode=main` で主音声だけを両方のスピーカーから鳴らす。普通のステレオの番組には効かない。「音声」のボタンで `main`・`sub`・`both` を切り替えるときは、`ad-lavc-o` を書き換えてから音声のトラックを外して付け直し、デコーダーを作り直す（音声が一瞬途切れる）

### トラックの選択

アンテナで受けた TS にはフルセグとワンセグの両方が入っていて、mpv は先頭のフルセグを選ぶ。
フルセグを再生できないときはそのままだと何も映らないので、トラックを選ぶ前（`on_preloaded` のフック）にアプリが映像と、それと同じ番組の音声を指定する。

- フルセグを選ぶのは、デコーダーを指定しているとき（`--decoder`）か、解析で映像の大きさが分かったとき（再生できるファイル）
- それ以外と、「ワンセグ」がオンのときは、ワンセグ（H.264）を選ぶ
- 「ワンセグ」を切り替えたときは、再生中のまま同じ選び方で指定し直す

## 描画

ソフトウェアレンダラ（`vo=libmpv` + `MPV_RENDER_API_TYPE_SW`）で、映像の表示サイズのまま `bgra` で、IOSurface 付きの CVPixelBuffer に直接描く。
それをそのまま CALayer の contents にし、拡大縮小は CALayer（縦横比を保つ）に任せる。

ソフトウェアレンダラを選んだ理由:

- 主な対象のワンセグ（320x180、15fps）は、CPU で描いても負荷が小さい
- OpenGL は macOS で非推奨で、NSOpenGLView/CGL のコンテキスト管理とスレッドの扱いが増える。SW なら描画キュー 1 本と CALayer だけで済む
- 拡大はレイヤの補間に任せるので、ウィンドウサイズを変えても再描画は要らない

描く先を IOSurface にしてコピーをなくし、CPU での拡大（フルセグの 1440→1920）は `sws-scaler=bilinear` にした。
フルセグ相当（MPEG-2 1440x1080i、15Mbps）で M4 Pro の 1 コアの約 26%（デコード自体は約 2%）。インターレース解除を入れると約 50%。

### 高精細化（macOS 26 以降）

ワンセグのような小さな映像は、使える環境なら常に VideoToolbox で次のように処理してから表示する（切り替えの設定は無い）。

1. 時間方向のノイズ除去（`VTTemporalNoiseFilter`、強さ 0.5）。遅れが出ないよう、後ろのフレームは待たず直前の 1 フレームだけを参照する
2. 低遅延の超解像（`VTLowLatencySuperResolutionScaler`）。対応する一番大きな倍率で拡大する（ワンセグは 4 倍の 1280x720）

- 処理は 1 フレームあたり 3 ms 前後。ワンセグでの CPU 使用率は 1 コアの約 6% から約 11% になる（M4 Pro）
- 超解像が対応しない大きさ（フルセグなど）や、macOS 25 以前、対応しない Mac では何もしない

## 字幕

mpv には字幕を描かせず（`sid=no`）、アプリが別のレイヤーに描く。mpv は映像の大きさ（ワンセグなら 320x180）でしか描けず、拡大すると粗くなるため。

1. 中継（`StreamTee.swift`）で TS を読み、再生中の映像と同じ番組の字幕の PES を取り出す（`CaptionExtractor.swift`）。PMT は PAT からたどるほか、PAT を含まないワンセグの TS のため、決まった PID（0x1FC8〜0x1FCF）も読む。フルセグも届いているときは、mpv が再生している映像の PID で番組を選ぶ
2. libaribcaption で解読し、画面上の映像の表示領域の実ピクセル数（Retina では 2 倍）で描く（`CaptionRenderer.swift`）。文字は CoreText でヒラギノなどのシステムのフォントで描く
3. 0.1 秒ごとに mpv の `time-pos` と字幕の PTS を比べ、その時刻の字幕を出す。`rebase-start-time=no` にして、`time-pos` を放送の時刻（PTS）のままにしている
4. ワンセグの字幕には位置の情報が無い（TR-B14）ので、FFmpeg と同じく左右の中央で下から積む。縁も背景も無く明るい場面で読めないので、行ごとに半透明の黒を敷く

ファイルの再生では中継を通らないので、字幕は出ない。

## 録画

1. 録画中は、中継しているバイト列を `~/Movies/coax/日時_リモコンの番号_局名_番組名.ts` にも書く。受信したままの TS なので、字幕や番組情報も残る
2. 止めたら、同梱の ffmpeg で主音声だけの MP4（同じ名前の `.mp4`）を作る。映像はそのまま、音声はデュアルモノなら主音声だけにして AAC（128 kbps）にし直す。入れる映像と音声は、止めた時点で再生していたものの PID で選ぶ（フルセグも届いているときに、再生していない方を選ばないため）。TS は残す。変換の進み具合と結果は画面に出さず、失敗したときだけ stderr に出す
3. 録画中に MP4 を直接書かないのは、MP4 は最後に目次（moov）を書くので、途中で落ちると全体が読めなくなるため

## 実装上の制限

- 拡大は CALayer の補間なので、mpv のスケーラ（シェーダ）による高画質化は効かない。OSD も映像サイズで描かれる（字幕は別のレイヤーに描く）
- 停止は子プロセスの終了を待つ間（最大 3 秒）メインスレッドを止める
- アプリが SIGKILL などで強制終了した場合、子プロセスは直接は止めない。coax は stdout のパイプが閉じて書き込みに失敗した時点で終わる想定
- `estimated-vf-fps` は SW 描画では取れず、インターレース解除後の値も反映しない（`--debug` では描画フレーム数を代わりに出す）
