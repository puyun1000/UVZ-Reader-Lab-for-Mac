#!/bin/zsh
set -eu
LAB_VENDOR="${0:A:h}"
LAB_DEST="${1:?Supply destination directory}"
LAB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/uvz-djvu.XXXXXX")
trap 'rm -rf "$LAB_TMP"' EXIT
tar -xzf "$LAB_VENDOR/djvulibre-3.5.30.tar.gz" -C "$LAB_TMP"
cd "$LAB_TMP/djvulibre-3.5.30"
./configure --disable-shared --enable-static --disable-desktopfiles --disable-xmltools --without-jpeg --without-tiff --without-x CXXFLAGS='-O2 -mmacosx-version-min=14.0' CFLAGS='-O2 -mmacosx-version-min=14.0'
make -j4
mkdir -p "$LAB_DEST"
cp tools/ddjvu tools/djvused "$LAB_DEST/"
