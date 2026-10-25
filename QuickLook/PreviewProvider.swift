import AppKit
import QuickLookUI
import OSLog

final class PreviewCenteredClip: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        if let document = documentView {
            if document.frame.width<result.width {result.origin.x = -(result.width-document.frame.width)/2}
            if document.frame.height<result.height {result.origin.y = -(result.height-document.frame.height)/2}
        }
        return result
    }
}

final class PreviewPageImage: NSImageView {
    var navigate: ((Int) -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric) }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with:event) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123,126,116: navigate?(-1)
        case 124,125,121: navigate?(1)
        default: super.keyDown(with:event)
        }
    }
}

/// The system owns the window. Only the requested page is decoded, with a small image cache.
@objc(UVZPreviewProvider)
final class PreviewProvider: NSViewController,QLPreviewingController,NSTextFieldDelegate {
    let image = PreviewPageImage(), scroll = NSScrollView(), pageField = NSTextField(string:"1")
    let countLabel = NSTextField(labelWithString:""), status = NSTextField(labelWithString:"正在打开…")
    let previous = NSButton(title:"上一页",target:nil,action:nil), next = NSButton(title:"下一页",target:nil,action:nil)
    private let queue = OperationQueue(), cache = NSCache<NSNumber,NSImage>()
    private var generation = UUID(), pageGeneration = UUID()
    private(set) var book: BookArchive?
    private(set) var currentPage = 0
    private var followsWindow = true, fitting = false
    private var lastViewport = CGSize.zero
    private var initialReply: ((Error?) -> Void)?
    override func loadView() {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width:1440,height:1000)
        let size = NSSize(width:min(1200,max(640,screen.width*0.85)),height:min(1100,max(480,screen.height*0.88)))
        view = NSView(frame:NSRect(origin:.zero,size:size)); view.autoresizingMask = [.width,.height]
        NotificationCenter.default.addObserver(self,selector:#selector(manualMagnification),name:NSScrollView.willStartLiveMagnifyNotification,object:scroll)
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated; cache.countLimit = 3; cache.totalCostLimit = 64*1024*1024
        previous.target = self; previous.action = #selector(previousPage); next.target = self; next.action = #selector(nextPage)
        pageField.target = self; pageField.action = #selector(goToPage); pageField.delegate = self; pageField.alignment = .center; pageField.widthAnchor.constraint(equalToConstant:65).isActive = true
        func button(_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b }
        previous.bezelStyle = .rounded; next.bezelStyle = .rounded
        let toolbar = NSStackView(views:[previous,next,NSTextField(labelWithString:"物理页"),pageField,countLabel,NSView(),button("−",#selector(zoomOut)),button("＋",#selector(zoomIn)),button("适合整页",#selector(fitPage))]); toolbar.spacing = 8
        image.imageScaling = .scaleProportionallyUpOrDown; image.navigate = { [weak self] delta in self?.showPage((self?.currentPage ?? 0)+delta) }
        scroll.contentView = PreviewCenteredClip(); scroll.scrollerStyle = .overlay; scroll.documentView = image; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.allowsMagnification = true; scroll.minMagnification = 0.02; scroll.maxMagnification = 4; scroll.drawsBackground = true; scroll.backgroundColor = .underPageBackgroundColor
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        let root = NSStackView(views:[toolbar,scroll,status]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:12),root.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-12),root.topAnchor.constraint(equalTo:view.topAnchor,constant:12),root.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-12)])
        for v in [toolbar,scroll,status] { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100).isActive = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(viewportChanged),name:NSView.frameDidChangeNotification,object:scroll.contentView)
        updateNavigation()
    }
    func preparePreviewOfFile(at url: URL,completionHandler handler: @escaping (Error?) -> Void) {
        loadViewIfNeeded()
        // A host can reuse this controller. Resolve the prior request before replacing it.
        initialReply?(ReaderFailure("预览请求已更换。")); initialReply = handler
        generation = UUID(); pageGeneration = UUID(); queue.cancelAllOperations(); cache.removeAllObjects(); book = nil; image.image = nil; currentPage = 0; updateNavigation()
        let token = generation; status.stringValue = "正在读取图书…"
        queue.addOperation { [weak self] in
            let result = Result { () throws -> BookArchive in
                guard url.pathExtension.lowercased() == "uvz" else { throw ReaderFailure("此扩展用于UVZ图书预览。") }
                return try BookArchive(url:url)
            }
            DispatchQueue.main.async {
                guard let self,self.generation == token else { return }
                switch result {
                case .success(let book): self.book = book; self.showPage(0)
                case .failure(let error): self.status.stringValue = error.localizedDescription; let reply = self.initialReply; self.initialReply = nil; reply?(error)
                }
            }
        }
    }
    func showPage(_ index: Int) {
        guard let book,book.pages.indices.contains(index) else { return }
        currentPage = index; let token = UUID(), request = generation; pageGeneration = token; queue.cancelAllOperations(); image.image = nil; updateNavigation(); status.stringValue = "正在读取物理第\(index+1)页…"
        if let cached = cache.object(forKey:NSNumber(value:index)) { display(cached,book:book,index:index); return }
        queue.addOperation { [weak self] in
            let result = Result { try book.pageImage(at:index) }
            DispatchQueue.main.async {
                guard let self,self.generation == request,self.pageGeneration == token else { return }
                switch result {
                case .success(let cg):
                    let ns = NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height)); self.cache.setObject(ns,forKey:NSNumber(value:index),cost:cg.bytesPerRow*cg.height); self.display(ns,book:book,index:index)
                case .failure(let error):
                    self.status.stringValue = "第\(index+1)页无法显示："+error.localizedDescription
                    let reply = self.initialReply; self.initialReply = nil; reply?(nil) // Keep navigation usable if one page is corrupt.
                }
            }
        }
    }
    private func display(_ value: NSImage,book: BookArchive,index: Int) {
        image.image = value; image.frame = CGRect(origin:.zero,size:value.size); view.layoutSubtreeIfNeeded(); fitPage()
        status.stringValue = "\(book.pages[index].name) · 物理第\(index+1)页，共\(book.pages.count)页 · 方向键翻页，可输入页码跳转"
        Logger(subsystem:"local.uvzreaderlab.rebuild.quicklook",category:"preview").notice("UVZ paged preview ready: version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",privacy:.public), physical \(index+1,privacy:.public) of \(book.pages.count,privacy:.public)")
        let reply = initialReply; initialReply = nil; reply?(nil)
    }
    private func updateNavigation() {
        previous.isEnabled = book != nil && currentPage>0; next.isEnabled = book.map {currentPage+1<$0.pages.count} ?? false
        pageField.isEnabled = book != nil; pageField.integerValue = currentPage+1; countLabel.stringValue = book.map {"／ \($0.pages.count)"} ?? ""
    }
    @objc func previousPage() { showPage(currentPage-1) }
    @objc func nextPage() { showPage(currentPage+1) }
    @objc func goToPage() {
        guard let book,let number = Int(pageField.stringValue.trimmingCharacters(in:.whitespaces)),(1...book.pages.count).contains(number) else { pageField.integerValue = currentPage+1; status.stringValue = "请输入图书范围内的物理页码。"; return }
        showPage(number-1)
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let size = scroll.contentView.frame.size
        if size != lastViewport { lastViewport = size; if followsWindow { applyFit() } }
    }
    @objc private func viewportChanged() {
        let size = scroll.contentView.frame.size
        if size != lastViewport { lastViewport = size; if followsWindow { applyFit() } }
    }
    @objc private func manualMagnification() { if !fitting { followsWindow = false } }
    @objc func fitPage() { followsWindow = true; applyFit() }
    private func applyFit() {
        guard !fitting else { return }; fitting = true; defer { fitting = false }
        guard let size = image.image?.size,size.width>0,size.height>0 else { return }
        let available = scroll.contentView.frame.size
        scroll.setMagnification(max(scroll.minMagnification,min(available.width/size.width,available.height/size.height)),centeredAt:CGPoint(x:size.width/2,y:size.height/2))
    }
    @objc func zoomIn() { followsWindow = false; scroll.magnification = min(scroll.maxMagnification,scroll.magnification*1.4) }
    @objc func zoomOut() { followsWindow = false; scroll.magnification = max(scroll.minMagnification,scroll.magnification/1.4) }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(image) }
    deinit { NotificationCenter.default.removeObserver(self); queue.cancelAllOperations() }
}
