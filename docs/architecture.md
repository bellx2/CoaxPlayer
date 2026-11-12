# 内部の構成

## ファイル

- `Sources/CMpv` — libmpv の system library target（`module.modulemap`。ヘッダーとライブラリの場所は `Package.swift` で `.deps/prefix` を指定）
- `Sources/CAribCaption` — libaribcaption の system library target
- `Sources/CoaxPlayer/App.swift` — SwiftUI の画面と AppDelegate（終了時の後始末）。視聴画面だけの 1 ページ（上にデバイスの状態とボタン、映像とその下のチャンネルと番組の行、下に受信状態の 1 行。番組表は映像に重ねる）。設定画面（チューナー・スキャン・表示・録画の 4 つのタブ）
- `Sources/CoaxPlayer/PlayerModel.swift` — 起動引数、選局・停止、録画、スキャン、受信状態の保持
- `Sources/CoaxPlayer/MPVPlayer.swift` — libmpv の初期化、ソフトウェアレンダラでの描画、トラックの選択、イベント処理
- `Sources/CoaxPlayer/Enhancer.swift` — 高精細化（ノイズ除去と超解像、macOS 26 以降）
- `Sources/CoaxPlayer/PixUserland.swift` — PIX-DT295 を pix-userland で使うための、pixd と pix-ts の場所と引数、`pixd --list-json` の読み取り（[dt295.md](dt295.md)）
- `Sources/CoaxPlayer/CoaxProcess.swift` — `coax tune`・`coax scan`・`coax pcsc` とデコーダーの子プロセス。stdout を fd で返し（tune はデコーダーか中継へ）、stderr を 1 行ずつ通知
- `Sources/CoaxPlayer/StreamTee.swift` — coax の出力を mpv へ中継し、録画中はファイルにも書く。字幕の PES もここで取り出す
- `Sources/CoaxPlayer/CaptionExtractor.swift` — TS から、再生中の番組の字幕の PES を取り出す
- `Sources/CoaxPlayer/LogoExtractor.swift` — TS の CDT から局ロゴの PNG を取り出し、パレットを足す
- `Sources/CoaxPlayer/CaptionRenderer.swift` — 字幕を libaribcaption で解読し、映像の表示領域の実ピクセル数で描く
- `Sources/CoaxPlayer/Updater.swift` — GitHub の最新の Release（API の `releases/latest`）で新しい版を確かめ、Homebrew で入れていれば brew で更新して起動し直す
- `Sources/CoaxPlayer/Guide.swift` — 視聴中に集めた番組表（`--schedule` の行）の保持と保存
- `Sources/CoaxPlayer/GuideView.swift` — 番組表（視聴画面の下半分に重ねる）
- `Sources/CoaxPlayer/Channels.swift` — `scan.json` から受信できたチャンネルを読む（リモコンの番号、局ロゴの在りかも）。スキャンで選べる範囲
- `scripts/build-deps.sh` — libmpv と依存ライブラリのビルド
- `scripts/bundle.sh` — `.app` の組み立て
- `scripts/fake-coax.sh` — 動作確認用の coax の代わり

## 選局と再生の流れ

1. 局を選ぶと（起動時は前回最後に見た局）`coax tune --ch N --stats --program --schedule` を起動する（デコーダーを指定していれば、その stdin につなぐ）
2. 出力は `StreamTee` が読んで、パイプ経由で `fdclose://N` として mpv に渡す（mpv が読み終えたら閉じる）。録画中はファイルにも書き、字幕の PES も取り出す
3. coax の stderr の行を画面下に表示する。`now` の行（`--program`）は今の番組として映像の下の行に出す。`now` の行と、それに続く `now-text`・`now-item` の詳細の行は、番組詳細のパネルにも出す（`next` で始まる次の番組の行は使わない）（詳細の行の `\n`・`\t`・`\\` は元に戻す）。それ以外は受信状態として最新の 1 行をそのまま出す（coax がエラーで終わったときはそのメッセージが残る）
4. 「停止」・チャンネル切替・ウィンドウを閉じる・Ctrl-C/SIGTERM では、子プロセスへ SIGTERM を送り、3 秒で終わらなければ SIGKILL して終了を待つ

