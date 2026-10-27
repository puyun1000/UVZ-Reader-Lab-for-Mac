#!/bin/zsh
set -eu
LAB_ROOT="${0:A:h}"
LAB_APP="$LAB_ROOT/UVZ Reader Lab.app"
LAB_BUILD="$LAB_ROOT/.build"
LAB_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/uvz-reader-lab.XXXXXX")
trap 'rm -rf "$LAB_STAGE"' EXIT
LAB_STAGE_APP="$LAB_STAGE/UVZ Reader Lab.app"
mkdir -p "$LAB_STAGE_APP/Contents/MacOS" "$LAB_STAGE_APP/Contents/Resources" "$LAB_BUILD"
if [[ ! -x "$LAB_BUILD/DjVuTools/ddjvu" || ! -x "$LAB_BUILD/DjVuTools/djvused" ]]; then
  /bin/zsh "$LAB_ROOT/ThirdParty/DjVuLibre/build-tools.sh" "$LAB_BUILD/DjVuTools"
fi
mkdir -p "$LAB_STAGE_APP/Contents/Helpers" "$LAB_STAGE_APP/Contents/Resources/DjVuLibre"
/bin/cp "$LAB_BUILD/DjVuTools/"{ddjvu,djvused} "$LAB_STAGE_APP/Contents/Helpers/"
/bin/cp "$LAB_ROOT/ThirdParty/DjVuLibre/"{COPYING,djvulibre-3.5.30.tar.gz,build-tools.sh} "$LAB_STAGE_APP/Contents/Resources/DjVuLibre/"
LAB_SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
/usr/bin/xcrun clang -O2 -arch arm64 -isysroot "$LAB_SDK" -mmacosx-version-min=14.0 -c "$LAB_ROOT/Source/ZipBridge.c" -o "$LAB_BUILD/ZipBridge.o"
/usr/bin/xcrun clang++ -O2 -std=c++17 -arch arm64 -isysroot "$LAB_SDK" -mmacosx-version-min=14.0 -Wno-deprecated-declarations -c "$LAB_ROOT/Source/PDGDecoder.cpp" -o "$LAB_BUILD/PDGDecoder.o"
/usr/bin/xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$LAB_SDK" \
  "$LAB_ROOT/Source/WorkflowUITest.swift" "$LAB_ROOT/Source/NativeEditing.swift" "$LAB_ROOT/Source/PDFExportWriter.swift" "$LAB_ROOT/Source/ConversionService.swift" "$LAB_ROOT/Source/ConversionWindow.swift" "$LAB_ROOT/Source/OnlineReferences.swift" "$LAB_ROOT/Source/ConversionUITest.swift" "$LAB_ROOT/Source/TitleNormalization.swift" "$LAB_ROOT/Source/MetadataResolver.swift" "$LAB_ROOT/Source/NamingPreferences.swift" "$LAB_ROOT/Source/NamingTemplateWindow.swift" "$LAB_ROOT/Source/BatchNaming.swift" "$LAB_ROOT/Source/BatchNamingWindow.swift" "$LAB_ROOT/Source/PageInspection.swift" "$LAB_ROOT/Source/PageRepairWindow.swift" "$LAB_ROOT/Source/PageAddressing.swift" "$LAB_ROOT/Source/NativeDialog.swift" "$LAB_ROOT/Source/AppGuide.swift" "$LAB_ROOT/Source/OCRWorkspace.swift" "$LAB_ROOT/Source/AppSettings.swift" "$LAB_ROOT/Source/TextRecognition.swift" "$LAB_ROOT/Source/BookMetadata.swift" "$LAB_ROOT/Source/BibliographicExtraction.swift" "$LAB_ROOT/Source/ContentsOperations.swift" "$LAB_ROOT/Source/DocumentFormats.swift" "$LAB_ROOT/Source/NativePDFOutline.swift" "$LAB_ROOT/Source/NativeDocumentMetadata.swift" "$LAB_ROOT/Source/BookEditor.swift" "$LAB_ROOT/Source/ContentsEditing.swift" "$LAB_ROOT/Source/RenameSheet.swift" "$LAB_ROOT/Source/BookArchive.swift" "$LAB_ROOT/Source/PageDecoder.swift" "$LAB_ROOT/Source/ReadingModel.swift" \
  "$LAB_ROOT/Source/ReadingSurface.swift" "$LAB_ROOT/Source/ReaderUI.swift" "$LAB_ROOT/Source/AppLifecycle.swift" "$LAB_ROOT/Source/main.swift" \
  "$LAB_BUILD/ZipBridge.o" "$LAB_BUILD/PDGDecoder.o" -lz -lc++ -framework AppKit -framework ImageIO -framework CryptoKit -framework PDFKit -framework VisionKit -framework Vision \
  -o "$LAB_STAGE_APP/Contents/MacOS/UVZReaderLab"
/bin/cp "$LAB_ROOT/Assets/AppIcon.icns" "$LAB_STAGE_APP/Contents/Resources/AppIcon.icns"
/bin/cp "$LAB_ROOT/Info.plist" "$LAB_STAGE_APP/Contents/Info.plist"
/bin/cp "$LAB_ROOT/ThirdPartyNotices.txt" "$LAB_STAGE_APP/Contents/Resources/ThirdPartyNotices.txt"
/bin/cp "$LAB_ROOT/Resources/"{UserGuide,ReleaseNotes}.md "$LAB_STAGE_APP/Contents/Resources/"
/bin/zsh "$LAB_ROOT/QuickLook/build-extensions.sh" "$LAB_STAGE_APP"
/usr/bin/xattr -cr "$LAB_STAGE_APP"
for LAB_HELPER in "$LAB_STAGE_APP/Contents/Helpers/"*; do /usr/bin/codesign --force --sign - "$LAB_HELPER"; done
/usr/bin/codesign --force --sign - "$LAB_STAGE_APP"
/usr/bin/codesign --verify --deep --strict "$LAB_STAGE_APP"
/usr/bin/ditto -c -k --keepParent --norsrc "$LAB_STAGE_APP" "$LAB_ROOT/UVZ Reader Lab.zip"
/usr/bin/ditto --norsrc "$LAB_STAGE_APP" "$LAB_APP"
print "Built: $LAB_APP"
