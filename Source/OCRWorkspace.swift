import AppKit
import Vision

/// Geometry is normalized to the displayed page, with its origin at the top left.
enum RegionGeometry {
    static func normalized(_ start: CGPoint, _ end: CGPoint, in image: CGRect) -> CGRect? {
        guard image.width > 0, image.height > 0 else { return nil }
        let a = CGPoint(x: min(image.maxX, max(image.minX, start.x)), y: min(image.maxY, max(image.minY, start.y)))
        let b = CGPoint(x: min(image.maxX, max(image.minX, end.x)), y: min(image.maxY, max(image.minY, end.y)))
        let rect = CGRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        return CGRect(x: (rect.minX-image.minX)/image.width, y: (rect.minY-image.minY)/image.height, width: rect.width/image.width, height: rect.height/image.height)
    }
    static func pixels(_ rect: CGRect, width: Int, height: Int) throws -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0, width > 0, height > 0 else { throw ReaderFailure("请先在页面上拖出识别范围。") }
        let clipped = rect.intersection(CGRect(x: 0,y: 0,width: 1,height: 1))
        guard !clipped.isNull else { throw ReaderFailure("框选范围不在页面内。") }
        let pixels = CGRect(x: clipped.minX*CGFloat(width), y: clipped.minY*CGFloat(height), width: clipped.width*CGFloat(width), height: clipped.height*CGFloat(height)).integral.intersection(CGRect(x: 0,y: 0,width: width,height: height))
        guard pixels.width >= 8, pixels.height >= 8 else { throw ReaderFailure("识别范围过小，请重新框选。") }
        return pixels
    }
    static func crop(_ image: CGImage, rect: CGRect) throws -> CGImage {
        let pixels = try pixels(rect, width: image.width, height: image.height)
        guard let cropped = image.cropping(to: pixels) else { throw ReaderFailure("无法读取框选图像，请重新框选。") }; return cropped
    }
}

func ocrTextScroll(_ text: NSTextView, editable: Bool, font: NSFont = .systemFont(ofSize: 14)) -> NSScrollView {
    text.setFrameSize(NSSize(width: 400,height: 600)); text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,height: CGFloat.greatestFiniteMagnitude)
    text.isRichText = false; text.isEditable = editable; text.isSelectable = true; text.allowsUndo = editable; text.font = font
    text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width: 400,height: CGFloat.greatestFiniteMagnitude)
    text.textContainerInset = NSSize(width: 12,height: 12)
    text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
    let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
    return scroll
}

/// Scrollable form whose natural height may exceed the adjacent OCR reference pane.
private final class OCRFormDocument: NSView { override var isFlipped: Bool { true } }
final class FormScrollView: NSScrollView {
    let column: NSStackView
    private let formDocument = OCRFormDocument(frame: NSRect(x: 0,y: 0,width: 500,height: 800))
    init(_ column: NSStackView) {
        self.column = column; super.init(frame: .zero)
        documentView = formDocument; hasVerticalScroller = true; autohidesScrollers = true; drawsBackground = false
        column.translatesAutoresizingMaskIntoConstraints = false; formDocument.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: formDocument.leadingAnchor,constant: 6),column.trailingAnchor.constraint(equalTo: formDocument.trailingAnchor,constant: -6),column.topAnchor.constraint(equalTo: formDocument.topAnchor,constant: 6)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() {
        super.layout()
        let width = max(200,contentSize.width)
        formDocument.setFrameSize(NSSize(width: width,height: formDocument.frame.height)); formDocument.layoutSubtreeIfNeeded()
        let height = max(contentSize.height,column.fittingSize.height+12)
        if abs(formDocument.frame.height-height)>0.5 { formDocument.setFrameSize(NSSize(width: width,height: height)) }
    }
}

