#!/bin/zsh
set -eu
QL_ROOT="${0:A:h:h}"
QL_APP="$1"
QL_SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
for QL_KIND in Preview Thumbnail; do
  QL_EXTENSION="$QL_APP/Contents/PlugIns/UVZ$QL_KIND.appex"
  mkdir -p "$QL_EXTENSION/Contents/MacOS"
  mkdir -p "$QL_EXTENSION/Contents/Helpers"
  /bin/cp "$QL_ROOT/.build/DjVuTools/ddjvu" "$QL_EXTENSION/Contents/Helpers/ddjvu"
  /usr/bin/codesign --force --sign - "$QL_EXTENSION/Contents/Helpers/ddjvu"
  /bin/cp "$QL_ROOT/QuickLook/$QL_KIND-Info.plist" "$QL_EXTENSION/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$QL_ROOT/Info.plist")" "$QL_EXTENSION/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$QL_ROOT/Info.plist")" "$QL_EXTENSION/Contents/Info.plist"
  /usr/bin/xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$QL_SDK" -application-extension -parse-as-library \
    -module-name "UVZ$QL_KIND" -Xlinker -e -Xlinker _NSExtensionMain \
    "$QL_ROOT/Source/BookArchive.swift" "$QL_ROOT/Source/DocumentFormats.swift" "$QL_ROOT/Source/NativePDFOutline.swift" "$QL_ROOT/Source/NativeDocumentMetadata.swift" "$QL_ROOT/Source/PageDecoder.swift" \
    "$QL_ROOT/QuickLook/CoverRenderer.swift" "$QL_ROOT/QuickLook/${QL_KIND}Provider.swift" \
    "$QL_ROOT/.build/ZipBridge.o" "$QL_ROOT/.build/PDGDecoder.o" -lz -lc++ \
    -framework AppKit -framework ImageIO -framework CryptoKit -framework PDFKit -framework QuickLookUI -framework QuickLookThumbnailing -framework UniformTypeIdentifiers \
    -o "$QL_EXTENSION/Contents/MacOS/UVZ$QL_KIND"
  /usr/bin/xattr -cr "$QL_EXTENSION"
  /usr/bin/codesign --force --sign - --entitlements "$QL_ROOT/QuickLook/Extension.entitlements" "$QL_EXTENSION"
done
