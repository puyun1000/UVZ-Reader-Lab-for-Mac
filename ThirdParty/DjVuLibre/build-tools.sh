#!/bin/zsh
set -eu
LAB_VENDOR="${0:A:h}"
LAB_JPEG="$LAB_VENDOR/../JPEG"
LAB_FINGERPRINT=$(shasum -a 256 "$LAB_VENDOR/build-tools.sh" "$LAB_VENDOR/reader-safety.patch" "$LAB_VENDOR/djvulibre-3.5.30.tar.gz" "$LAB_JPEG/jpegsrc.v10.tar.gz" | shasum -a 256 | cut -d ' ' -f 1)
if [[ "${1:-}" == --fingerprint ]]; then print -r -- "$LAB_FINGERPRINT"; exit 0; fi
LAB_DEST="${1:?Supply destination directory}"
LAB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/uvz-djvu.XXXXXX")
trap 'rm -rf "$LAB_TMP"' EXIT
[[ $(shasum -a 256 "$LAB_JPEG/jpegsrc.v10.tar.gz" | cut -d ' ' -f 1) == 8b9eaa13242690ebd03e1728ab1edf97a81a78ed6e83624d493655f31ac95ab5 ]]
tar -xzf "$LAB_JPEG/jpegsrc.v10.tar.gz" -C "$LAB_TMP"
cd "$LAB_TMP/jpeg-10"
./configure --prefix="$LAB_TMP/jpeg-install" --disable-shared --enable-static CFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0'
make -j4
make install
cd "$LAB_TMP"
tar -xzf "$LAB_VENDOR/djvulibre-3.5.30.tar.gz"
cd djvulibre-3.5.30
patch -p1 < "$LAB_VENDOR/reader-safety.patch"
./configure --disable-shared --enable-static --disable-desktopfiles --disable-xmltools --with-jpeg="$LAB_TMP/jpeg-install" --without-tiff --without-x CXXFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0' CFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0'
grep -q '^#define NEED_JPEG_DECODER 1' config.h
make -j4
mkdir -p "$LAB_DEST"
cp tools/ddjvu tools/djvused tools/c44 tools/cjb2 tools/djvumake "$LAB_DEST/"
print -r -- "$LAB_FINGERPRINT" > "$LAB_DEST/build-id"
