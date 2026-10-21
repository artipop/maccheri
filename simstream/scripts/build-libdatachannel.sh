#!/bin/zsh
# Builds libdatachannel (WebRTC: ICE, DTLS, SRTP, SCTP data channels) with Mbed TLS as one static
# library and packs it as simstream/Vendor/LibDataChannel.xcframework for SwiftPM.
#
#   simstream/scripts/build-libdatachannel.sh
#
# Needs git, cmake and ninja. Sources and objects go to simstream/.deps (gitignored).
set -euo pipefail

LDC_VERSION=v0.24.6
MBEDTLS_VERSION=v3.6.7

root=${0:A:h:h}
deps=$root/.deps
out=$root/Vendor/LibDataChannel.xcframework
mkdir -p $deps
cd $deps

fetch() { # url tag dir
    if [[ ! -d $3 ]]; then
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch $2 --recurse-submodules --shallow-submodules $1 $3
    fi
}
fetch https://github.com/Mbed-TLS/mbedtls.git $MBEDTLS_VERSION mbedtls
fetch https://github.com/paullouisageneau/libdatachannel.git $LDC_VERSION libdatachannel
# DTLS-SRTP (media tracks) is off in Mbed TLS's default config.
python3 mbedtls/scripts/config.py -f mbedtls/include/mbedtls/mbedtls_config.h set MBEDTLS_SSL_DTLS_SRTP

common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON)

cmake -S mbedtls -B build-mbedtls $common -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DCMAKE_INSTALL_PREFIX=$deps/prefix >/dev/null
cmake --build build-mbedtls --target install >/dev/null

cmake -S libdatachannel -B build-ldc $common -DUSE_MBEDTLS=ON -DMbedTLS_ROOT=$deps/prefix \
    -DCMAKE_PREFIX_PATH=$deps/prefix -DNO_EXAMPLES=ON -DNO_TESTS=ON -DNO_WEBSOCKET=ON \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=$deps/prefix >/dev/null
cmake --build build-ldc --target install >/dev/null

# One archive with everything the C API needs.
libs=($deps/prefix/lib/libdatachannel.a $deps/prefix/lib/libmbed*.a)
for extra in build-ldc/deps/libjuice/libjuice.a build-ldc/deps/libsrtp/libsrtp2.a build-ldc/deps/usrsctp/usrsctplib/libusrsctp.a; do
    [[ -f $extra ]] && libs+=$deps/$extra
done
libtool -static -o $deps/libdatachannel-all.a $libs 2>/dev/null

headers=$deps/headers
rm -rf $headers && mkdir -p $headers
cp $deps/prefix/include/rtc/rtc.h $deps/prefix/include/rtc/version.h $headers/
cat > $headers/module.modulemap <<'MAP'
module LibDataChannel {
    header "rtc.h"
    link "c++"
    export *
}
MAP

rm -rf $out
xcodebuild -create-xcframework -library $deps/libdatachannel-all.a -headers $headers -output $out >/dev/null
echo "built $out"
