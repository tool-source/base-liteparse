#!/bin/sh
set -eux

# tesseract-rs's build.rs hard-codes -DCMAKE_CXX_COMPILER=clang++ and -stdlib=libc++,
# so we need real clang + libc++ in the image (gcc/g++ from build-base is not enough).
# Alpine's libc++ links against llvm-libunwind (NOT the GNU libunwind, which conflicts);
# libc++abi symbols are bundled in libc++ itself, no separate package.
# Static libs (openssl-libs-static, zlib-static) are required because musl rust defaults
# to crt-static for build scripts.
apk add --no-cache \
  build-base cmake git curl pkgconf perl \
  clang libc++-dev llvm-libunwind-dev \
  tesseract-ocr-dev leptonica-dev \
  openssl-dev openssl-libs-static zlib-static

curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable -t x86_64-unknown-linux-musl
. /root/.cargo/env

# napi produces a cdylib (.node) which MUST be dynamically linked against libc.
export RUSTFLAGS="-C target-feature=-crt-static"
npx napi build --cargo-cwd ../../crates/liteparse-napi --platform --release --js false --dts native.d.ts --target x86_64-unknown-linux-musl .

# The resulting .node has a DT_NEEDED on libc++.so.1 (clang+libc++ runtime),
# which is not present on stock node:20-alpine. Bundle the shared lib next to
# the .node so that the $ORIGIN rpath (set by liteparse-napi/build.rs) finds
# it at dlopen time. Same pattern we use for libpdfium.so.
for lib in libc++.so.1 libunwind.so.1; do
  src=$(find /usr/lib /usr/lib64 -maxdepth 2 -name "$lib" -type f 2>/dev/null | head -n1)
  if [ -z "$src" ]; then
    # On Alpine these are typically symlinks; resolve them.
    src=$(find /usr/lib /usr/lib64 -maxdepth 2 -name "$lib" 2>/dev/null | head -n1)
    src=$(readlink -f "$src")
  fi
  [ -n "$src" ] && [ -f "$src" ] || { echo "ERROR: cannot locate $lib"; exit 1; }
  cp -v "$src" "./$lib"
done
