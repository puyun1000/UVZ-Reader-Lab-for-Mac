import AppKit

/// Page silhouettes communicate geometry directly, without clipboard/document symbols.
enum PageLayoutIcon {
    static func image(mode: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 24), flipped: false) { rect in
            NSColor.black.setStroke()
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).addClip()
            let double = mode >= 2, continuous = mode % 2 == 1
            let xs: [CGFloat] = double ? [2.5, 14] : [7]
            let ys: [CGFloat] = continuous ? [-13, 5, 23] : [3]
            for y in ys { for x in xs {
                let box = NSRect(x: x, y: y, width: double ? 9.5 : 12, height: continuous ? 15 : 18)
                let path = NSBezierPath(rect: box); path.lineWidth = 1.2; path.stroke()
                let line = NSBezierPath(); line.lineWidth = 0.8
                for offset: CGFloat in [4, 7, 10] where offset < box.height - 2 { line.move(to: NSPoint(x: box.minX + 2, y: box.maxY - offset)); line.line(to: NSPoint(x: box.maxX - 2, y: box.maxY - offset)) }
                line.stroke()
            } }
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = ["单页视图", "单页连续", "双页视图", "双页连续"][mode]
        return image
    }
}

final class AppGuide: NSObject {
    let window = ChineseWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 690), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let tabs = NSSegmentedControl(), text = ChineseTextView()
    override init() {
        super.init(); window.title = "UVZ Reader Lab 帮助"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 650, height: 480)
        let host = NSView(); window.contentView = host
        tabs.segmentCount = 2; tabs.trackingMode = .selectOne
        for (i, title) in ["功能说明", "更新说明"].enumerated() { tabs.setLabel(title, forSegment: i); tabs.setWidth(110, forSegment: i) }
        tabs.target = self; tabs.action = #selector(changeTab)
        let scroll = ocrTextScroll(text, editable: false); text.isRichText = true; text.textContainerInset = NSSize(width: 22, height: 18)
        let close = NSButton(title: "关闭", target: window, action: #selector(NSWindow.performClose(_:))); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        for view in [tabs, scroll, close] { view.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(view) }
        NSLayoutConstraint.activate([tabs.topAnchor.constraint(equalTo: host.topAnchor, constant: 16), tabs.centerXAnchor.constraint(equalTo: host.centerXAnchor), scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16), scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12), close.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16), close.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14)])
    }
    func show(tab: Int) { tabs.selectedSegment = max(0,min(1,tab-1)); changeTab(); window.center(); window.makeKeyAndOrderFront(nil) }
    @objc func changeTab() {
        let name = tabs.selectedSegment == 0 ? "UserGuide" : "ReleaseNotes"
        let content = Bundle.main.url(forResource:name,withExtension:"md").flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? "说明文件未找到，请重新安装完整应用。"
        let output = NSMutableAttributedString()
        for line in content.components(separatedBy: .newlines) {
            let heading = line.hasPrefix("#"), level = line.prefix { $0 == "#" }.count
            let value = heading ? String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces) : line
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = heading ? 12 : 6; paragraph.lineSpacing = 4
            let font: NSFont = heading ? .systemFont(ofSize: level == 1 ? 24 : (level == 2 ? 18 : 15), weight: .semibold) : .systemFont(ofSize: 14)
            output.append(NSAttributedString(string: value + "\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        text.textStorage?.setAttributedString(output); text.setSelectedRange(NSRange(location: 0, length: 0)); text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

/// Set a concrete bundle image after activation-policy setup as well as at launch.
enum AppIdentity {
    static func installIcon() {
        guard let url = Bundle.main.url(forResource:"AppIcon",withExtension:"icns"),let image = NSImage(contentsOf:url),image.isValid else { return }
        NSApplication.shared.applicationIconImage = image
        let tile = NSApplication.shared.dockTile
        let view = NSImageView(frame:NSRect(origin:.zero,size:tile.size)); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown; view.autoresizingMask = [.width,.height]
        tile.contentView = view; tile.display()
    }
}
