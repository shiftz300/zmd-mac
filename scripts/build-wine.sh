#!/bin/bash
set -euo pipefail
ZMD_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${ZMD_WORK_DIR:-$ZMD_PROJECT}"
python3 "$ZMD_PROJECT/scripts/prepare-session-patch.py"
SDK="$ROOT/tools/x86_64"
NATIVE="$ROOT/tools/native"
SOURCE="$ROOT/build/wine-src"
BUILD="$ROOT/build/wine"
export PATH="$NATIVE/opt/mingw-w64/bin:$NATIVE/opt/bison/bin:$NATIVE/opt/pkgconf/bin:$PATH"
export BISON_PKGDATADIR="$NATIVE/opt/bison/share/bison"
export PKG_CONFIG_LIBDIR="$SDK/lib/pkgconfig:$SDK/share/pkgconfig"
export PKG_CONFIG_PATH=""
export MACOSX_DEPLOYMENT_TARGET=14.0
export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
export OBJC="clang -arch x86_64"
export CPPFLAGS="-I$SDK/include"
export LDFLAGS="-L$SDK/lib -Wl,-rpath,$SDK/lib"
export CROSSCFLAGS="-O2"
mkdir -p "$BUILD"
cd "$BUILD"

if [ ! -f Makefile ]; then
    "$SOURCE/configure" \
        --prefix="$ROOT/runtime/wine" \
        --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
        --enable-archs=i386,x86_64 \
        --with-mingw x86_64_CC=x86_64-w64-mingw32-gcc i386_CC=i686-w64-mingw32-gcc \
        --disable-tests --disable-winebth_sys \
        --with-coreaudio --with-freetype --with-gettext --with-gnutls \
        --with-opencl --with-pcap --with-pcsclite --with-pthread --with-sdl --with-vulkan \
        --without-alsa --without-capi --without-cups --without-dbus --without-ffmpeg \
        --without-fontconfig --without-gettextpo --without-gphoto --without-gssapi \
        --without-gstreamer --without-inotify --without-krb5 --without-netapi \
        --without-opengl --without-oss --without-pulse --without-sane --without-udev \
        --without-usb --without-v4l2 --without-wayland --without-x
fi
make -j"${JOBS:-8}"
make install-lib
cp "$SOURCE/COPYING.LIB" "$ROOT/runtime/wine/"
