# 应用图标

本项目使用 imagegen 内置图像工具生成独立的阅读器图标：深青色圆角底、展开的象牙白书页和书签。没有使用原 UVZ 阅读器、UnicornViewer 或其他应用的图标。

- `AppIcon.png`：生成的透明背景原图。
- `AppIcon.icns`：用于应用包的多尺寸图标，包含 16、32、128、256、512 点及对应双倍分辨率。
- `build-icon.sh`：使用系统 sips、iconutil 生成 ICNS；缩放和格式转换不需要其他依赖。
- Info.plist 的 CFBundleIconFile 指向 AppIcon，构建时复制到应用 Resources。

生成方式：内置 imagegen，transparent_background=true。

生成提示词原文：

> Use case: logo-brand. Asset type: production macOS desktop application icon for an independent scholarly ebook and scanned-book reader. A single exquisite simple open book, ivory paper, a subtle turning page, clear symmetrical book silhouette with substantial shapes that read well at 32px. Centered on a softly rounded square tile with restrained deep teal blue color and gentle tactile depth, modern macOS native icon aesthetic. Warm pale page edges and one restrained bookmark accent. Front-facing, no busy environment. Transparent outside the tile, ample safe outer padding appropriate for macOS icons. No letters, no words, no numbers, no watermark, no mockup, no multiple variants. Square 1024 by 1024.
