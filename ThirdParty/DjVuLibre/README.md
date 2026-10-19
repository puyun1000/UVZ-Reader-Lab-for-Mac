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
without external JPEG, TIFF, X11, XML or desktop dependencies, targeting
macOS 14 or later. The Swift reader is not linked with this library. It
executes `djvused` to index documents and `ddjvu` to render pages as RGB PPM.

No source patch is applied. Ad hoc code signing is applied to the copied
executables by the application's `build.sh`. The JPEG-dependent DjVu
chunks are outside this build's compatibility scope. TIFF output support
is unnecessary because RGB PPM is used. Only ddjvu and djvused are shipped;
upstream build tools and sample documents remain available in this source.
