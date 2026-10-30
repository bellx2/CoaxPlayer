#!/bin/sh
# 動作確認用の coax の代わり。実チューナーを使わずに「再生」の経路を試す。
# FAKE_TS の TS を stdout へ流し、stats 風の行を 1 秒ごとに stderr へ出す。
: "${FAKE_TS:?FAKE_TS に TS ファイルのパスを指定してください}"
n=0
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