設定画面でチューナーを PIX-DT295 にしたときは、1 の `coax tune --ch N` の代わりに、pix-userland の `pix-ts` の出力を `coax tune --input - --stats --program --schedule` に流す。デコーダーは通さない。pixd の起動と止め方は [dt295.md](dt295.md) にある。

デバイスの状態は `coax list --tuners --json` で各デバイスを開いて確かめる。`tuners` は開けなくても型番から埋まるので、`probe_error` が無いものだけを見つかったとみなす。選局中は開けないので、確かめる前に再生を止め、見つかったら最後に見た局を選局し直す。coax の再起動は、`pkill -x coaxd` で止めて終わるのを待ち（最大 3 秒）、coax pcsc を立て直してから確かめ直す（coaxd は次の coax が起動する）。

チャンネル一覧（番組表の局の並び、左右の矢印キーの順）は、リモコンの番号（NIT の TS 情報記述子の `remote_control_key_id`）の順に、番号とサービス名を並べる。番号が無い古い `scan.json` では物理チャンネル（`27ch` など）を出す。

スキャンは設定画面から、`coax scan --discover=ISDBT --lock-timeout 3s --include '^(選んだ範囲)$' --output <--scan のパス> --restart` を実行し、終わると一覧を読み込み、一覧の先頭の局を見始める（前回の局が一覧にあればその局）。チューナーが PIX-DT295 のときは、`--data-timeout 5s --tune-command <pix-ts のコマンド>` を足す（[dt295.md](dt295.md#スキャン)）。
実行中は設定画面に進捗の行を出し、「中止」で止められる。coax は進捗を残すので、中止した次のスキャンだけは `--restart` を付けずに続きから調べる。

## 番組表

番組表は、視聴中の選局に付けた `coax tune --schedule` の行（EIT のスケジュールの 1 セクションを 1 行の JSON にしたもの）から作る（`Guide.swift`）。地上波の TS には同じ物理チャンネルのサービスの番組表しか無いので、見た局だけが埋まる。27ch（NHK 総合）で、8 日分がそろうまで約 60 秒だった。

1. 物理チャンネルごとに、セクション（original_network_id・transport_stream_id・service_id・テーブル ID・セクション番号）の最新の版を持つ。版が変われば置き換えるので、番組の変更や取り消しも反映される
2. 基本情報（テーブル ID の下位 4 ビットが 0〜7。番組名と説明）と拡張情報（8〜F。詳しい説明の項目だけ）を、サービスと番組 ID でまとめて 1 番組にする。セクションは 1 分ほど続けて届くので、並べ直しは 1 秒まとめて行う
3. 一つの局に複数のサービスがあるときは、最初のサービス（局名を取るもの、`serviceID`）の番組だけを出す
4. セクションのまま `~/Library/Application Support/CoaxPlayer/guide.json` に保存する。書くのは、変わったものがあるときの停止（チャンネル切替）と終了のとき。番組がすべて終わって 1 日たったセクションは捨てる
5. 開始時刻は時差の付かない日本時間の文字列なので、Asia/Tokyo として読む

番組表（`GuideView.swift`）は、視聴画面の映像の下半分に半透明で重ねる。横に局（一覧と同じ並び）、縦に 1 分 3 ポイントで 1 日（5 時から翌 5 時）を並べる。縦横を 1 つのスクロールにし、局名の行は上に留める（横には表と一緒に動く）。

## 局ロゴ

アンテナで受けた TS には、局ロゴの PNG が CDT（PID 0x29、ARIB STD-B21）で数分おきに流れる。scan.json のサービスのロゴの情報（`logo_transmission_type` が 1 のときの `download_data_id` と `logo_id`。coax は 0 を省くので、無ければ 0）で目当てのロゴを探し、HD 大（64x36、`logo_type` 5）を使う。

1. 中継（`StreamTee.swift`）で TS を読み、CDT のセクションを組み立てる（`LogoExtractor.swift`）
2. ロゴの PNG にはパレットが無く、ARIB の共通固定色（128 色。0〜64 は不透明、65〜127 は半透明）を使う決まりなので、PLTE と tRNS を足してから画像にする
3. `~/Library/Application Support/CoaxPlayer/logos/<物理チャンネル>.png` に保存し、選局したらまずそれを出す。届いたロゴが保存したものと違えば置き換える

## mpv の設定

- 低ビットレートのワンセグで表示開始を早めるため、`demuxer-lavf-probesize=200000`、`demuxer-lavf-analyzeduration=0.5`、`cache=no`、`profile=low-latency` で動かす
- `profile=low-latency` はストリームの解析を省くが、そのままではトラックが一つも見つからないので、`demuxer-lavf-probe-info=yes` で解析させる
- 音声出力は `ao=avfoundation`。mpv にパッチを当てて、AVSampleBufferAudioRenderer に先に渡す量を約 2 秒から 0.25 秒にしている（docs/build.md）。そのうえで `audio-buffer=0.5` を `profile=low-latency`（0 にする）より後に置く。受信はまとまって届くので、溜めが無いと再生が受信の端に追いつき、ほぼ 1 秒ごとに音が途切れるため。実測（温まった状態）で、選局から動き出すまでは約 5.0 秒から 2.3〜2.6 秒に、放送からの遅れは 1.6〜1.8 秒から 0.1〜0.4 秒になり、40 秒の再生で途切れは無かった
- 選局してから 5 秒経っても映像が 1 コマも描かれなければ、1 回だけ選局し直す（`PlayerModel.watchVideo`）。mpv が最初の解析で映像の種類を判定できないと（`Could not find codec parameters for stream 0`）、その再生の間ずっと映像が出ないため。実機で 17 回に 1 回ほど起きた
- `--debug` のときは、選局を始めてからの経過を `trace:` の行で出す（前の再生を止めた・coax とデコーダーの起動・中継の最初のバイトと PCR・mpv の file-loaded と最初のコマと再生開始）。1 秒ごとの `debug:` の行の `lag` は、中継が読んだ最新の PCR と再生位置の差で、放送からの遅れの目安になる
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
4. ワンセグの字幕には位置の情報が無い（TR-B14）ので、FFmpeg と同じく左右の中央で下から積む
5. 字幕には縁も背景も無いものが多く、明るい場面で読めないので、すべての文字に不透明の黒の縁（背景なしでは 3 ドット、背景を敷くときは 1.5 ドット）を付ける。libaribcaption の強制縁取りは縁の色に背景色を使うので、解読した字幕の文字ごとに縁の色を黒にしてから描く。放送側の背景は描かない（`aribcc_renderer_set_force_no_background`）
6. 行ごとに半透明の黒を敷く。設定（`captionBackground`）で「なし」を選んだときは敷かない

ファイルの再生では中継を通らないので、字幕は出ない。

## 録画

1. 録画中は、中継しているバイト列を `~/Movies/coax/日時_リモコンの番号_局名_番組名.ts` にも書く。受信したままの TS なので、字幕や番組情報も残る
2. 止めたら、設定画面の「録画の変換」に引数があるときだけ、同梱の ffmpeg で変換する。`{video}`・`{audio}` は、止めた時点で再生していたもの（`current-tracks/video/src-id` と `audio/src-id`）を `0:i:<PID>` にして渡す（フルセグも届いているときに、再生していない方を選ばないため）。TS は残す。変換の進み具合と結果は画面に出さず、失敗したときだけ stderr に出す
3. 録画中に MP4 を直接書かないのは、MP4 は最後に目次（moov）を書くので、途中で落ちると全体が読めなくなるため

## 実装上の制限

- 拡大は CALayer の補間なので、mpv のスケーラ（シェーダ）による高画質化は効かない。OSD も映像サイズで描かれる（字幕は別のレイヤーに描く）
- 停止は子プロセスの終了を待つ間（最大 3 秒）メインスレッドを止める
- アプリが SIGKILL などで強制終了した場合、子プロセスは直接は止めない。coax は stdout のパイプが閉じて書き込みに失敗した時点で終わる想定
- `estimated-vf-fps` は SW 描画では取れず、インターレース解除後の値も反映しない（`--debug` では描画フレーム数を代わりに出す）
