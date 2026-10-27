import AppKit
import CryptoKit
import VisionKit

final class ReaderController: NSResponder, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    let window = ChineseWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let document = PageDocumentView()
    let scroll = ReaderScrollView()
    let outline = NSOutlineView()
    private(set) var book: BookArchive?
    private(set) var requestedURL: URL?
    var state = ReadingState()
    var smokeMode = false
    var onConvert: (([URL])->Void)?
    var onOpenFiles: (([URL]) -> Void)?
    var onCloseWindow: ((ReaderController) -> Void)?
    var onBookChanged: (() -> Void)?
    private let emptyView = ReaderEmptyView(),emptyRecent = NSStackView()
    private let displayOptions = NSPopover()
    let defaultColorButton=NSButton(title:"设为默认",target:nil,action:nil)
    let fitWidthButton=NSButton(title:"宽度",target:nil,action:nil),fitHeightButton=NSButton(title:"高度",target:nil,action:nil),fitWholeButton=NSButton(title:"整页",target:nil,action:nil)
    private var bookBars: [NSView] = []
    private let root = DropRootView(frame: .zero)
    private let toolbar = FlowToolbar()
    private var toolbarHeight: NSLayoutConstraint!
    private let sidebar = NSStackView()
    let readingSplit=NSSplitView()
    private var sidebarWidth:NSLayoutConstraint!
    private var preferredSidebarWidth:CGFloat=260
    private let note = CenteredTextField(wrappingLabelWithString: "")
    private let status = CenteredTextField(labelWithString: "打开电子书，开始阅读")
    private let ocrStatus = CenteredTextField(labelWithString: "")
    let pageField = CenteredTextField(string: "1")
    let pageTypePopup = NSPopUpButton()
    private var physicalNavigation = false
    private var pageMap: PageAddressing?
    private let countLabel = CenteredTextField(labelWithString: "/ 0")
    private let modePopup = NSPopUpButton()
    private let coverButton = NSButton(checkboxWithTitle: "首页单独", target: nil, action: nil)
    private let layoutButtons = NSSegmentedControl()
    private let filenameLabel = CenteredTextField(labelWithString: "尚未打开书籍")
    private let renameButton = NSButton(title: "书籍信息与重命名…", target: nil, action: nil)
    private(set) var renameSheet: RenameSheet?
    private let rtlButton = NSButton(checkboxWithTitle: "从右至左", target: nil, action: nil)
    private let fitPopup = NSPopUpButton()
    private let colorPopup = NSPopUpButton()
    private let zoomSlider = NSSlider(value: 1, minValue: 0.25, maxValue: 4, target: nil, action: nil)
    private let zoomLabel = CenteredTextField(labelWithString: "100%")
    private let defaults = UserDefaults.standard
    private var stateKey = ""
    private(set) var onlineReferences: OnlineReferences?
    @objc func showOnlineReferences() {
        if let existing=onlineReferences {existing.show();return}
        let source=book,controller=OnlineReferences(ssid:book.map {FilenameDraft(book:$0).ss} ?? "");onlineReferences=controller
        if let source {controller.onDirectory = {[weak self] text in
            guard let self,self.book === source else{return false}
            if self.editor == nil {self.showBookEditor(info:false)}
            return self.editor?.insertReferenceContents(text) ?? false
        }}
        controller.onClosed = {[weak self] in self?.onlineReferences=nil};controller.show()
    }
    private(set) var editor: BookEditor?
    private(set) var pageRepair: PageRepairWindow?
    private let repairButton = NSButton(title:"页面编码校对…",target:nil,action:nil)
    private let auditButton = NSButton(title:"",target:nil,action:nil)
    private(set) var pageFindings: [PageFinding] = []
    private let inspectionQueue = OperationQueue()
    private var checkedMargins = Set<Int>()
    private var marginOperation: BlockOperation?
    private var marginIndex: Int?

    private(set) var regionOCR: RegionOCRController?
    private var reopenState: ReadingState?
    private var session = UUID()
    private var revision = 0
    private var layout = ReadingLayout()
    private var sizes: [CGSize] = []
    private var nodes: [NavigationNode] = []
    private(set) var tiles: [Int: PageTile] = [:]
    private var pending = Set<Int>()
    private var errors: [Int: String] = [:]
    private let queue = OperationQueue()
    private let rawCache = NSCache<NSNumber, NSImage>()
    private let preparedCache = NSCache<NSString, NSImage>()
    private let analysisCache = NSCache<NSString, ImageAnalysis>()
    private let analyzer = ImageAnalyzer()
    private var ocrTasks: [Int: Task<Void, Never>] = [:]
    private var ocrDelay: DispatchWorkItem?
    private var saveDelay: DispatchWorkItem?
    private var keyMonitor: Any?
    private var readingControls: [NSControl] = []
    private var layingOut = false
    private var selecting = false
    private var sidebarVisible = true
    var includePageNumbers = false
    var ocrEnabled = AppSettings().automaticOCR
    private var settingsObserver: NSObjectProtocol?
    var diagnosticStatus: String { status.stringValue + " | " + ocrStatus.stringValue }
    var hasRenderedImage: Bool { !tiles.isEmpty }
    var sidebarTitles: [String] { nodes.map(\.title) }

    override init() {
        super.init()
        settingsObserver = NotificationCenter.default.addObserver(forName: AppSettings.changed, object: nil, queue: .main) { [weak self] notification in
            guard let self, !self.smokeMode, notification.object as? String == "automaticOCR" else { return }
            let desired = AppSettings().automaticOCR
            if self.ocrEnabled != desired { self.toggleOCR() }
        }
        window.title = "UVZ Reader Lab"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        nextResponder = window.nextResponder
        window.nextResponder = self
        window.center()
        window.contentView = root
        root.onFiles = { [weak self] in self?.onOpenFiles?($0) }
        root.onAppearance = { [weak self] in self?.invalidateImages() }
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        rawCache.totalCostLimit = 48 * 1024 * 1024
        preparedCache.totalCostLimit = 80 * 1024 * 1024
        analysisCache.countLimit = 16
        includePageNumbers = defaults.bool(forKey: "showPageNumbersInContents")
        buildToolbar()
        buildSidebar()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        scroll.onEdge = { [weak self] direction in self?.step(direction) }
        document.onDoubleClick = { [weak self] event in self?.doubleClickPage(event) };document.onContextMenu = {[weak self] in self?.pageContextMenu()}
        renameButton.target = self; renameButton.action = #selector(renameZip); renameButton.bezelStyle = .rounded
        filenameLabel.lineBreakMode = .byTruncatingMiddle; filenameLabel.font = .systemFont(ofSize: 12); filenameLabel.isSelectable = true
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filenameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let region = button("框选识别…", #selector(recognizeRegion), symbol: "viewfinder"); region.toolTip = "框选一列或一块文字，识别后送入目录编辑"
        readingControls.append(region)
        repairButton.target = self; repairButton.action = #selector(repairPages); repairButton.bezelStyle = .rounded
        auditButton.target = self; auditButton.action = #selector(repairPages); auditButton.bezelStyle = .inline; auditButton.contentTintColor = .systemOrange; auditButton.isHidden = true
        readingControls.append(repairButton)
        inspectionQueue.maxConcurrentOperationCount = 1; inspectionQueue.qualityOfService = .utility
        renameButton.title="图书信息…";renameButton.image=NSImage(systemSymbolName:"info.circle",accessibilityDescription:"书籍信息与重命名");renameButton.imagePosition = .imageLeading
        repairButton.title="页面校对…"
        let filebar = NSStackView(views: [filenameLabel, repairButton, region, renameButton]); filebar.spacing = 10
        let body=readingSplit;body.isVertical=true;body.dividerStyle = .thin;body.delegate=self
        body.addArrangedSubview(sidebar);body.addArrangedSubview(scroll)
        body.setHoldingPriority(.init(rawValue:260),forSubviewAt:0);body.setHoldingPriority(.defaultLow,forSubviewAt:1)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        ocrStatus.font = .systemFont(ofSize: 11); ocrStatus.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [status, auditButton, NSView(), ocrStatus]); footer.spacing = 12
        for view in [toolbar, filebar, body, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: 88)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor), toolbarHeight,
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor), body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            filebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), filebar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            filebar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2), filebar.heightAnchor.constraint(equalToConstant: 30),
            body.topAnchor.constraint(equalTo: filebar.bottomAnchor, constant: 5), body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -7),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        bookBars=[toolbar,filebar,footer];buildEmptyState()
        toolbar.onHeight = { [weak self] height in
            guard let self, abs(self.toolbarHeight.constant - height) > 0.5 else { return }
            self.toolbarHeight.constant = height
        }
        NotificationCenter.default.addObserver(self, selector: #selector(viewportResized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
        root.layoutSubtreeIfNeeded();readingSplit.setPosition(preferredSidebarWidth,ofDividerAt:0)
        updateControls(); relayout(preservePosition: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        queue.cancelAllOperations(); ocrTasks.values.forEach { $0.cancel() }; ocrDelay?.cancel(); saveDelay?.cancel()
    }
    private func button(_ title: String, _ action: Selector, symbol: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); b.imagePosition = .imageLeading }
        return b
    }
    private func group(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views); stack.spacing = 6; stack.alignment = .centerY
        return stack
    }
    private func buildToolbar() {
        let open = button("打开", #selector(chooseBook), symbol: "folder")
        let close = button("关闭书籍", #selector(closeBook), symbol: "xmark")
        let previous = button("", #selector(previousPage), symbol: "chevron.left"); previous.toolTip = "上一页"
        let next = button("", #selector(nextPage), symbol: "chevron.right"); next.toolTip = "下一页"
        previous.setAccessibilityLabel("上一页"); next.setAccessibilityLabel("下一页")
        previous.widthAnchor.constraint(equalToConstant: 30).isActive = true; next.widthAnchor.constraint(equalToConstant: 30).isActive = true
        pageField.alignment = .center; pageField.target = self; pageField.action = #selector(pageEntered)
        pageField.widthAnchor.constraint(equalToConstant: 54).isActive = true
        countLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        pageTypePopup.addItem(withTitle: "页面类型"); pageTypePopup.target = self; pageTypePopup.action = #selector(pageTypeChanged)
        pageTypePopup.setAccessibilityLabel("跳转页面类型"); pageField.setAccessibilityLabel("所选类型的页号")
        pageField.toolTip = "输入所选类型的页号；也可输入 @加物理页码"
        pageTypePopup.widthAnchor.constraint(equalToConstant: 95).isActive = true
        modePopup.addItems(withTitles: ["单页视图", "单页连续", "双页视图", "双页连续"]); modePopup.target = self; modePopup.action = #selector(modeChanged)
        coverButton.target = self; coverButton.action = #selector(coverChanged)
        coverButton.toolTip = "双页时第 1 页单独显示，从第 2 页开始配对；也适用于双页连续"
        layoutButtons.segmentCount = 4; layoutButtons.trackingMode = .selectOne; layoutButtons.target = self; layoutButtons.action = #selector(layoutQuickChanged)
        for index in 0..<4 {
            layoutButtons.setImage(PageLayoutIcon.image(mode: index), forSegment: index)
            layoutButtons.setToolTip(modePopup.itemTitles[index], forSegment: index); layoutButtons.setWidth(32, forSegment: index)
        }
        layoutButtons.setAccessibilityLabel("页面显示方式")
        rtlButton.target = self; rtlButton.action = #selector(directionChanged)
        fitPopup.addItems(withTitles: ["适合宽度", "适合整页", "适合高度", "原始大小"]); fitPopup.target = self; fitPopup.action = #selector(fitChanged)
        colorPopup.addItems(withTitles: ["跟随系统", "原色", "反色"]); colorPopup.target = self; colorPopup.action = #selector(colorChanged)
        zoomSlider.target = self; zoomSlider.action = #selector(zoomChanged); zoomSlider.isContinuous = false
        zoomSlider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        zoomLabel.widthAnchor.constraint(equalToConstant: 43).isActive = true; zoomLabel.alignment = .right
        let whole = button("", #selector(fitWhole), symbol: "doc.viewfinder"); whole.toolTip = "适合整页"; whole.setAccessibilityLabel("适合整页"); whole.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let width = button("", #selector(fitWidth), symbol: "arrow.left.and.right"); width.toolTip = "适合宽度"; width.setAccessibilityLabel("适合宽度"); width.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let options=button("图像调整",#selector(showDisplayOptions),symbol:"slider.horizontal.3")
        let conversion=button("转换",#selector(convertCurrent),symbol:"doc.badge.arrow.up")
        let contents=button("",#selector(toggleSidebar),symbol:"sidebar.left");contents.toolTip="显示或隐藏目录";contents.setAccessibilityLabel("显示或隐藏目录")
        let smaller=button("",#selector(smallerZoom),symbol:"minus.magnifyingglass"),larger=button("",#selector(largerZoom),symbol:"plus.magnifyingglass")
        smaller.setAccessibilityLabel("缩小页面");larger.setAccessibilityLabel("放大页面")
        for (button,title,action,symbol) in [(fitWidthButton,"适合宽度",#selector(fitWidth),"arrow.left.and.right"),(fitHeightButton,"适合高度",#selector(fitHeight),"arrow.up.and.down"),(fitWholeButton,"适合整页",#selector(fitWhole),"doc.viewfinder")] {button.target=self;button.action=action;button.bezelStyle = .rounded;button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:title);button.imagePosition = .imageLeading;button.toolTip=title;button.setAccessibilityLabel(title);button.setButtonType(.toggle)}
        defaultColorButton.target=self;defaultColorButton.action = #selector(setDefaultPageColor);defaultColorButton.bezelStyle = .rounded;defaultColorButton.toolTip="将当前配色记为默认，后续打开图书使用此配色"
        toolbar.groups = [group([contents,open,close]),group([previous,pageTypePopup,pageField,countLabel,next]),group([layoutButtons]),group([fitWidthButton,fitHeightButton,fitWholeButton]),group([smaller,zoomLabel,larger]),group([coverButton,rtlButton]),group([colorPopup,defaultColorButton]),group([options,conversion])]
        readingControls = [close,previous,next,pageTypePopup,pageField,modePopup,layoutButtons,coverButton,rtlButton,fitPopup,colorPopup,zoomSlider,whole,width,smaller,larger,options,fitWidthButton,fitHeightButton,fitWholeButton,defaultColorButton]
        let rotate=button("旋转90°",#selector(rotatePage),symbol:"rotate.right"),cropMore=button("增加裁边",#selector(cropMore)),cropLess=button("减小裁边",#selector(cropLess))
        readingControls += [rotate,cropMore,cropLess]
        let title=CenteredTextField(labelWithString:"阅读显示");title.font = .systemFont(ofSize:15,weight:.semibold)
        let box=NSStackView(views:[title,group([zoomSlider,zoomLabelCopy()]),group([rotate,cropMore,cropLess])]);box.orientation = .vertical;box.alignment = .leading;box.spacing=14;box.edgeInsets = .init(top:18,left:18,bottom:18,right:18)
        let host=NSViewController();host.view=box;displayOptions.contentViewController=host;displayOptions.behavior = .transient
    }
    private func zoomLabelCopy()->NSTextField {let text=CenteredTextField(labelWithString:"缩放比例");text.font = .systemFont(ofSize:11);text.textColor = .secondaryLabelColor;return text}
    @objc private func showDisplayOptions(_ sender:NSButton) {displayOptions.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY)}
    @objc private func cropMore() {state.crop=min(0.15,state.crop+0.01);invalidateImages();relayout(preservePosition:true);save()}
    @objc private func cropLess() {state.crop=max(0,state.crop-0.01);invalidateImages();relayout(preservePosition:true);save()}
    @objc private func smallerZoom() {state.zoom=max(0.25,state.zoom/1.25);applyGeometryOptions()}
    @objc private func largerZoom() {state.zoom=min(4,state.zoom*1.25);applyGeometryOptions()}
    @objc func convertCurrent() {onConvert?(book.map {[$0.url]} ?? [])}
    private func buildEmptyState() {
        let icon=NSImageView();icon.image=NSImage(systemSymbolName:"books.vertical",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:42,weight:.light));icon.widthAnchor.constraint(equalToConstant:58).isActive=true;icon.contentTintColor = .secondaryLabelColor;icon.imageScaling = .scaleProportionallyUpOrDown;icon.heightAnchor.constraint(equalToConstant:58).isActive=true
        let title=CenteredTextField(labelWithString:"阅读与整理你的图书");title.font = .systemFont(ofSize:24,weight:.semibold);title.alignment = .center
        let subtitle=CenteredTextField(wrappingLabelWithString:"打开或拖入电子书开始阅读，也可以批量转换为PDF。\n支持UVZ、ZIP、PDG、PDF、DjVu和多页TIFF。")
        subtitle.alignment = .center;subtitle.font = .systemFont(ofSize:13);subtitle.textColor = .secondaryLabelColor
        let open=button("打开图书…",#selector(chooseBook),symbol:"folder"),convert=button("转换工作台…",#selector(convertCurrent),symbol:"doc.badge.arrow.up")
        let actions=group([open,convert]);emptyRecent.orientation = .vertical;emptyRecent.alignment = .centerX;emptyRecent.spacing=8
        let stack=NSStackView(views:[icon,title,subtitle,actions,emptyRecent]);stack.orientation = .vertical;stack.alignment = .centerX;stack.spacing=18;stack.translatesAutoresizingMaskIntoConstraints=false
        emptyView.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(emptyView);emptyView.addSubview(stack)
        NSLayoutConstraint.activate([emptyView.leadingAnchor.constraint(equalTo:root.leadingAnchor),emptyView.trailingAnchor.constraint(equalTo:root.trailingAnchor),emptyView.topAnchor.constraint(equalTo:root.topAnchor),emptyView.bottomAnchor.constraint(equalTo:root.bottomAnchor),stack.centerXAnchor.constraint(equalTo:emptyView.centerXAnchor),stack.centerYAnchor.constraint(equalTo:emptyView.centerYAnchor),stack.widthAnchor.constraint(equalToConstant:600),subtitle.widthAnchor.constraint(equalTo:stack.widthAnchor)])
    }
    @objc private func openRecentEmpty(_ sender:NSButton) {if let path=sender.toolTip {onOpenFiles?([URL(fileURLWithPath:path)])}}

    private func buildSidebar() {
        let title = CenteredTextField(labelWithString: "目录"); title.font = .systemFont(ofSize: 13, weight: .semibold)
        let options = NSPopUpButton(frame: .zero, pullsDown: true)
        options.addItem(withTitle: "目录选项")
        for (text, action) in [("显示页码作为目录项", #selector(togglePageNumbers)), ("全部展开", #selector(expandContents)), ("全部折叠", #selector(collapseContents))] {
            let item = NSMenuItem(title: text, action: action, keyEquivalent: ""); item.target = self; options.menu?.addItem(item)
        }
        let edit = button("编辑目录…", #selector(editBook))
        let header = NSStackView(views: [title, NSView(), edit, options]); header.spacing = 4
        let column = NSTableColumn(identifier: .init("contents")); outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.rowHeight = 30; outline.indentationPerLevel = 14
        outline.dataSource = self; outline.delegate = self; outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let list = NSScrollView(); list.documentView = outline; list.hasVerticalScroller = true; list.autohidesScrollers = true
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 8; sidebar.edgeInsets = .init(top: 8, left: 10, bottom: 8, right: 10)
        for view in [header, note, list] { sidebar.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20).isActive = true }
        let background=NSVisualEffectView();background.material = .sidebar;background.blendingMode = .withinWindow;background.state = .active;background.translatesAutoresizingMaskIntoConstraints=false
        sidebar.addSubview(background,positioned:.below,relativeTo:nil)
        NSLayoutConstraint.activate([background.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor),background.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor),background.topAnchor.constraint(equalTo:sidebar.topAnchor),background.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor)])
        sidebarWidth = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant:180);sidebarWidth.isActive=true
        let stored=UserDefaults.standard.double(forKey:"reading.sidebarWidth")
        preferredSidebarWidth=stored.isFinite && stored>=180 ? min(700,stored) : 260
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    }
    func open(_ url: URL, preserving savedState: ReadingState? = nil) {
        resetBookSession(clearSession: false)
        reopenState = savedState
        requestedURL = url.standardizedFileURL
        let token = session
        status.stringValue = "正在读取书籍…"; document.message = "正在建立页面与目录索引…"
        queue.addOperation { [weak self] in
            let result = Result { try BookArchive(url: url) }
            DispatchQueue.main.async {
                guard let self, self.session == token else { return }
                switch result {
                case .failure(let error):
                    self.requestedURL = nil; self.document.message = error.localizedDescription; self.status.stringValue = "无法打开电子书"
                    if !self.smokeMode { NativeDialog.alert(NSAlert(error: error), on: self.window) }
                case .success(let book):
                    self.book = book; self.pageMap = PageAddressing(book)
                    self.pageTypePopup.removeAllItems()
                    for group in (0..<PageAddressing.titles.count) where !self.pageMap!.pages(in:group).isEmpty {
                        self.pageTypePopup.addItem(withTitle:PageAddressing.titles[group]); self.pageTypePopup.lastItem?.tag = group
                    }
                    self.pageTypePopup.addItem(withTitle:"物理页"); self.pageTypePopup.lastItem?.tag = -1
                    self.stateKey = "book:" + SHA256.hash(data: Data(book.url.path.utf8)).map { String(format: "%02x", $0) }.joined()
                    self.state = self.reopenState ?? (self.smokeMode ? ReadingState() : (AppSettings().rememberPosition ? self.defaults.data(forKey: self.stateKey).flatMap { try? JSONDecoder().decode(ReadingState.self, from: $0) } : nil) ?? AppSettings().readingState)
                    if !self.smokeMode {self.state.color=AppSettings().pageColor}
                    self.reopenState = nil; self.save()
                    self.state.page = min(self.state.page, book.pages.count - 1)
                    self.sizes = Array(repeating: CGSize(width: 1200, height: 1800), count: book.pages.count)
                    self.window.title = book.title + " — UVZ Reader Lab"; self.window.representedURL = book.url
                    self.rebuildNavigation(); self.updateControls(); self.relayout(preservePosition: false)
                    self.window.makeFirstResponder(self.document)
                    if !self.smokeMode { NSDocumentController.shared.noteNewRecentDocumentURL(book.url) }
                    self.startPageInspection(); self.onBookChanged?()
                }
            }
        }
    }
    @objc func editBook() { showBookEditor(info: false) }
    @objc func editInfo() { renameZip() }
    private func showBookEditor(info: Bool) {
        guard let book, !window.hasDocumentDialog else { return }
        let sheet = BookEditor(book: book); editor = sheet
        sheet.currentPage = state.page
        sheet.onSaved = { [weak self] backups in
            guard let self else { return }
            let saved = self.state; self.open(book.url, preserving: saved)
            if !backups.isEmpty { self.status.stringValue = "已保存，原文件备份：" + backups.map(\.lastPathComponent).joined(separator: "、") }
        }
        sheet.onPageRepaired = { [weak self] updated,map in
            guard let self else { return }; var saved = self.state; saved.page = map[saved.page] ?? 0
            self.open(updated.url,preserving:saved)
        }
        sheet.onClosed = { [weak self] in self?.editor = nil; self?.updateControls() }
        NativeDialog.present(sheet.window, on: window); updateControls()
    }
    @objc func repairPages() {
        guard let book,book.canCorrectPages,!window.hasDocumentDialog else { return }
        let controller = PageRepairWindow(book:book,current:state.page,findings:pageFindings); pageRepair = controller
        controller.onApplied = { [weak self] updated,map in
            guard let self else { return }; var saved = self.state; saved.page = map[saved.page] ?? 0
            self.open(updated.url,preserving:saved)
        }
        controller.onClosed = { [weak self] in self?.pageRepair = nil; self?.updateControls() }
        controller.show(on:window); updateControls()
    }
    private func updatePageFindings() {
        auditButton.title = "页面校对：\(pageFindings.count) 条提示"
        auditButton.toolTip = pageFindings.map(\.text).joined(separator:"\n")
        auditButton.isHidden = pageFindings.isEmpty || book?.canCorrectPages != true
    }
    private func startPageInspection() {
        guard let book,book.canCorrectPages else { return }
        pageFindings = PageInspection.structural(book); updatePageFindings()
        guard !smokeMode,!pageFindings.isEmpty else { return }
        let token = session, operation = BlockOperation()
        operation.addExecutionBlock { [weak self,weak operation,book] in
            let findings = try? PageInspection.scan(book,limit:32,cancelled:{ operation?.isCancelled != false })
            DispatchQueue.main.async { guard let self,self.session == token,let findings else { return }; self.pageFindings += findings.filter { item in !self.pageFindings.contains(where:{ $0.id == item.id }) }; self.updatePageFindings() }
        }; inspectionQueue.addOperation(operation)
    }
    private func checkPageMargin(_ index: Int, image: NSImage) {
        guard !smokeMode,let book,book.canCorrectPages,book.pages[index].key.group == 5,!checkedMargins.contains(index),let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return }
        if let previous = marginOperation,!previous.isFinished {
            previous.cancel(); if let marginIndex { checkedMargins.remove(marginIndex) }
        }
        checkedMargins.insert(index); let token = session, operation = BlockOperation()
        marginOperation = operation; marginIndex = index
        operation.addExecutionBlock { [weak self,weak operation,book] in
            guard operation?.isCancelled == false else { return }
            let findings = (try? PageInspection.currentPage(book,index:index,image:cg)) ?? []
            DispatchQueue.main.async { guard let self,self.session == token,operation?.isCancelled == false else { return }; self.pageFindings += findings.filter { item in !self.pageFindings.contains(where:{ $0.id == item.id }) }; self.updatePageFindings() }
        }; inspectionQueue.addOperation(operation)
    }
    @objc func recognizeRegion() {
        guard let book, !window.hasDocumentDialog else { return }
        let controller = RegionOCRController(book: book,page: state.page,rotation: state.rotation,allowCursor: false); regionOCR = controller
        controller.onClosed = { [weak self] in self?.regionOCR = nil; self?.updateControls() }
        controller.onImport = { [weak self] text, _ in
            guard let self, self.book === book else { return }
            self.showBookEditor(info: false); self.editor?.insertRecognizedContents(text,atEnd: true)
        }
        controller.show(on: window); updateControls()
    }
    func performRename(stem: String, metadata: [String: String]? = nil, preserveDates: Bool = true) throws {
        guard let book else { return }
        let newURL = try book.updateInformation(stem: stem, metadata: metadata, backup: AppSettings().backups, preserveDates: preserveDates)
        save(); let saved = state
        open(newURL, preserving: saved)
    }
    @objc func renameZip() {
        guard let book, !window.hasDocumentDialog else { return }
        let sheet = RenameSheet(book: book); renameSheet = sheet; sheet.currentPage = state.page
        for index in book.pages.indices where book.pages[index].key.group == 2 || index == state.page {
            if let cached = analysisCache.object(forKey: analysisKey(index)) { sheet.cachedCopyrightText[index] = cached.transcript }
        }
        sheet.onRename = { [weak self] name, metadata, preserve in try self?.performRename(stem: name, metadata: metadata, preserveDates: preserve) }
        sheet.onClose = { [weak self] in self?.renameSheet = nil; self?.updateControls() }
        NativeDialog.present(sheet.window, on: window); sheet.prepareForDisplay(); updateControls()
    }
    @objc func chooseBook() { onOpenFiles?([]) }
    @objc func closeBook() { guard !window.hasDocumentDialog else { window.bringDocumentDialogForward(); return }; resetBookSession(clearSession: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if window.hasDocumentDialog { window.bringDocumentDialogForward(); return false }; return true }
    private func resetBookSession(clearSession: Bool) {
        save(); saveDelay?.cancel(); ocrDelay?.cancel(); ocrTasks.values.forEach { $0.cancel() }; ocrTasks.removeAll()
        session = UUID(); revision += 1; inspectionQueue.cancelAllOperations(); checkedMargins.removeAll(); pageFindings.removeAll(); updatePageFindings(); queue.cancelAllOperations(); pending.removeAll()
        tiles.values.forEach { $0.removeFromSuperview() }; tiles.removeAll(); errors.removeAll()
        rawCache.removeAllObjects(); preparedCache.removeAllObjects(); analysisCache.removeAllObjects()
        book = nil; pageMap = nil; physicalNavigation = false; pageTypePopup.removeAllItems(); pageTypePopup.addItem(withTitle:"页面类型"); requestedURL = nil; stateKey = ""; sizes = []; nodes = []; state = ReadingState()
        document.frames = [:]; document.errors = [:]; document.message = "打开电子书，或拖入书籍文件／PDG 文件夹"
        outline.reloadData(); note.stringValue = "暂无打开的书籍"; status.stringValue = "打开电子书，开始阅读"; ocrStatus.stringValue = ""
        window.title = "UVZ Reader Lab"; window.representedURL = nil
        updateControls(); relayout(preservePosition: false)
        if clearSession { onBookChanged?() }
    }
    func windowWillClose(_ notification: Notification) {
        onlineReferences?.close()
        save(); session = UUID(); queue.cancelAllOperations(); ocrTasks.values.forEach { $0.cancel() }; ocrDelay?.cancel(); saveDelay?.cancel()
        onCloseWindow?(self)
    }
    @objc func save() {
        guard !smokeMode, AppSettings().rememberPosition, !stateKey.isEmpty else { return }
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }
    private func scheduleSave() {
        saveDelay?.cancel(); let job = DispatchWorkItem { [weak self] in self?.save() }; saveDelay = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: job)
    }
    func jump(_ index: Int, fraction: Double = 0) {
        guard let book else { return }
        state.page = min(max(0, index), book.pages.count - 1); state.fraction = fraction
        if state.continuous { scrollToState(); refreshVisible() } else { relayout(preservePosition: false) }
        updateControls(); selectNavigation(); scheduleSave()
    }
    func step(_ direction: Int) {
        guard let book else { return }
        jump(ReadingLayout.destination(from: state.page, direction: direction, count: book.pages.count, state: state))
    }
    func doubleClickPage(_ event: NSEvent) {
        guard book != nil, !window.hasDocumentDialog else { return }
        let point = scroll.contentView.convert(event.locationInWindow, from: nil)
        let towardRight = point.x >= scroll.contentView.bounds.midX
        step(towardRight == !state.rightToLeft ? 1 : -1)
    }
    @objc func previousPage() { step(-1) }
    @objc func nextPage() { step(1) }
    @objc func firstPage() { jump(0) }
    @objc func lastPage() { if let book { jump(book.pages.count - 1) } }
    @objc func pageTypeChanged() {
        guard let map = pageMap, let group = pageTypePopup.selectedItem?.tag else { return }
        physicalNavigation = group == -1
        if group == -1 { updateControls() }
        else if let first = map.pages(in:group).first { jump(first) }
        window.makeFirstResponder(pageField)
    }
    @objc func pageEntered() {
        guard let map = pageMap else { return }
        let group = pageTypePopup.selectedItem?.tag ?? -1, typed = pageField.stringValue
        do {
            let token = group == -1 && !typed.hasPrefix("@") ? "@" + typed : typed
            let physical = try map.resolve(token,defaultGroup:group)
            jump(physical - 1); window.makeFirstResponder(scroll)
        } catch {
            status.stringValue = error.localizedDescription; pageField.toolTip = error.localizedDescription
            window.makeFirstResponder(pageField); pageField.selectText(nil)
        }
    }
    @objc func modeChanged() { setDisplayMode(modePopup.indexOfSelectedItem) }
    @objc func layoutQuickChanged() { setDisplayMode(layoutButtons.selectedSegment) }
    func setDisplayMode(_ index: Int) { state.continuous = index % 2 == 1; state.doublePages = index >= 2; applyGeometryOptions() }
    @objc func singlePageMode() { setDisplayMode(0) }
    @objc func singleContinuousMode() { setDisplayMode(1) }
    @objc func twoPageMode() { setDisplayMode(2) }
    @objc func twoContinuousMode() { setDisplayMode(3) }
    @objc func coverChanged() { state.coverAlone = coverButton.state == .on; applyGeometryOptions() }
    @objc func toggleCoverAlone() { state.coverAlone.toggle(); applyGeometryOptions() }
    @objc func toggleWheelPaging() { state.wheelTurnsPages.toggle(); updateControls(); save() }
    @objc func directionChanged() { state.rightToLeft = rtlButton.state == .on; applyGeometryOptions() }
    @objc func fitChanged() { state.fit = fitPopup.indexOfSelectedItem; state.zoom = 1; applyGeometryOptions() }
    @objc func zoomChanged() { state.zoom = zoomSlider.doubleValue; applyGeometryOptions() }
    @objc func zoomIn() { state.zoom = min(4, state.zoom * 1.2); applyGeometryOptions() }
    @objc func zoomOut() { state.zoom = max(0.25, state.zoom / 1.2); applyGeometryOptions() }
    @objc func setDefaultPageColor() {AppSettings().set(state.color,"color");updateControls();status.stringValue="默认页面配色已保存，后续打开图书时生效。"}
    @objc func colorChanged() { state.color = colorPopup.indexOfSelectedItem; invalidateImages(); updateControls(); save() }
    @objc func toggleContinuous() { state.continuous.toggle(); applyGeometryOptions() }
    @objc func toggleDoublePages() { state.doublePages.toggle(); applyGeometryOptions() }
    @objc func toggleDirection() { state.rightToLeft.toggle(); applyGeometryOptions() }
    @objc func fitWidth() { state.fit = 0; state.zoom = 1; applyGeometryOptions() }
    @objc func fitWhole() { state.fit = 1; state.zoom = 1; applyGeometryOptions() }
    @objc func fitHeight() { state.fit = 2; state.zoom = 1; applyGeometryOptions() }
    @objc func actualSize() { state.fit = 3; state.zoom = 1; applyGeometryOptions() }
    @objc func systemColor() { state.color = 0; colorChangedFromMenu() }
    @objc func originalColor() { state.color = 1; colorChangedFromMenu() }
    @objc func invertedColor() { state.color = 2; colorChangedFromMenu() }
    private func colorChangedFromMenu() { updateControls(); invalidateImages(); save() }
    @objc func rotatePage() { state.rotation = (state.rotation + 1) % 4; invalidateImages(); relayout(preservePosition: true); save() }
    @objc func setCrop() {
        let alert = NSAlert(); alert.messageText = "四边裁边"; alert.informativeText = "对当前书籍统一设置，只影响显示。"
        let slider = NSSlider(value: state.crop * 100, minValue: 0, maxValue: 15, target: nil, action: nil)
        slider.frame = NSRect(x: 0, y: 0, width: 280, height: 28); slider.numberOfTickMarks = 16; slider.allowsTickMarkValuesOnly = true
        alert.accessoryView = slider; alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        NativeDialog.alert(alert, on: window) { response in
            if response == .alertFirstButtonReturn { self.state.crop = slider.doubleValue / 100; self.invalidateImages(); self.relayout(preservePosition: true); self.save() }
        }
    }
    @objc func resetAppearance() { state.rotation = 0; state.crop = 0; invalidateImages(); relayout(preservePosition: true); save() }
    @objc func toggleSidebar() {
        if sidebarVisible {preferredSidebarWidth=sidebar.frame.width}
        sidebarVisible.toggle();sidebarWidth.isActive=sidebarVisible;sidebar.isHidden = !sidebarVisible
        readingSplit.adjustSubviews();root.layoutSubtreeIfNeeded()
        if sidebarVisible {readingSplit.setPosition(min(preferredSidebarWidth,max(180,readingSplit.bounds.width-320)),ofDividerAt:0)}
        relayout(preservePosition:true)
    }
    func splitView(_ splitView:NSSplitView,constrainMinCoordinate proposed:CGFloat,ofSubviewAt index:Int) -> CGFloat {180}
    func splitView(_ splitView:NSSplitView,constrainMaxCoordinate proposed:CGFloat,ofSubviewAt index:Int) -> CGFloat {min(700,max(180,splitView.bounds.width-320))}
    func splitView(_ splitView:NSSplitView,shouldHideDividerAt index:Int) -> Bool {!sidebarVisible}
    func splitViewDidResizeSubviews(_ notification:Notification) {
        guard sidebarVisible,sidebar.frame.width>=180 else {return}
        if let type=NSApp.currentEvent?.type,type == .leftMouseDragged || type == .leftMouseUp {
            preferredSidebarWidth=min(700,sidebar.frame.width)
            UserDefaults.standard.set(Double(preferredSidebarWidth),forKey:"reading.sidebarWidth")
        }
        if !layingOut {relayout(preservePosition:true)}
    }
    @objc func togglePageNumbers() {
        includePageNumbers.toggle(); if !smokeMode { defaults.set(includePageNumbers, forKey: "showPageNumbersInContents") }
        rebuildNavigation()
    }
    @objc func expandContents() { outline.expandItem(nil, expandChildren: true) }
    @objc func collapseContents() { outline.collapseItem(nil, collapseChildren: true) }
    @objc func toggleOCR() {
        ocrEnabled.toggle(); ocrDelay?.cancel(); ocrTasks.values.forEach { $0.cancel() }; ocrTasks.removeAll()
        tiles.values.forEach { $0.overlay.analysis = nil }
        ocrStatus.stringValue = ocrEnabled ? "页面停留后自动识别文字" : "自动文字选取已关闭"
        if ocrEnabled { scheduleRecognition() }
    }
    private func applyGeometryOptions() { updateControls(); relayout(preservePosition: true); save() }
    private func updateControls() {
        let empty=book == nil && requestedURL == nil
        emptyView.isHidden = !empty;bookBars.forEach {$0.isHidden=empty}
        if empty {
            emptyRecent.arrangedSubviews.forEach {emptyRecent.removeArrangedSubview($0);$0.removeFromSuperview()}
            let recent=NSDocumentController.shared.recentDocumentURLs.filter {FileManager.default.fileExists(atPath:$0.path)}.prefix(3)
            if !recent.isEmpty {let title=CenteredTextField(labelWithString:"最近阅读");title.font = .systemFont(ofSize:12,weight:.semibold);title.textColor = .secondaryLabelColor;emptyRecent.addArrangedSubview(title)}
            for url in recent {let b=button(url.deletingPathExtension().lastPathComponent,#selector(openRecentEmpty),symbol:"book.closed");b.toolTip=url.path;b.cell?.lineBreakMode = .byTruncatingMiddle;b.widthAnchor.constraint(lessThanOrEqualToConstant:580).isActive=true;emptyRecent.addArrangedSubview(b)}
        }

        readingControls.forEach { $0.isEnabled = book != nil }
        if let book, let map = pageMap {
            let group = physicalNavigation ? -1 : book.pages[state.page].key.group
            pageTypePopup.selectItem(withTag:group)
            pageField.stringValue = String(map.number(at:state.page,group:group))
            countLabel.stringValue = " / " + map.range(in:group)
            countLabel.toolTip = "该类型页号范围：\(map.rangeDescription(in:group))；物理位置 \(state.page+1) / \(book.pages.count)"
        } else { pageField.stringValue = "0"; countLabel.stringValue = "/ 0" }
        pageField.isEnabled = book != nil
        let mode = (state.doublePages ? 2 : 0) + (state.continuous ? 1 : 0)
        modePopup.selectItem(at: mode); layoutButtons.selectedSegment = mode
        coverButton.state = state.coverAlone ? .on : .off; coverButton.isEnabled = book != nil && state.doublePages
        rtlButton.state = state.rightToLeft ? .on : .off
        repairButton.isEnabled = book?.canCorrectPages == true && !window.hasDocumentDialog; auditButton.isEnabled = repairButton.isEnabled
        renameButton.isEnabled = book != nil
        filenameLabel.stringValue = book?.url.lastPathComponent ?? "尚未打开书籍"; filenameLabel.toolTip = book?.url.path
        fitPopup.selectItem(at: state.fit); colorPopup.selectItem(at: state.color)
        for (index,title) in ["跟随系统","原色","反色"].enumerated() {colorPopup.item(at:index)?.title=title+(index == AppSettings().pageColor ? " · 默认" : "")}
        fitWidthButton.state=state.fit == 0 ? .on : .off;fitHeightButton.state=state.fit == 2 ? .on : .off;fitWholeButton.state=state.fit == 1 ? .on : .off
        defaultColorButton.isEnabled=book != nil && state.color != AppSettings().pageColor
        zoomSlider.doubleValue = state.zoom; zoomLabel.stringValue = "\(Int((state.zoom * 100).rounded()))%"
        outline.isEnabled = !window.hasDocumentDialog
        if window.hasDocumentDialog { readingControls.forEach { $0.isEnabled = false }; renameButton.isEnabled = false }
        scroll.continuous = state.continuous; scroll.wheelTurnsPages = state.wheelTurnsPages
        if let book { status.stringValue = "\(book.pages[state.page].name) · \(book.pages[state.page].label) · \(state.page + 1) / \(book.pages.count)" }
    }
    private var inverted: Bool { state.color == 2 || (state.color == 0 && document.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) }
    private func imageKey(_ index: Int) -> NSString { "\(index):\(state.rotation):\(state.crop):\(inverted)" as NSString }
    private func analysisKey(_ index: Int) -> NSString { "\(index):\(state.rotation):\(state.crop)" as NSString }
    private func invalidateImages() {
        revision += 1; queue.cancelAllOperations(); pending.removeAll(); errors.removeAll()
        ocrDelay?.cancel(); ocrTasks.values.forEach { $0.cancel() }; ocrTasks.removeAll()
        tiles.values.forEach { $0.removeFromSuperview() }; tiles.removeAll(); document.errors = [:]
        refreshVisible()
    }
    @objc private func viewportResized() { if !layingOut { relayout(preservePosition: true) } }
    @objc private func viewportScrolled() {
        guard !layingOut else { return }
        if state.continuous, let index = layout.page(at: scroll.contentView.bounds.minY) {
            if index != state.page { state.page = index; updateControls(); selectNavigation() }
        }
        state.fraction = layout.fraction(page: state.page, y: scroll.contentView.bounds.minY)
        refreshVisible(); scheduleSave()
    }
    private func relayout(preservePosition: Bool) {
        guard !layingOut else { return }; layingOut = true
        if preservePosition { state.fraction = layout.fraction(page: state.page, y: scroll.contentView.bounds.minY) }
        layout = ReadingLayout.make(sizes: sizes, viewport: scroll.contentSize, state: state)
        document.setFrameSize(layout.size); document.frames = layout.frames
        for (index, tile) in tiles { if let rect = layout.frames[index] { tile.frame = rect } }
        scrollToState(); layingOut = false; refreshVisible(); selectNavigation()
    }
    private func scrollToState() {
        guard let rect = layout.frames[state.page] else { return }
        let anchor = layout.anchor(for: state.page) ?? rect
        let y = anchor.minY + CGFloat(state.fraction) * anchor.height
        let desired = CGRect(origin: CGPoint(x: max(0, rect.midX - scroll.contentSize.width / 2), y: max(0, y)), size: scroll.contentSize)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(desired).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func refreshVisible() {
        guard let book else { return }
        let visible = scroll.contentView.bounds
        let nearby = visible.insetBy(dx: 0, dy: -visible.height * 0.5)
        let wanted = Set(layout.frames.filter { $0.value.intersects(nearby) }.sorted { abs($0.value.midY - visible.midY) < abs($1.value.midY - visible.midY) }.prefix(8).map(\.key))
        for index in Array(tiles.keys) where !wanted.contains(index) { tiles.removeValue(forKey: index)?.removeFromSuperview(); ocrTasks.removeValue(forKey: index)?.cancel() }
        for index in wanted where tiles[index] == nil && errors[index] == nil {
            if let image = preparedCache.object(forKey: imageKey(index)) { install(image, at: index); continue }
            guard !pending.contains(index) else { continue }; pending.insert(index)
            let token = session, epoch = revision, key = imageKey(index), rotation = state.rotation, crop = state.crop, invert = inverted
            queue.addOperation { [weak self] in
                guard let self else { return }
                let result = Result { () throws -> (NSImage, NSImage) in
                    let raw: NSImage
                    if let cached = self.rawCache.object(forKey: NSNumber(value: index)) { raw = cached }
                    else { let cg = try book.pageImage(at: index); raw = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)) }
                    guard let cg = raw.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ReaderFailure("页面图像不可用。") }
                    let prepared = try PageImageFactory.prepare(cg, rotation: rotation, crop: crop, invert: invert)
                    return (raw, NSImage(cgImage: prepared, size: CGSize(width: prepared.width, height: prepared.height)))
                }
                DispatchQueue.main.async {
                    guard self.session == token, self.revision == epoch else { return }
                    self.pending.remove(index)
                    switch result {
                    case .success(let (raw, prepared)):
                        self.rawCache.setObject(raw, forKey: NSNumber(value: index), cost: Int(raw.size.width * raw.size.height * 4))
                        self.preparedCache.setObject(prepared, forKey: key, cost: Int(prepared.size.width * prepared.size.height * 4))
                        if self.sizes[index] != raw.size { self.sizes[index] = raw.size; self.relayout(preservePosition: true) }
                        if self.layout.frames[index]?.intersects(self.scroll.contentView.bounds.insetBy(dx: 0, dy: -self.scroll.contentSize.height * 0.5)) == true { self.install(prepared, at: index) }
                    case .failure(let error):
                        self.errors[index] = error.localizedDescription; self.document.errors = self.errors
                        if index == self.state.page { self.status.stringValue = "第 \(index + 1) 页无法显示：\(error.localizedDescription) · 可继续翻页" }
                    }
                }
            }
        }
        if let image = rawCache.object(forKey:NSNumber(value:state.page)) { checkPageMargin(state.page,image:image) }
        scheduleRecognition()
    }
    private func install(_ image: NSImage, at index: Int) {
        guard let frame = layout.frames[index] else { return }
        if let tile = tiles[index] { tile.frame = frame; return }
        let tile = PageTile(image: image)
        tile.onContextMenu = {[weak self] in self?.pageContextMenu(index:index)};tile.onDoubleClick = { [weak self] event in self?.doubleClickPage(event) }; tile.frame = frame
        document.addSubview(tile); tiles[index] = tile
        if ocrEnabled, let analysis = analysisCache.object(forKey: analysisKey(index)) { tile.overlay.analysis = analysis }
        if index == state.page, let raw = rawCache.object(forKey:NSNumber(value:index)) { checkPageMargin(index,image:raw) }
        scheduleRecognition()
    }
    private func scheduleRecognition() {
        guard ocrEnabled, !smokeMode, book != nil else { return }
        ocrDelay?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recognizeVisible() }; ocrDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func recognizeVisible() {
        guard ocrEnabled, ImageAnalyzer.isSupported else { ocrStatus.stringValue = "此设备暂不支持自动文字选取"; return }
        let visible = scroll.contentView.bounds
        let indices = tiles.keys.filter { layout.frames[$0]?.intersects(visible) == true }.sorted { abs((layout.frames[$0]?.midY ?? 0) - visible.midY) < abs((layout.frames[$1]?.midY ?? 0) - visible.midY) }
        for index in indices.prefix(2) {
            let key = analysisKey(index)
            if let cached = analysisCache.object(forKey: key) { tiles[index]?.overlay.analysis = cached; ocrStatus.stringValue = cached.hasResults(for: .text) ? "文字可选取、复制" : "此页未识别到文字"; continue }
            guard ocrTasks[index] == nil, let displayed = tiles[index]?.imageView.image,
                  let cg = displayed.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let token = session, epoch = revision, undoInversion = inverted
            ocrStatus.stringValue = "正在自动识别文字…"
            ocrTasks[index] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if self.session == token && self.revision == epoch { self.ocrTasks.removeValue(forKey: index) } }
                do {
                    let image = try PageImageFactory.prepare(cg, rotation: 0, crop: 0, invert: undoInversion)
                    var config = ImageAnalyzer.Configuration(.text)
                    let supported = Set(ImageAnalyzer.supportedTextRecognitionLanguages)
                    config.locales = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"].compactMap { preferred in supported.first { $0.hasPrefix(preferred) } }
                    let analysis = try await self.analyzer.analyze(image, orientation: .up, configuration: config)
                    guard !Task.isCancelled, self.session == token, self.revision == epoch else { return }
                    self.analysisCache.setObject(analysis, forKey: key); self.tiles[index]?.overlay.analysis = analysis
                    if self.smokeMode { print("OCR_ANALYSIS characters=\(analysis.transcript.count)") }
                    self.ocrStatus.stringValue = analysis.hasResults(for: .text) ? "文字可选取、复制 · Option 拖动可移动页面" : "此页未识别到文字"
                } catch {
                    if self.smokeMode { fputs("OCR_ERROR \(error)\n", stderr) }
                    if !Task.isCancelled, self.session == token, self.revision == epoch { self.ocrStatus.stringValue = "文字识别未完成，可继续阅读" }
                }
            }
        }
    }
    private func rebuildNavigation() {
        selecting = true
        nodes = book.map { navigationNodes(for: $0, includePages: includePageNumbers) } ?? []
        outline.reloadData(); outline.expandItem(nil, expandChildren: false)
        note.stringValue = book?.contentsNotice ?? (book?.chapters.isEmpty == false ? "电子目录 · \(book?.chapters.count ?? 0) 项" : book == nil ? "暂无打开的书籍" : "未附有效电子目录，显示基础信息")
        selecting = false; selectNavigation()
    }
    private func selectNavigation() {
        func flattened(_ nodes: [NavigationNode]) -> [NavigationNode] { nodes.flatMap { [$0] + flattened($0.children) } }
        var candidate: NavigationNode?
        if let book, book.chapters.isEmpty, !includePageNumbers {
            let group = book.pages[state.page].key.group
            candidate = nodes.first { $0.page.map { book.pages[$0].key.group == group } ?? false }
        } else {
            candidate = flattened(nodes).filter { ($0.page ?? Int.max) <= state.page }.max { ($0.page ?? -1) < ($1.page ?? -1) }
        }
        while let current = candidate, outline.row(forItem: current) < 0 { candidate = current.parent }
        selecting = true
        if let candidate { let row = outline.row(forItem: candidate); if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row) } }
        else { outline.deselectAll(nil) }
        selecting = false
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? NavigationNode)?.children.count ?? nodes.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? NavigationNode)?.children ?? nodes)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! NavigationNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! NavigationNode
        let cell = CenteredTextField(labelWithString: node.title); cell.font = .systemFont(ofSize: 12); cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = node.page.map { "\(node.title) · 第 \($0 + 1) 页" } ?? node.title
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? NavigationNode, let page = node.page else { return }
        jump(page)
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard book != nil, !window.hasDocumentDialog, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(window.firstResponder is NSTextView), !tiles.values.contains(where: { $0.overlay.hasActiveTextSelection }) else { return false }
        switch event.keyCode {
        case 123: step(state.rightToLeft ? 1 : -1)
        case 124: step(state.rightToLeft ? -1 : 1)
        case 115: firstPage()
        case 119: lastPage()
        case 49, 116, 121:
            let direction = event.keyCode == 116 || event.modifierFlags.contains(.shift) ? -1 : 1
            let bounds = scroll.contentView.bounds, maxY = max(0, document.bounds.height - bounds.height)
            let target = min(maxY, max(0, bounds.minY + CGFloat(direction) * bounds.height * 0.85))
            if abs(target - bounds.minY) < 1, !state.continuous { step(direction) }
            else { scroll.contentView.scroll(to: CGPoint(x: bounds.minX, y: target)); scroll.reflectScrolledClipView(scroll.contentView) }
        default: return false
        }
        return true
    }
    func pageContextMenu(index:Int?=nil)->NSMenu {
        let menu=NSMenu(title:"阅读操作")
        func add(_ title:String,_ action:Selector) {let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;item.tag=index ?? state.page;menu.addItem(item)}
        add("上一页",#selector(previousPage));add("下一页",#selector(nextPage));menu.addItem(.separator())
        add("适合宽度",#selector(fitWidth));add("适合高度",#selector(fitHeight));add("适合整页",#selector(fitWhole));add("原始大小",#selector(actualSize));menu.addItem(.separator())
        add("复制页面图像",#selector(copyContextPage));add("框选识别目录…",#selector(recognizeContextRegion));menu.addItem(.separator())
        add("编辑目录…",#selector(editBook));add("书籍信息与重命名…",#selector(editInfo));add("复制图书路径",#selector(copyBookPath));return menu
    }
    @objc private func copyContextPage(_ item:NSMenuItem) {if let image=tiles[item.tag]?.imageView.image {NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects([image])}}
    @objc private func recognizeContextRegion(_ item:NSMenuItem) {jump(item.tag);recognizeRegion()}
    @objc private func copyBookPath() {if let book {NSPasteboard.general.clearContents();NSPasteboard.general.setString(book.url.path,forType:.string)}}
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showOnlineReferences): return !window.hasDocumentDialog
        case #selector(repairPages): return book?.canCorrectPages == true && !window.hasDocumentDialog
        case #selector(editBook): return book != nil && !window.hasDocumentDialog
        case #selector(renameZip), #selector(editInfo): return book != nil && !window.hasDocumentDialog
        case #selector(togglePageNumbers): item.state = includePageNumbers ? .on : .off
        case #selector(toggleContinuous): item.state = state.continuous ? .on : .off
        case #selector(toggleDoublePages): item.state = state.doublePages ? .on : .off
        case #selector(toggleCoverAlone): item.state = state.coverAlone ? .on : .off; return book != nil && state.doublePages
        case #selector(toggleWheelPaging): item.state = state.wheelTurnsPages ? .on : .off
        case #selector(singlePageMode): item.state = !state.doublePages && !state.continuous ? .on : .off
        case #selector(singleContinuousMode): item.state = !state.doublePages && state.continuous ? .on : .off
        case #selector(twoPageMode): item.state = state.doublePages && !state.continuous ? .on : .off
        case #selector(twoContinuousMode): item.state = state.doublePages && state.continuous ? .on : .off
        case #selector(toggleDirection): item.state = state.rightToLeft ? .on : .off
        case #selector(toggleSidebar): item.state = sidebarVisible ? .on : .off; return true
        case #selector(recognizeRegion): return book != nil && !window.hasDocumentDialog
        case #selector(toggleOCR): item.state = ocrEnabled ? .on : .off
        case #selector(systemColor): item.state = state.color == 0 ? .on : .off
        case #selector(originalColor): item.state = state.color == 1 ? .on : .off
        case #selector(invertedColor): item.state = state.color == 2 ? .on : .off
        default: break
        }
        return item.action == #selector(chooseBook) || (book != nil && !window.hasDocumentDialog)
    }

    func setTestOptions(continuous: Bool = false, doublePages: Bool = false, rtl: Bool = false, color: Int = 1, rotation: Int = 0, crop: Double = 0, coverAlone: Bool = false) {
        state.continuous = continuous; state.doublePages = doublePages; state.rightToLeft = rtl; state.color = color; state.rotation = rotation; state.crop = crop
        state.coverAlone = coverAlone; state.fit = 1; invalidateImages(); applyGeometryOptions()
    }
    var renderedPageIndices: [Int] { tiles.keys.sorted() }
    var currentFrames: [Int: CGRect] { layout.frames }
    var recognizedText: String { tiles[state.page]?.overlay.analysis?.transcript ?? "" }
    func checkTextSelection() -> Bool {
        guard let overlay = tiles[state.page]?.overlay else { return false }
        let text = overlay.text
        guard !text.isEmpty else { return false }
        let end = text.index(text.startIndex, offsetBy: min(10, text.count))
        overlay.selectedRanges = [text.startIndex..<end]
        let selected = !overlay.selectedText.isEmpty
        overlay.resetSelection()
        return selected
    }
    func checkDisplayControls() -> Bool {
        for mode in 0..<4 {
            modePopup.selectItem(at: mode); modePopup.sendAction(#selector(modeChanged), to: self)
            guard state.doublePages == (mode >= 2), state.continuous == (mode % 2 == 1), layoutButtons.selectedSegment == mode else { return false }
        }
        for mode in (0..<4).reversed() {
            layoutButtons.selectedSegment = mode; layoutButtons.sendAction(#selector(layoutQuickChanged), to: self)
            guard modePopup.indexOfSelectedItem == mode else { return false }
        }
        setTestOptions(doublePages: true, rtl: true, coverAlone: true); jump(0)
        guard Set(currentFrames.keys) == [0] else { return false }
        nextPage()
        guard state.page == 1, Set(currentFrames.keys) == [1, 2], currentFrames[1]!.minX > currentFrames[2]!.minX else { return false }
        previousPage(); guard state.page == 0 else { return false }
        setDisplayMode(3)
        guard currentFrames[0]!.maxY < currentFrames[1]!.minY, currentFrames[1]!.minY == currentFrames[2]!.minY else { return false }
        guard renameButton.isEnabled, filenameLabel.stringValue == book?.url.lastPathComponent else { return false }
        setTestOptions(); jump(1); return true
    }
    func checkDoubleClickInput() -> Bool {
        func click(right: Bool) -> Bool {
            let bounds = scroll.contentView.bounds
            let point = scroll.contentView.convert(CGPoint(x: bounds.minX + bounds.width * (right ? 0.75 : 0.25), y: bounds.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1) else { return false }
            document.mouseDown(with: event); return true
        }
        jump(1)
        guard click(right: true), state.page == 2, click(right: false), state.page == 1 else { return false }
        toggleDirection()
        guard click(right: true), state.page == 0, click(right: false), state.page == 1 else { return false }
        toggleDirection(); return true
    }
    func sendTestWheel(_ direction: Int) -> Bool {
        let before = state.page
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(-direction * 3), wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg) else { return false }
        scroll.scrollWheel(with: event)
        return state.page == before + direction
    }
    func checkReadingInputs() -> Bool {
        guard let book, book.pages.count > state.page + 1 else { return false }
        window.makeFirstResponder(document)
        let start = state.page
        func key(_ code: UInt16) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return false }
            return handleKey(event)
        }
        guard key(124), state.page == start + 1, key(123), state.page == start else { return false }
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg) {
            scroll.scrollWheel(with: event)
            guard state.page == start + 1 else { return false }
            jump(start)
        } else { return false }
        return true
    }
}
