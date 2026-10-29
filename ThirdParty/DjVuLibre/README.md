# DjVuLibre command-line components

Upstream: https://djvu.sourceforge.net/
Source release: 3.5.30, downloaded from
https://downloads.sourceforge.net/project/djvu/DjVuLibre/3.5.30/djvulibre-3.5.30.tar.gz

`djvulibre-3.5.30.tar.gz` is the unmodified complete source archive. `COPYING`
contains GPL version 2; upstream permits version 2 or later. Upstream
copyright notices are in the archive. The app includes these files too.

Build on Apple silicon with Apple Command Line Tools:

```sh
zsh build-tools.sh /absolute/output/directory
```

The script configures the library statically for its own standalone tools,
with a static IJG JPEG 10 library and without TIFF, X11, XML or desktop dependencies, targeting
macOS 14 or later. The Swift reader is not linked with this library. It
executes `djvused` to index documents and `ddjvu` to render pages as RGB PPM.

`reader-safety.patch` adds pixel checks before page/JPEG allocation and rejects
unsupported JPEG2000 and CMYK JPEG layers instead of returning partial images.
JPEG background/foreground chunks are enabled. The patch is local; the source
tarball remains unmodified. JPEG source and license are in ../JPEG. A build
fingerprint invalidates old helper caches when source, patch or flags change.
Ad hoc signing is applied by build.sh. Only ddjvu and djvused are shipped;
c44/cjb2/djvumake are retained in the local build cache for generated tests.
