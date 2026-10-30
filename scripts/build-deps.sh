#!/usr/bin/env bash
# libmpv と依存ライブラリを、放送の再生に要る最小構成でビルドして .deps/prefix に入れる。
# Homebrew のライブラリは使わない。GPL の部分は外し、LGPL で配布できる構成にする。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPS=$ROOT/.deps
SRC=$DEPS/src
PREFIX=$DEPS/prefix
JOBS=$(sysctl -n hw.ncpu)

export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
# Homebrew の .pc を拾わないよう、探す場所をここだけにする
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
unset PKG_CONFIG_PATH
# Homebrew のツールを誤って使わないよう、PATH は最小限にする（uv と pkg-config は先に場所を控える）
UV=$(command -v uv)
PKG_CONFIG=$(command -v pkg-config)
export PKG_CONFIG
export PATH=$DEPS/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin

mkdir -p "$SRC" "$PREFIX"

# meson と ninja はビルドにだけ使うので、ここの venv に入れる
if [ ! -x "$DEPS/venv/bin/meson" ]; then
  "$UV" venv -q "$DEPS/venv"
  "$UV" pip install -q --python "$DEPS/venv/bin/python" meson ninja jinja2
fi

# fetch 名前 URL SHA-256：取得して照合し、$SRC/名前 に展開する
fetch() {
  local name=$1 url=$2 sum=$3
  local archive=$SRC/$(basename "$url")
  [ -f "$archive" ] || curl -fsSL --retry 5 --retry-all-errors -o "$archive" "$url"
  echo "$sum  $archive" | shasum -a 256 -c - >/dev/null
  rm -rf "${SRC:?}/$name"
  mkdir -p "$SRC/$name"
  tar -xf "$archive" -C "$SRC/$name" --strip-components 1
}

# meson_install 名前 オプション...
meson_install() {
  local name=$1
  shift
  (cd "$SRC/$name" &&
    meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
      --default-library=shared "$@" >/dev/null &&
    ninja -C build install >/dev/null)
  echo "built $name"
}

fetch freetype https://downloads.sourceforge.net/project/freetype/freetype2/2.15.0/freetype-2.15.0.tar.xz \
  93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5
meson_install freetype -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=disabled

fetch fribidi https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz \
  1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f
meson_install fribidi -Ddocs=false -Dtests=false -Dbin=false

fetch harfbuzz https://github.com/harfbuzz/harfbuzz/releases/download/15.0.0/harfbuzz-15.0.0.tar.xz \
  968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df
meson_install harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
  -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled -Dutilities=disabled

fetch libass https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz \
  2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
meson_install libass -Dfontconfig=disabled -Dcoretext=enabled -Dlibunibreak=disabled -Dtest=disabled

# 放送の TS に要るものだけ：MPEG-TS、H.264、MPEG-2 映像、AAC。デコードは VideoToolbox も使う。
# h264・aac・mpegvideo のデマルチプレクサーは、PMT より先に届いたストリームの中身を判別するのに要る
fetch ffmpeg https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz \
  8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
(cd "$SRC/ffmpeg" &&
  ./configure --prefix="$PREFIX" --install-name-dir='@rpath' \
    --enable-shared --disable-static --disable-programs --disable-doc \
    --disable-autodetect --disable-network --disable-everything --disable-avdevice \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-demuxer=mpegts,h264,aac,mpegvideo \
    --enable-parser=h264,mpegvideo,aac,aac_latm \
    --enable-decoder=h264,mpeg2video,aac,aac_latm \
    --enable-hwaccel=h264_videotoolbox,mpeg2_videotoolbox \
    --enable-protocol=file,pipe \
    --enable-filter=aformat,aresample,anull,format,null,scale,bwdif,yadif >/dev/null &&
  make -j"$JOBS" >/dev/null && make install >/dev/null)
echo "built ffmpeg"

fetch libplacebo https://code.videolan.org/videolan/libplacebo/-/archive/v7.387.0/libplacebo-v7.387.0.tar.bz2 \
  14ceeeb14d1c08fcdb1a782a06129da11f842c6fddbf3a43c1c4061406ad03d2
# 配布物にはサブモジュールの中身が無いので置く。Vulkan を使わなくてもヘッダーは参照され、
# fast_float は macOS 13 の libc++ に浮動小数点の from_chars が無いため要る
fetch vulkan-headers https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-1.4.363.0.tar.gz \
  4a078be12bef21cfebc09d878b77a63cff9d68f899254a0b00d0e37ef73e7f7e
fetch fast_float https://github.com/fastfloat/fast_float/archive/refs/tags/v8.3.2.tar.gz \
  71bb9e865b888df01351558db5a39586d13ea97ada162156b3a07784d8c1b26b
for name in Vulkan-Headers fast_float; do
  rm -rf "$SRC/libplacebo/3rdparty/$name"
done
cp -R "$SRC/vulkan-headers" "$SRC/libplacebo/3rdparty/Vulkan-Headers"
cp -R "$SRC/fast_float" "$SRC/libplacebo/3rdparty/fast_float"
meson_install libplacebo -Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled -Dglslang=disabled \
  -Dshaderc=disabled -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled -Ddemos=false -Dtests=false \
  -Dxxhash=disabled -Dunwind=disabled

# libmpv だけを作る。描画はソフトウェア描画を使うので、GL と Cocoa は要らない
fetch mpv https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz \
  ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
meson_install mpv -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dlibavdevice=disabled \
  -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled \
  -Ddvdnav=disabled -Dcdda=disabled -Duchardet=disabled -Drubberband=disabled -Dzimg=disabled \
  -Dlcms2=disabled -Dvapoursynth=disabled -Djpeg=disabled \
  -Dcocoa=disabled -Dswift-build=disabled -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled \
  -Dmacos-touchbar=disabled -Dgl=disabled -Dvulkan=disabled -Dplain-gl=disabled \
  -Dvideotoolbox-gl=disabled -Dvideotoolbox-pl=disabled \
  -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled

echo "done: $PREFIX/lib"