final class OCRTextReview: NSObject, NSWindowDelegate {
    let window = ChineseWindow(contentRect: NSRect(x: 0,y: 0,width: 820,height: 720),styleMask: [.titled,.closable,.resizable,.miniaturizable],backing: .buffered,defer: false)
    let text = ChineseTextView()
    init(text value: String) {
        super.init(); window.title = "版权页识别原文 — 放大核对"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 480,height: 360); window.delegate = self
        let scroll = ocrTextScroll(text, editable: false); text.string = value
        let smaller = NSButton(title: "减小字号",target: self,action: #selector(smallerText)); smaller.bezelStyle = .rounded
        let larger = NSButton(title: "增大字号",target: self,action: #selector(largerText)); larger.bezelStyle = .rounded
        let tools = NSStackView(views: [CenteredTextField(labelWithString: "选择文字后可复制或转换；窗口可自由放大。"),TextConversion.button(for:text),NSView(),smaller,larger]); tools.spacing = 8
        let root = NSStackView(views: [tools,scroll]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        let host = NSView(); window.contentView = host; root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: host.leadingAnchor,constant: 16),root.trailingAnchor.constraint(equalTo: host.trailingAnchor,constant: -16),root.topAnchor.constraint(equalTo: host.topAnchor,constant: 16),root.bottomAnchor.constraint(equalTo: host.bottomAnchor,constant: -16),scroll.widthAnchor.constraint(equalTo: root.widthAnchor),tools.widthAnchor.constraint(equalTo: root.widthAnchor)])
    }
    @objc private func smallerText() { text.font = .systemFont(ofSize: max(10,(text.font?.pointSize ?? 14)-1)) }
    @objc private func largerText() { text.font = .systemFont(ofSize: min(30,(text.font?.pointSize ?? 14)+1)) }
    func show(above parent: NSWindow) { NativeDialog.present(window, on: parent) }
}

final class RegionCanvas: NSView {
    let imageView = NSImageView()
    private(set) var imageRect: CGRect = .zero
    var selection: CGRect? { didSet { needsDisplay = true; subviews.last?.needsDisplay = true } }
    var onSelected: (() -> Void)?
    private var anchor: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); imageView.imageScaling = .scaleAxesIndependently; addSubview(imageView) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func configure(_ image: CGImage, viewport: CGSize, zoom: Double) {
        let fit = min(max(80,viewport.width-32)/CGFloat(image.width),max(80,viewport.height-32)/CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width)*fit*zoom,height: CGFloat(image.height)*fit*zoom)
        setFrameSize(NSSize(width: max(viewport.width,size.width+32),height: max(viewport.height,size.height+32)))
        imageRect = CGRect(x: (bounds.width-size.width)/2,y: (bounds.height-size.height)/2,width: size.width,height: size.height)
        imageView.image = NSImage(cgImage: image,size: NSSize(width: image.width,height: image.height)); imageView.frame = imageRect; needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point,from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) { NSColor.underPageBackgroundColor.setFill(); bounds.fill() }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from: nil)
        guard imageRect.contains(point) else { return }; window?.makeFirstResponder(self); anchor = point; selection = nil
    }
    override func mouseDragged(with event: NSEvent) { if let anchor { selection = RegionGeometry.normalized(anchor,convert(event.locationInWindow,from: nil),in: imageRect) } }
    override func mouseUp(with event: NSEvent) {
        guard let anchor else { return }; selection = RegionGeometry.normalized(anchor,convert(event.locationInWindow,from: nil),in: imageRect); self.anchor = nil
        if selection != nil { onSelected?() }
    }
    override func resetCursorRects() { addCursorRect(imageRect,cursor: .crosshair) }
}

/// A separate overlay above the page image keeps the selection visible without intercepting input.
private final class RegionOutline: NSView {
    weak var canvas: RegionCanvas?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let selection = canvas.selection else { return }
        let image = canvas.imageRect, rect = CGRect(x: image.minX+selection.minX*image.width,y: image.minY+selection.minY*image.height,width: selection.width*image.width,height: selection.height*image.height)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill(); rect.fill()
        let path = NSBezierPath(rect: rect); path.lineWidth = 2; NSColor.controlAccentColor.setStroke(); path.stroke()
        for point in [CGPoint(x: rect.minX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.minY),CGPoint(x: rect.minX,y: rect.maxY),CGPoint(x: rect.maxX,y: rect.maxY)] { NSColor.controlAccentColor.setFill(); CGRect(x: point.x-3,y: point.y-3,width: 6,height: 6).fill() }
    }
}

