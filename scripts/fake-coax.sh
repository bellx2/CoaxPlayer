#!/bin/sh
# 動作確認用の coax の代わり。実チューナーを使わずに「再生」の経路を試す。
# FAKE_TS の TS を stdout へ流し、stats 風の行を 1 秒ごとに、番組の行と番組詳細の行（--program 相当）を最初に一度 stderr へ出す。
# 番組詳細の改行は coax と同じく「\n」の 2 文字で書く（sh の echo は解釈してしまうので printf の %s で出す）。
: "${FAKE_TS:?FAKE_TS に TS ファイルのパスを指定してください}"
n=0
echo "$(date +%H:%M:%S) now 21:00-22:00 テスト番組（今）" >&2
printf '%s now-text %s\n' "$(date +%H:%M:%S)" '今の番組の説明。\n改行のあとの行' >&2
printf '%s now-item %s\t%s\n' "$(date +%H:%M:%S)" '出演者' '【司会】テスト太郎\n【ゲスト】テスト花子' >&2
echo "$(date +%H:%M:%S) next 22:00-22:30 テスト番組（次）" >&2
echo "$(date +%H:%M:%S) next-text 次の番組の説明" >&2
( while :; do
    n=$((n + 1))
    echo "$(date +%H:%M:%S) locked  CNR 17.4dB  -77dBm  0.51 Mbps  dropped 0 (+0)  fake $n  args: $*" >&2
    sleep 1
  done ) &
STATS=$!
cat "$FAKE_TS" &
CAT=$!
trap 'kill $CAT $STATS 2>/dev/null; exit 0' TERM INT
wait $CAT
kill $STATS 2>/dev/null
