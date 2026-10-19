import AppKit
import VisionKit
import CoreImage

final class FlowToolbar: NSView {
    var groups: [NSView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; groups.forEach { addSubview($0) }; needsLayout = true } }
    var onHeight: ((CGFloat) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        var x: CGFloat = 12, y: CGFloat = 10, row: CGFloat = 30
        for group in groups {
            let natural = group.fittingSize
            let w = max(20, natural.width), h = max(28, natural.height)
            if x > 12, x + w > bounds.width - 12 { x = 12; y += row + 8; row = 30 }
            group.frame = NSRect(x: x, y: y, width: w, height: h)
            row = max(row, h); x += w + 18
        }
        onHeight?(y + row + 10)
    }
}

final class DropRootView: NSView {
    var onFiles: (([URL]) -> Void)?
    var onAppearance: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter { acceptsBookURL($0) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender); guard !files.isEmpty else { return false }; onFiles?(files); return true
    }
}

final class ReaderScrollView: NSScrollView {
    var continuous = false
    var wheelTurnsPages = true
    var onEdge: ((Int) -> Void)?
    private var lastFlip: TimeInterval = 0
    private var flippedInGesture = false
    private var accumulated: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) { flippedInGesture = false; accumulated = 0 }
        let vertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) && abs(event.scrollingDeltaY) > 0.1
        if !continuous, wheelTurnsPages, vertical {
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { accumulated = 0; return }
            if event.hasPreciseScrollingDeltas {
                guard !flippedInGesture else { return }
                if accumulated * event.scrollingDeltaY < 0 { accumulated = 0 }
                accumulated += event.scrollingDeltaY
                guard abs(accumulated) >= 40 else { return }
            }
            guard Date.timeIntervalSinceReferenceDate - lastFlip > 0.18 else { return }
            lastFlip = Date.timeIntervalSinceReferenceDate; accumulated = 0
            flippedInGesture = event.hasPreciseScrollingDeltas && !event.phase.isEmpty
            onEdge?(event.scrollingDeltaY < 0 ? 1 : -1); return
        }
        let before = contentView.bounds
        super.scrollWheel(with: event)
        guard !continuous, event.momentumPhase.isEmpty, vertical,
              abs(event.scrollingDeltaY) > 1, Date.timeIntervalSinceReferenceDate - lastFlip > 0.4,
              !flippedInGesture, let documentView else { return }
        let maxY = max(0, documentView.bounds.height - before.height)
        let next = event.scrollingDeltaY < 0
        let atEdge = next ? before.minY >= maxY - 2 : before.minY <= 2
        if atEdge { lastFlip = Date.timeIntervalSinceReferenceDate; flippedInGesture = event.hasPreciseScrollingDeltas; onEdge?(next ? 1 : -1) }
    }
}

final class PageDocumentView: NSView {
    var onDoubleClick: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick?(event) }
    }
    var frames: [Int: CGRect] = [:] { didSet { needsDisplay = true } }
    var errors: [Int: String] = [:] { didSet { needsDisplay = true } }
    var message = "打开电子书，或拖入书籍文件／PDG 文件夹" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        if frames.isEmpty {
            let text = NSAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.secondaryLabelColor])
            let size = text.size(); text.draw(at: CGPoint(x: max(20, (bounds.width - size.width) / 2), y: max(30, (bounds.height - size.height) / 2)))
        }
        for (index, rect) in frames where rect.intersects(dirtyRect) {
            NSColor.windowBackgroundColor.setFill(); rect.fill()
            let text = errors[index] ?? "正在读取第 \(index + 1) 页…"
            (text as NSString).draw(in: rect.insetBy(dx: 16, dy: 28), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

final class PageTile: NSView, ImageAnalysisOverlayViewDelegate {
    let imageView = NSImageView()
    let overlay = ImageAnalysisOverlayView(frame: .zero)
    var onDoubleClick: ((NSEvent) -> Void)?
    private var dragPoint: CGPoint?
    private var dragOrigin = CGPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: NSImage) {
        super.init(frame: .zero)
        imageView.image = image; imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView); addSubview(overlay)
        overlay.delegate = self; overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .textSelection
        overlay.isSupplementaryInterfaceHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() {
        super.layout(); imageView.frame = bounds; overlay.frame = bounds; overlay.setContentsRectNeedsUpdate()
    }
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }
    func contentView(for overlayView: ImageAnalysisOverlayView) -> NSView? { imageView }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !NSEvent.modifierFlags.contains(.option), overlay.analysis != nil,
           overlay.hasInteractiveItem(at: overlay.convert(local, from: self)) { return super.hitTest(point) }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick?(event); return }
        dragPoint = event.locationInWindow; dragOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragPoint, let scroll = enclosingScrollView else { return }
        let now = event.locationInWindow
        let point = CGPoint(x: dragOrigin.x - now.x + dragPoint.x, y: dragOrigin.y + now.y - dragPoint.y)
        var rect = scroll.contentView.bounds; rect.origin = point
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(rect).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func mouseUp(with event: NSEvent) { if dragPoint != nil { NSCursor.pop() }; dragPoint = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

enum PageImageFactory {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func prepare(_ image: CGImage, rotation: Int, crop: Double, invert: Bool) throws -> CGImage {
        var result = image
        if crop > 0 {
            let rect = CGRect(x: Double(image.width) * crop, y: Double(image.height) * crop,
                              width: Double(image.width) * (1 - 2 * crop), height: Double(image.height) * (1 - 2 * crop)).integral
            if let cropped = image.cropping(to: rect) { result = cropped }
        }
        if rotation % 4 != 0 {
            let w = rotation % 2 == 0 ? result.width : result.height, h = rotation % 2 == 0 ? result.height : result.width
            guard let target = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReaderFailure("页面旋转内存不足。") }
            target.setFillColor(CGColor(gray: 1, alpha: 1)); target.fill(CGRect(x: 0, y: 0, width: w, height: h))
            target.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            target.rotate(by: -CGFloat(rotation) * .pi / 2)
            target.draw(result, in: CGRect(x: -CGFloat(result.width) / 2, y: -CGFloat(result.height) / 2, width: CGFloat(result.width), height: CGFloat(result.height)))
            guard let rotated = target.makeImage() else { throw ReaderFailure("页面旋转失败。") }; result = rotated
        }
        if invert {
            let ci = CIImage(cgImage: result).applyingFilter("CIColorInvert")
            guard let inverted = context.createCGImage(ci, from: ci.extent) else { throw ReaderFailure("页面反色失败。") }; result = inverted
        }
        return result
    }
}