final class RegionOCRController: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    let recognitionControls = RecognitionControls()
    let window = ChineseWindow(contentRect: NSRect(x: 0,y: 0,width: 1120,height: 770),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
    let canvas = RegionCanvas(frame: .zero)
    let resultText = ChineseTextView()
    let pageField = CenteredTextField()
    let splitOnImport = NSButton(checkboxWithTitle: "添加时分离末尾页码",target: nil,action: nil)
    let append = NSButton(checkboxWithTitle: "连续框选时追加结果",target: nil,action: nil)
    let split = NSSplitView()
    let imageScroll = NSScrollView()
    let placement = NSPopUpButton()
    private let zoom = NSSlider(value: 1,minValue: 1,maxValue: 4,target: nil,action: nil)
    private let status = CenteredTextField(wrappingLabelWithString: "在左侧页面拖出矩形，松开鼠标后识别。多栏目录请按列框选。")
    private let importButton = NSButton(title: "添加到目录",target: nil,action: nil)
    private let book: BookArchive
    private var page: Int
    private var rotation: Int
    private var image: CGImage?
    private let selectionOutline = RegionOutline(frame: .zero)
    private let queue = OperationQueue()
    private var token = UUID()
    private var closed = false
    private(set) var recognizing = false
    private(set) var loading = false
    var onImport: ((String,Bool) -> Void)?
    var onClosed: (() -> Void)?
    init(book: BookArchive,page: Int,rotation: Int = 0,allowCursor: Bool = true) {
        self.book = book; self.page = min(book.pages.count-1,max(0,page)); self.rotation = rotation
        super.init(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        window.title = "框选识别目录 — " + book.title; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 900,height: 620); window.delegate = self
        let previous = button("上一页",#selector(previousPage)), next = button("下一页",#selector(nextPage))
        pageField.integerValue = self.page+1; pageField.widthAnchor.constraint(equalToConstant: 52).isActive = true; pageField.target = self; pageField.action = #selector(pageEntered)
        zoom.widthAnchor.constraint(equalToConstant: 100).isActive = true; zoom.target = self; zoom.action = #selector(zoomChanged); zoom.isContinuous = true
        let tools = NSStackView(views: [previous,pageField,CenteredTextField(labelWithString: "/ \(book.pages.count)"),next,NSView(),CenteredTextField(labelWithString: "放大"),zoom,button("适合窗口",#selector(fitImage)),button("旋转",#selector(rotateImage))]); tools.spacing = 8
        imageScroll.documentView = canvas; imageScroll.hasVerticalScroller = true; imageScroll.hasHorizontalScroller = true; imageScroll.autohidesScrollers = true
        selectionOutline.canvas = canvas; canvas.addSubview(selectionOutline); selectionOutline.autoresizingMask = [.width,.height]
        canvas.onSelected = { [weak self] in self?.recognizeSelection() }
        let textScroll = ocrTextScroll(resultText,editable: true,font: .monospacedSystemFont(ofSize: 14,weight: .regular))
        append.state = .on; splitOnImport.state = .on
        let resultTools = NSStackView(views: [append,TextConversion.button(for:resultText),NSView(),button("分离末尾页码",#selector(splitNumbers)),button("清空",#selector(clearResult))]); resultTools.spacing = 6
        let right = NSStackView(views: [CenteredTextField(labelWithString: "识别结果（可编辑）"),textScroll,resultTools]); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        for view in [textScroll,resultTools] { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = self; split.addArrangedSubview(imageScroll); split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultLow,forSubviewAt: 0); split.setHoldingPriority(.defaultHigh,forSubviewAt: 1)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        placement.addItems(withTitles: allowCursor ? ["插入目录光标处","追加到目录末尾"] : ["追加到目录末尾"]); placement.tag = allowCursor ? 1 : 0
        importButton.target = self; importButton.action = #selector(importResult); importButton.bezelStyle = .rounded; importButton.isEnabled = true
        let close = button("取消",#selector(close)); close.keyEquivalent = "\u{1b}"
        let options = NSStackView(views: [splitOnImport,CenteredTextField(labelWithString: "选中结果中的部分文字时，仅添加选中内容；添加前可直接修改结果。")]); options.spacing = 12
        let footer = NSStackView(views: [button("识别所选区域",#selector(recognizeSelection)),NSView(),placement,close,importButton]); footer.spacing = 8
        let recognitionOptions = NSStackView(views:[CenteredTextField(labelWithString:"文字识别"),recognitionControls.language,recognitionControls.layout,NSView()]); recognitionOptions.spacing = 8
        let root = NSStackView(views: [tools,recognitionOptions,split,options,status,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        let host = NSView(); window.contentView = host; root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: host.leadingAnchor,constant: 16),root.trailingAnchor.constraint(equalTo: host.trailingAnchor,constant: -16),root.topAnchor.constraint(equalTo: host.topAnchor,constant: 16),root.bottomAnchor.constraint(equalTo: host.bottomAnchor,constant: -16)])
        for view in [tools,recognitionOptions,split,options,status,footer] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        NotificationCenter.default.addObserver(self,selector: #selector(viewportChanged),name: NSView.frameDidChangeNotification,object: imageScroll.contentView)
        imageScroll.contentView.postsFrameChangedNotifications = true
        loadPage()
    }
    deinit { NotificationCenter.default.removeObserver(self); queue.cancelAllOperations() }
    private func button(_ title: String,_ action: Selector) -> NSButton { let button = NSButton(title: title,target: self,action: action); button.bezelStyle = .rounded; return button }
    func show(on parent: NSWindow) {
        NativeDialog.present(window, on: parent); window.contentView?.layoutSubtreeIfNeeded(); split.setPosition(split.bounds.width*0.58,ofDividerAt: 0); viewportChanged()
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,ofSubviewAt dividerIndex: Int) -> CGFloat { 300 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width-360 }
    @objc func viewportChanged() {
        guard let image else { return }
        canvas.configure(image,viewport: imageScroll.contentSize,zoom: zoom.doubleValue); selectionOutline.frame = canvas.bounds; selectionOutline.needsDisplay = true
    }
    private func invalidate() { token = UUID(); queue.cancelAllOperations(); recognizing = false }
    private func loadPage() {
        invalidate(); importButton.isEnabled = true; loading = true; image = nil; canvas.selection = nil; canvas.imageView.image = nil; selectionOutline.needsDisplay = true
        pageField.integerValue = page+1; status.stringValue = "正在读取物理第 \(page+1) 页…"
        let current = token, source = book, index = page, rotation = rotation
        queue.addOperation { [weak self] in
            let result = Result { try PageImageFactory.prepare(source.pageImage(at: index),rotation: rotation,crop: 0,invert: false) }
            DispatchQueue.main.async {
                guard let self,!self.closed,self.token == current else { return }; self.loading = false
                switch result {
                case .success(let image): self.image = image; self.viewportChanged(); self.status.stringValue = "物理第 \(index+1) 页：拖动框选一列或一块文字，松开后识别；可以连续框选追加。"
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc private func previousPage() { guard page > 0 else { return }; page -= 1; loadPage() }
    @objc private func nextPage() { guard page+1 < book.pages.count else { return }; page += 1; loadPage() }
    @objc private func pageEntered() {
        guard (1...book.pages.count).contains(pageField.integerValue) else { pageField.integerValue = page+1; return }; page = pageField.integerValue-1; loadPage()
    }
    @objc private func zoomChanged() { viewportChanged() }
    @objc private func fitImage() { zoom.doubleValue = 1; viewportChanged() }
    @objc private func rotateImage() { rotation = (rotation+1)%4; loadPage() }
    @objc func recognizeSelection() {
        guard let image,let selection = canvas.selection else { status.stringValue = "请先在左侧页面拖出识别范围。"; return }
        selectionOutline.needsDisplay = true
        do {
            let cropped = try RegionGeometry.crop(image,rect: selection)
            invalidate(); recognizing = true; importButton.isEnabled = false
            let current = token, appendText = append.state == .on, originalText = resultText.string, options = recognitionControls.options
            status.stringValue = "正在识别框选区域（\(cropped.width) × \(cropped.height)）…"
            queue.addOperation { [weak self] in
                let result = Result { try ContentsRegionRecognizer.recognize(cropped,options:options) }
                DispatchQueue.main.async {
                    guard let self,!self.closed,self.token == current else { return }; self.recognizing = false; self.importButton.isEnabled = true
                    switch result {
                    case .success(let value):
                        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { self.status.stringValue = "该区域未识别到文字，请放大或重新框选。"; return }
                        let source = self.resultText.string as NSString
                        let shouldAppend = appendText || self.resultText.string != originalText
                        let insertion = shouldAppend ? NSRange(location: source.length,length: 0) : NSRange(location: 0,length: source.length)
                        self.resultText.breakUndoCoalescing()
                        self.resultText.insertText((shouldAppend && source.length > 0 ? "\n" : "")+text,replacementRange: insertion)
                        self.resultText.breakUndoCoalescing()
                        self.resultText.setSelectedRange(NSRange(location: (self.resultText.string as NSString).length,length: 0)); self.resultText.scrollRangeToVisible(self.resultText.selectedRange())
                        self.status.stringValue = "已识别 \(text.count) 字，可校正、分离页码，或继续框选下一列；添加后仍是目录草稿。"
                    case .failure(let error): self.status.stringValue = error.localizedDescription
                    }
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc func splitNumbers() {
        let source = resultText.string as NSString, selected = resultText.selectedRange()
        let range = selected.length > 0 ? source.lineRange(for: NSRange(location: selected.location,length: max(0,selected.length-1))) : NSRange(location: 0,length: source.length)
        resultText.insertText(ContentsOCRText.prepare(source.substring(with: range)),replacementRange: range); resultText.setSelectedRange(NSRange(location: (resultText.string as NSString).length,length: 0))
    }
    @objc private func clearResult() { invalidate(); resultText.insertText("",replacementRange: NSRange(location: 0,length: (resultText.string as NSString).length)); importButton.isEnabled = true; status.stringValue = "结果已清空，可重新框选。" }
    @objc func importResult() {
        guard !recognizing,!loading else { status.stringValue = "识别或页面读取尚未完成，请稍候。"; return }
        window.makeFirstResponder(nil)
        let selected = resultText.selectedRange(), source = resultText.string as NSString
        let value = (selected.length > 0 ? source.substring(with: selected) : resultText.string).trimmingCharacters(in: .newlines)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status.stringValue = "识别结果为空，请先框选或输入文字。"; return }
        let text = splitOnImport.state == .on ? ContentsOCRText.prepare(value) : value, atEnd = placement.tag == 0 || placement.indexOfSelectedItem == 1, callback = onImport
        close(); callback?(text,atEnd)
    }
    @objc func close() { guard !closed else { return }; closed = true; invalidate(); NativeDialog.dismiss(window); onClosed?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

/// Joins separately detected page numbers with their title on the same baseline.
enum ContentsRegionRecognizer {
    struct Line { let text: String; let box: CGRect }
    static func assemble(_ lines: [Line]) -> String {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let index = rows.firstIndex(where: { row in
                let box = row[0].box
                let overlap = min(box.maxY,line.box.maxY)-max(box.minY,line.box.minY)
                return overlap > min(box.height,line.box.height)*0.45 && abs(box.midY-line.box.midY)<max(box.height,line.box.height)*0.6
            }) { rows[index].append(line) } else { rows.append([line]) }
        }
        return rows.map { row in
            let fragments = row.sorted { $0.box.minX < $1.box.minX }
            return fragments.enumerated().map { index,line in
                if index == 0 { return line.text }
                let page = index == fragments.count-1 && line.text.range(of: "^(?:cov|bok|leg|fow|!|att|bac|@)?-?[0-9]+$",options: [.regularExpression,.caseInsensitive]) != nil
                return (page ? "\t" : " ")+line.text
            }.joined()
        }.joined(separator: "\n")
    }
    static func recognize(_ image: CGImage,options: RecognitionOptions = .saved) throws -> String {
        let lines = try TextRecognition.lines(image,options:options)
        if lines.contains(where: \.vertical) { return TextRecognition.ordered(lines).map(\.text).joined(separator:"\n") }
        return assemble(lines.map { Line(text:$0.text,box:$0.box) })
    }
}

/// OCR layout cleanup is explicit and reversible; hierarchy and uncertain page numbers remain for review.
enum ContentsOCRText {
    static func prepare(_ input: String) -> String {
        let text = input.replacingOccurrences(of: "\r\n",with: "\n").replacingOccurrences(of: "\r",with: "\n")
        let dots = try! NSRegularExpression(pattern: "[.．·•…⋯。＿_](?:[ \\t]*[.．·•…⋯。＿_])+[ \\t]*((?:cov|bok|leg|fow|!|att|bac|@)?-?[0-9]+)[ \\t]*$",options: .caseInsensitive)
        return ContentsTextCodec.splitTrailingNumbers(text.components(separatedBy: "\n").map { line in
            let joined = dots.stringByReplacingMatches(in: line,range: NSRange(location: 0,length: (line as NSString).length),withTemplate: "\t$1")
            return joined.replacingOccurrences(of: "[ \\t]*[/／][ \\t]*([0-9]+)[ \\t]*$",with: "\t$1",options: .regularExpression)
        }.joined(separator: "\n")).replacingOccurrences(of: "[ \u{00a0}]+\t",with: "\t",options: .regularExpression)
    }
    static func inserting(_ text: String,into source: String,at caret: Int) -> (String,NSRange) {
        let value = source as NSString, location = min(value.length,max(0,caret))
        // Insert between complete lines, keeping the current line and all existing text intact.
        let insertion: Int
        if location == 0 || location == value.length || value.substring(with: NSRange(location: location-1,length: 1)) == "\n" { insertion = location }
        else { insertion = NSMaxRange(value.lineRange(for: NSRange(location: location,length: 0))) }
        let prefix = insertion > 0 && value.substring(with: NSRange(location: insertion-1,length: 1)) != "\n" ? "\n" : ""
        let suffix = insertion < value.length ? "\n" : ""
        return (prefix+text+suffix,NSRange(location: insertion,length: 0))
    }
}
