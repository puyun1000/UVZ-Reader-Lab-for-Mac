import AppKit
import PDFKit

private final class CenteredPageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        if let frame = documentView?.frame {
            if bounds.width > frame.width { bounds.origin.x = frame.midX - bounds.width / 2 }
            if bounds.height > frame.height { bounds.origin.y = frame.midY - bounds.height / 2 }
        }
        return bounds
    }
}

final class BookProofCanvas: NSScrollView {
    private(set) var size = CGSize.zero
    private var fitted = true
    var hasPage: Bool { size.width > 0 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteredPageClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.002
        maxMagnification = 10
        borderType = .bezelBorder
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func show(_ image: CGImage?, vector: PDFPage? = nil) {
        let content: NSView
        if let vector {
            size = vector.orientedCropSize
            content = VectorPageView(page: vector, rotation: 0, crop: 0, invert: false)
        } else if let image {
            size = CGSize(width: image.width, height: image.height)
            let picture = PageProofImageView()
            picture.imageScaling = .scaleProportionallyUpOrDown
            picture.image = NSImage(cgImage: image, size: size)
            content = picture
        } else {
            size = .zero
            documentView = nil
            return
        }
        content.frame = NSRect(origin: .zero, size: size)
        documentView = content
        fitPage()
    }

    override func layout() {
        super.layout()
        if fitted { fitPage() }
    }

    func fitPage() {
        guard hasPage, size.height > 0, contentSize.width > 0, contentSize.height > 0 else { return }
        fitted = true
        let factor = min((contentSize.width - 2) / size.width, (contentSize.height - 2) / size.height)
        let target = min(maxMagnification, max(minMagnification, factor))
        if abs(magnification - target) > 0.00001 {
            setMagnification(target, centeredAt: CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }

    func zoom(_ factor: CGFloat) {
        guard hasPage else { return }
        fitted = false
        setMagnification(min(maxMagnification, max(minMagnification, magnification * factor)),
                         centeredAt: CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
    }
}

final class BatchBookPreview: NSStackView {
    let canvas = BookProofCanvas()
    let pageField = CenteredTextField()
    private let count = CenteredTextField(labelWithString: "/ —")
    private let status = CenteredTextField(labelWithString: "选择图书即可翻看全书")
    private let previewTitle = CenteredTextField(labelWithString: "图书预览")
    var titleVisible: Bool {
        get { !previewTitle.isHidden }
        set { previewTitle.isHidden = !newValue }
    }
    private let previous = NSButton(title: "上一页", target: nil, action: nil)
    private let next = NSButton(title: "下一页", target: nil, action: nil)
    private let queue = OperationQueue()
    private var generation = UUID()
    private var pendingPage: Int?
    private var source: NamingSource?
    private(set) var url: URL?
    private(set) var page = 0
    var pageCount: Int { source?.pageCount ?? 0 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let zoom = NSButton(title: "放大", target: self, action: #selector(zoomIn))
        let smaller = NSButton(title: "缩小", target: self, action: #selector(zoomOut))
        let fit = NSButton(title: "整页", target: self, action: #selector(fitPage))
        previous.target = self; previous.action = #selector(previousPage)
        next.target = self; next.action = #selector(nextPage)
        for button in [previous, next, zoom, smaller, fit] { button.bezelStyle = .rounded; button.controlSize = .small }
        pageField.target = self; pageField.action = #selector(jump)
        pageField.alignment = .center; pageField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        pageField.setAccessibilityLabel("预览物理页码")
        let toolbar = NSStackView(views: [previous, pageField, count, next, NSView(), smaller, zoom, fit])
        toolbar.spacing = 4
        previewTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        status.lineBreakMode = .byTruncatingMiddle
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        for view in [previewTitle, toolbar, canvas, status] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 138).isActive = true
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateNavigation()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func load(_ url: URL?, page requestedPage: Int = 0, refresh: Bool = false) {
        guard refresh || self.url != url else { return }
        self.url = url
        generation = UUID()
        queue.cancelAllOperations()
        source = nil
        pendingPage = requestedPage
        page = 0
        canvas.show(nil)
        updateNavigation()
        guard let url else { status.stringValue = "选择图书即可翻看全书"; return }
        status.stringValue = "正在打开预览…"
        let token = generation
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result { try NamingSource(url) }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let source):
                    self.source = source
                    self.showPage(min(max(self.pendingPage ?? 0, 0), source.pageCount - 1))
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
        queue.addOperation(operation)
    }

    func showPage(_ index: Int) {
        guard let source else { pendingPage = index; return }
        guard (0..<source.pageCount).contains(index) else { updateNavigation(); return }
        pendingPage = nil
        page = index
        updateNavigation()
        let token = UUID()
        generation = token
        queue.cancelAllOperations()
        canvas.show(nil)
        status.stringValue = "正在读取第 \(index + 1) 页…"
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result { () throws -> (CGImage?, PDFPage?, PDFDocument?) in
                if let vector = try source.vectorPage(at: index) { return (nil, vector, vector.document) }
                return (try source.image(at: index), nil, nil)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let (image, vector, document)):
                    withExtendedLifetime(document) { self.canvas.show(image, vector: vector) }
                    self.status.stringValue = source.pageName(at: index)
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
        queue.addOperation(operation)
    }

    private func updateNavigation() {
        pageField.stringValue = pageCount > 0 ? String(page + 1) : ""
        count.stringValue = pageCount > 0 ? "/ \(pageCount)" : "/ —"
        pageField.isEnabled = pageCount > 0
        previous.isEnabled = pageCount > 0 && page > 0
        next.isEnabled = page + 1 < pageCount
    }
    @objc private func previousPage() { showPage(page - 1) }
    @objc private func nextPage() { showPage(page + 1) }
    @objc private func jump() { if let value = Int(pageField.stringValue), value > 0 { showPage(value - 1) } else { updateNavigation() } }
    @objc private func zoomIn() { canvas.zoom(1.35) }
    @objc private func zoomOut() { canvas.zoom(1 / 1.35) }
    @objc private func fitPage() { canvas.fitPage() }
}

/// Shows pages from the editor's open snapshot, including vector PDF pages.
final class ContentsPagePreview: NSStackView {
    let canvas = BookProofCanvas()
    private let pageField = CenteredTextField()
    private let status = CenteredTextField(labelWithString: "")
    private let previous = NSButton(title: "上一页", target: nil, action: nil)
    private let next = NSButton(title: "下一页", target: nil, action: nil)
    private let queue = OperationQueue()
    private var generation = UUID()
    private var book: BookArchive
    private var origin = 0
    private(set) var page: Int?
    private(set) var isShowingVector = false

    init(book: BookArchive) {
        self.book = book
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 2, right: 12)
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let heading = CenteredTextField(labelWithString: "原页预览")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let reset = NSButton(title: "返回原页", target: self, action: #selector(resetPage))
        let fit = NSButton(title: "整页", target: self, action: #selector(fitPage))
        let zoom = NSButton(title: "放大", target: self, action: #selector(zoomIn))
        previous.target = self; previous.action = #selector(goPrevious)
        next.target = self; next.action = #selector(goNext)
        pageField.target = self; pageField.action = #selector(jump)
        pageField.alignment = .center
        pageField.setAccessibilityLabel("预览物理页码")
        pageField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        let title = NSStackView(views: [heading, NSView(), reset])
        let paging = NSStackView(views: [previous, pageField, next, NSView(), fit, zoom])
        paging.spacing = 4
        for button in [previous, next, reset, fit, zoom] { button.bezelStyle = .rounded; button.controlSize = .small }
        for view in [title, paging, canvas, status] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -12).isActive = true
        }
        canvas.setAccessibilityLabel("目录校对原页")
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init(coder: NSCoder) { fatalError("init(coder:)") }
    deinit { queue.cancelAllOperations() }

    func setSource(_ book: BookArchive, origin: Int) {
        queue.cancelAllOperations()
        self.book = book
        self.origin = min(max(origin, 0), book.pages.count - 1)
        page = nil
        showPage(self.origin)
    }

    func showPage(_ index: Int) {
        guard book.pages.indices.contains(index) else { status.stringValue = "物理页码应在 1—\(book.pages.count) 之间"; refreshNavigation(); return }
        if page == index, canvas.hasPage { status.stringValue = summary(index); return }
        page = index
        isShowingVector = false
        refreshNavigation()
        canvas.show(nil)
        status.stringValue = "正在读取物理第 \(index + 1) 页…"
        let source = book, token = UUID()
        generation = token
        queue.cancelAllOperations()
        queue.addOperation { [weak self] in
            let result = Result { () throws -> (CGImage?, PDFPage?, PDFDocument?) in
                if let vector = try source.vectorPage(at: index) { return (nil, vector, vector.document) }
                return (try source.pageImage(at: index), nil, nil)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let (raster, vector, document)):
                    withExtendedLifetime(document) { self.canvas.show(raster, vector: vector) }
                    self.isShowingVector = vector != nil
                    self.status.stringValue = self.summary(index)
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                }
                self.status.toolTip = self.status.stringValue
            }
        }
    }

    private func summary(_ index: Int) -> String {
        "\(book.pages[index].label) · 物理页 \(index + 1) / \(book.pages.count)"
    }
    private func refreshNavigation() {
        guard let page else { return }
        pageField.stringValue = String(page + 1)
        previous.isEnabled = page > 0
        next.isEnabled = page + 1 < book.pages.count
    }
    @objc private func resetPage() { showPage(origin) }
    @objc private func fitPage() { canvas.fitPage() }
    @objc private func zoomIn() { canvas.zoom(1.3) }
    @objc private func goPrevious() { if let page { showPage(page - 1) } }
    @objc private func goNext() { if let page { showPage(page + 1) } }
    @objc private func jump() {
        if let number = Int(pageField.stringValue), number > 0 { showPage(number - 1) }
        else { refreshNavigation() }
    }
}
