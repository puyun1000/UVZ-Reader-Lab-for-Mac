import AppKit
import PDFKit

final class NamingSourceWindow: NSObject, NSWindowDelegate {
    let window = ChineseWindow(contentRect:NSRect(x:0,y:0,width:1080,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    let chooser = NSPopUpButton(), image = PageProofImageView(), text = ChineseTextView()
    let imageScroll = NSScrollView()
    let pdfView=PDFView()
    private var automaticFit=true
    private let url: URL, proposal: NamingProposal
    private let queue = OperationQueue()
    private var generation = UUID(), closed = false
    var onClosed: (() -> Void)?
    init(url: URL, proposal: NamingProposal) {
        self.url = url; self.proposal = proposal; super.init(); window.title = "核对原图与识别文字 — "+url.lastPathComponent; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:760,height:540); window.delegate = self
        for page in proposal.pages { chooser.addItem(withTitle:"\(page.role) · 物理\(page.physical) · \(page.textLayer ? "PDF 文字层" : "OCR")") }
        chooser.target = self; chooser.action = #selector(pageChanged)
        image.imageScaling = .scaleProportionallyUpOrDown
        imageScroll.scrollerStyle = .overlay; imageScroll.documentView = image; imageScroll.hasVerticalScroller = true; imageScroll.hasHorizontalScroller = true; imageScroll.autohidesScrollers = true; imageScroll.allowsMagnification = true; imageScroll.minMagnification = 0.05; imageScroll.maxMagnification = 4; imageScroll.borderType = .bezelBorder
        imageScroll.widthAnchor.constraint(greaterThanOrEqualToConstant:350).isActive = true
        let scroll = ocrTextScroll(text,editable:false)
        let preview=NSView()
        for view in [imageScroll,pdfView] {
            view.translatesAutoresizingMaskIntoConstraints=false;preview.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:preview.leadingAnchor),view.trailingAnchor.constraint(equalTo:preview.trailingAnchor),view.topAnchor.constraint(equalTo:preview.topAnchor),view.bottomAnchor.constraint(equalTo:preview.bottomAnchor)])
        }
        pdfView.isHidden=true;pdfView.displayMode = .singlePage;pdfView.displayBox = .cropBox;pdfView.autoScales=true
        pdfView.minScaleFactor=0.01;pdfView.maxScaleFactor=40
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin; split.addArrangedSubview(preview); split.addArrangedSubview(scroll); scroll.widthAnchor.constraint(greaterThanOrEqualToConstant:320).isActive = true
        let close = NSButton(title:"关闭",target:self,action:#selector(closeWindow)); close.bezelStyle = .rounded
        let fit = NSButton(title:"适合整页",target:self,action:#selector(fitPage)), minus = NSButton(title:"缩小",target:self,action:#selector(zoomOut)), plus = NSButton(title:"放大",target:self,action:#selector(zoomIn))
        for button in [fit,minus,plus] { button.bezelStyle = .rounded }
        chooser.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let width=NSButton(title:"适合宽度",target:self,action:#selector(fitWidth));width.bezelStyle = .rounded
        let row = NSStackView(views:[chooser,NSView(),minus,plus,width,fit,close]); row.spacing = 10
        let root = NSStackView(views:[row,split]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        let host = NSView(); window.contentView = host; root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:host.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-16),row.widthAnchor.constraint(equalTo:root.widthAnchor),split.widthAnchor.constraint(equalTo:root.widthAnchor)])
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
    }
    func show(on parent: NSWindow) { NativeDialog.present(window,on:parent); window.contentView?.layoutSubtreeIfNeeded(); (imageScroll.superview?.superview as? NSSplitView)?.setPosition(window.contentView!.bounds.width*0.52,ofDividerAt:0); pageChanged() }
    @objc func pageChanged() {
        guard proposal.pages.indices.contains(chooser.indexOfSelectedItem) else { return }
        let page = proposal.pages[chooser.indexOfSelectedItem], token = UUID(); generation = token; queue.cancelAllOperations(); image.image = nil;pdfView.document=nil; text.string = page.text
        queue.addOperation { [weak self,url,proposal] in
            let result = Result { () throws -> (CGImage,PDFPage?,PDFDocument?) in
                guard try BatchNaming.fingerprint(url) == proposal.fingerprint else { throw ReaderFailure("图书已变化，请重新分析。") }
                let source=try NamingSource(url)
                let vector=try source.vectorPage(at:page.physical-1)
                return (try source.image(at:page.physical-1),vector,vector?.document)
            }
            DispatchQueue.main.async {
                guard let self,!self.closed,self.generation == token else { return }
                switch result { case .success(let (cg,pdf,document)):
                    self.pdfView.isHidden=pdf==nil;self.imageScroll.isHidden=pdf != nil
                    if let pdf {self.pdfView.document=document;self.pdfView.go(to:pdf)}
                    self.image.image = NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height)); self.image.frame = CGRect(x:0,y:0,width:cg.width,height:cg.height); self.fitPage()
                case .failure(let error): self.text.string = error.localizedDescription+"\n\n原识别文字：\n"+page.text }
            }
        }
    }
    @objc func fitPage() {
        automaticFit=true
        if !pdfView.isHidden {
            pdfView.autoScales=true
            pdfView.scaleFactor=pdfView.scaleFactorForSizeToFit
            return
        }
        guard let size=image.image?.size,size.width>0,size.height>0 else{return}
        let available=imageScroll.contentSize
        imageScroll.setMagnification(min(imageScroll.maxMagnification,max(imageScroll.minMagnification,min(available.width/size.width,available.height/size.height))),centeredAt:CGPoint(x:size.width/2,y:size.height/2))
    }
    @objc func fitWidth() {
        automaticFit=false
        if !pdfView.isHidden,let page=pdfView.currentPage {
            pdfView.autoScales=false;pdfView.scaleFactor=pdfView.bounds.width/max(1,page.orientedCropSize.width)
        } else if let size=image.image?.size {
            imageScroll.magnification=min(imageScroll.maxMagnification,imageScroll.contentSize.width/max(1,size.width))
        }
    }
    @objc func zoomIn() {
        automaticFit=false
        if !pdfView.isHidden {pdfView.autoScales=false;pdfView.zoomIn(nil)}
        else {imageScroll.magnification=min(imageScroll.maxMagnification,imageScroll.magnification*1.4)}
    }
    @objc func zoomOut() {
        automaticFit=false
        if !pdfView.isHidden {pdfView.autoScales=false;pdfView.zoomOut(nil)}
        else {imageScroll.magnification=max(imageScroll.minMagnification,imageScroll.magnification/1.4)}
    }
    func windowDidResize(_ notification:Notification) {if automaticFit {fitPage()}}
    @objc func closeWindow() { closed = true; generation = UUID(); queue.cancelAllOperations(); NativeDialog.dismiss(window); onClosed?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeWindow(); return false }
}

final class BatchSelectionHeader: NSTableHeaderView {
    let check = NSButton(checkboxWithTitle:"",target:nil,action:nil)
    override init(frame: NSRect) { super.init(frame:frame); check.allowsMixedState = true; check.toolTip = "全选或取消全部已分析的图书"; check.setAccessibilityLabel("选择全部图书"); addSubview(check) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() { super.layout(); guard tableView?.tableColumns.isEmpty == false else { return }; let rect = headerRect(ofColumn:0); check.frame = CGRect(x:rect.midX-9,y:rect.midY-9,width:18,height:18) }
}

final class BatchBookTable: NSTableView {
    private final class SelectionBox: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            bounds.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    var clickRow: ((Int) -> Void)?
    var includeRows: ((IndexSet) -> Void)?
    private let selectionBox = SelectionBox()

    override func mouseDown(with event: NSEvent) {
        guard let window, event.type == .leftMouseDown else { super.mouseDown(with: event); return }
        let start = convert(event.locationInWindow, from: nil)
        let firstRow = row(at: start)
        window.makeFirstResponder(self)
        var dragging = false
        var latest = event
        defer { selectionBox.removeFromSuperview() }

        while true {
            if let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                           until: Date(timeIntervalSinceNow: 0.04),
                                           inMode: .eventTracking, dequeue: true) {
                latest = next
                if next.type == .leftMouseUp { break }
            } else if !dragging {
                continue
            }
            let point = convert(latest.locationInWindow, from: nil)
            if !dragging, hypot(point.x - start.x, point.y - start.y) >= 4 {
                dragging = true
                wantsLayer = true
                selectionBox.wantsLayer = true
                selectionBox.layer?.zPosition = 10
                addSubview(selectionBox, positioned: .above, relativeTo: nil)
            }
            if dragging {
                autoscroll(with: latest)
                selectionBox.frame = box(from: start, to: convert(latest.locationInWindow, from: nil))
                selectionBox.needsDisplay = true
                displayIfNeeded()
            }
        }

        if dragging {
            let area = box(from: start, to: convert(latest.locationInWindow, from: nil))
            let rows = rows(in: area)
            if rows.location != NSNotFound, rows.length > 0 {
                includeRows?(IndexSet(integersIn: rows.location..<(rows.location + rows.length)))
            }
        } else if firstRow >= 0 {
            selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
            if column(at: start) == 0 { clickRow?(firstRow) }
        }
    }

    private func box(from start: NSPoint, to end: NSPoint) -> NSRect {
        NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: max(2, abs(start.x - end.x)), height: max(2, abs(start.y - end.y)))
    }
}

/// Clicks in the checkbox column are tracked by the table, including drags that start on the checkbox.
private final class BatchRowCheckbox: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BatchNamingWindow: NSObject, NSSplitViewDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let recognitionControls = RecognitionControls()
    let window = ChineseWindow(contentRect:NSRect(x:0,y:0,width:1380,height:940),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
    let table = BatchBookTable(), evidenceTable = NSTableView()
    let bookPreview = BatchBookPreview()
    let recursive = NSButton(checkboxWithTitle:"包含子文件夹",target:nil,action:nil)
    let useOCR = NSButton(checkboxWithTitle:"识别图像并交叉核对",target:nil,action:nil)
    let forcePDFOCR = NSButton(checkboxWithTitle:"PDF 逐页 OCR",target:nil,action:nil)
    let preserveDates = NSButton(checkboxWithTitle:"保持文件日期",target:nil,action:nil)
    let reviewed = NSButton(checkboxWithTitle:"已人工核对本书的冲突、推测及缺失项",target:nil,action:nil)
    let uniformStyle = NSPopUpButton()
    let selectionHeader = BatchSelectionHeader(frame:NSRect(x:0,y:0,width:600,height:24))
    private var namingStyles = NamingPreferences.styles()
    private(set) var templateWindow: NamingTemplateWindow?
    let finalName = CenteredTextField()
    let fields = BookMetadata.fields.filter { $0 != "摘要" }.map { _ in CenteredTextField() }
    private let fieldKeys = BookMetadata.fields.filter { $0 != "摘要" }
    private let fieldStates = BookMetadata.fields.filter { $0 != "摘要" }.map { _ in CenteredTextField(labelWithString:"") }
    private let folderLabel = CenteredTextField(labelWithString:"尚未选择文件夹")
    private let formatHint = CenteredTextField(wrappingLabelWithString:"")
    private let note = CenteredTextField(wrappingLabelWithString:"选择文件夹后逐本分析。候选建议不会自动改名，需勾选并应用。")
    private let scanButton = NSButton(title:"分析未完成项",target:nil,action:nil)
    private let stopButton = NSButton(title:"停止",target:nil,action:nil)
    private let supplementButton = NSButton(title: "补书签…", target: nil, action: nil)
    private let inclusionSummary = CenteredTextField(labelWithString: "已勾选 0 本")
    private let originalName = CenteredTextField(wrappingLabelWithString: "")
    private let nameExtension = CenteredTextField(labelWithString: "")
    private let sources = NSPopUpButton()
    private let detailScroll = NSScrollView()
    private let split = NSSplitView()
    private(set) var referenceWindow: OnlineReferences?
    private(set) var bookmarkEditor: BookEditor?
    private var loadingBookmarks = false
    private var lastPages: [URL:Int] = [:]
    private var sourceField: String?
    private var bookmarkFlowActive: Bool { loadingBookmarks || referenceWindow != nil || bookmarkEditor != nil }
    private let applyButton = NSButton(title:"保存信息并改名",target:nil,action:nil)
    private let detailNote = CenteredTextField(wrappingLabelWithString:"")
    private let queue = OperationQueue()
    private var generation = UUID(), closed = false, stopRequested = false
    private var selectedIndex: Int?
    private var planIssues: [Int:String] = [:]
    private(set) var currentEvidence: [NamingEvidence] = []
    private(set) var folder: URL?
    private(set) var items: [BatchNamingItem] = []
    private(set) var isAnalysing = false, isApplying = false
    private(set) var sourceWindow: NamingSourceWindow?
    var blockedReason: ((URL) -> String?)?
    var onRenamed: ((URL,URL) -> Void)?
    var onClosed: (() -> Void)?
    override init() {
        super.init(); window.title = "批量规范命名"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:1040,height:650); window.delegate = self; window.identifier = .init("UVZBatchNaming")
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        useOCR.target = self; useOCR.action = #selector(ocrOptionChanged)
        forcePDFOCR.toolTip = "忽略 PDF 文字层，对首尾候选页逐张识别；适合文字层缺字或与原图不符的文件。"
        useOCR.state = .on; preserveDates.state = AppSettings().preserveFileDates ? .on : .off
        uniformStyle.addItems(withTitles:namingStyles.map(\.title)); uniformStyle.selectItem(at:namingStyles.firstIndex(where:{$0.id == NamingPreferences.preferred()}) ?? 0); uniformStyle.target = self; uniformStyle.action = #selector(uniformStyleChanged)
        folderLabel.lineBreakMode = .byTruncatingMiddle; folderLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let choose = button("选择文件夹…", #selector(chooseFolder))
        let rescan = button("重新扫描", #selector(rescanFolder))
        scanButton.target = self; scanButton.action = #selector(analysePending); scanButton.bezelStyle = .rounded
        stopButton.target = self; stopButton.action = #selector(stop); stopButton.bezelStyle = .rounded
        let settings = NSPopover()
        let settingsStack = NSStackView(views: [
            recursive, useOCR,
            NSStackView(views: [CenteredTextField(labelWithString: "识别语言"), recognitionControls.language]),
            NSStackView(views: [CenteredTextField(labelWithString: "版式"), recognitionControls.layout]),
            forcePDFOCR
        ])
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 8
        settingsStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let settingsController = NSViewController()
        settingsController.view = settingsStack
        settings.contentViewController = settingsController
        settings.behavior = .transient
        let settingsButton = button("识别设置…", #selector(showRecognitionSettings(_:)))
        recognitionSettings = settings
        let top = NSStackView(views: [choose, folderLabel, NSView(), rescan, scanButton, stopButton, settingsButton])
        top.spacing = 8

        configure(table, columns: [("include","",42),("file","原文件名",260),("name","最终文件名",270),("status","状态",100)])
        table.rowHeight = 49
        table.usesAutomaticRowHeights = false
        table.clickRow = { [weak self] row in self?.setIncluded(IndexSet(integer: row), to: nil) }
        table.includeRows = { [weak self] rows in self?.setIncluded(rows, to: true) }
        selectionHeader.check.target = self
        selectionHeader.check.action = #selector(toggleAll)
        table.headerView = selectionHeader
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.borderType = .bezelBorder
        let listTitle = CenteredTextField(labelWithString: "书单")
        listTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let listHint = CenteredTextField(labelWithString: "拖出选框可勾选多本")
        listHint.textColor = .secondaryLabelColor
        listHint.font = .systemFont(ofSize: 11)
        let formatRow = NSStackView(views: [listTitle, listHint, NSView(), CenteredTextField(labelWithString: "批次命名格式"), uniformStyle, button("管理…", #selector(manageTemplates))])
        formatRow.spacing = 6
        let books = verticalStack([formatRow, list], spacing: 6)
        list.setContentHuggingPriority(.defaultLow, for: .vertical)

        for (key,field) in zip(fieldKeys,fields) { field.identifier = .init(key); field.delegate = self }
        let grid = NSGridView(views: fieldKeys.indices.map { [CenteredTextField(labelWithString:fieldKeys[$0]),fields[$0],fieldStates[$0]] })
        grid.rowSpacing = 3
        grid.columnSpacing = 7
        grid.column(at: 0).width = 54
        grid.column(at: 2).width = 70
        for state in fieldStates { state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor }
        for index in fieldKeys.indices { grid.row(at:index).height = 23 }

        reviewed.title = "已人工核对"
        reviewed.target = self
        reviewed.action = #selector(reviewChanged)
        supplementButton.target = self
        supplementButton.action = #selector(supplementBookmarks)
        supplementButton.bezelStyle = .rounded
        let heading = CenteredTextField(labelWithString: "书目信息")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailHeading = NSStackView(views: [heading, NSView(), supplementButton, reviewed])
        detailHeading.spacing = 7
        originalName.font = .systemFont(ofSize: 11)
        originalName.textColor = .secondaryLabelColor
        originalName.maximumNumberOfLines = 2
        detailNote.font = .systemFont(ofSize: 11)
        detailNote.textColor = .secondaryLabelColor
        detailNote.maximumNumberOfLines = 3
        formatHint.font = .systemFont(ofSize: 11)
        formatHint.textColor = .secondaryLabelColor
        formatHint.lineBreakMode = .byTruncatingTail
        finalName.delegate = self
        finalName.identifier = .init("final-name")
        finalName.placeholderString = "最终名称"
        let nameRow = NSStackView(views: [CenteredTextField(labelWithString: "最终名称"), finalName, nameExtension])
        nameRow.spacing = 6

        configure(evidenceTable, columns: [("field","字段",55),("value","来源值",180),("source","来源",75),("page","页",34)])
        evidenceTable.target = self
        evidenceTable.doubleAction = #selector(adoptEvidence)
        let evidence = NSScrollView()
        evidence.documentView = evidenceTable
        evidence.hasVerticalScroller = true
        evidence.borderType = .bezelBorder
        evidence.heightAnchor.constraint(equalToConstant: 108).isActive = true
        sources.addItems(withTitles: ["所有字段"] + fieldKeys)
        sources.target = self
        sources.action = #selector(sourceFilterChanged)
        let evidenceTools = NSStackView(views: [sources, NSView(), button("采用来源",#selector(adoptEvidence)),button("识别原文…",#selector(showSources))])
        evidenceTools.spacing = 5
        let detail = verticalStack([detailHeading, originalName, detailNote, grid, formatHint, nameRow, evidenceTools, evidence], spacing: 6)
        let document = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            detail.topAnchor.constraint(equalTo: document.topAnchor),
            detail.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        detailScroll.documentView = document
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor)
        ])

        let side = verticalStack([bookPreview, detailScroll], spacing: 9, leadingInset: 10)
        bookPreview.heightAnchor.constraint(equalToConstant: 236).isActive = true
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 265).isActive = true
        detailScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.delegate = self
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(books)
        split.addArrangedSubview(side)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        side.widthAnchor.constraint(greaterThanOrEqualToConstant: 395).isActive = true
        side.widthAnchor.constraint(lessThanOrEqualTo: split.widthAnchor, multiplier: 0.45).isActive = true

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingMiddle
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inclusionSummary.font = .systemFont(ofSize: 12, weight: .medium)
        applyButton.toolTip = "保存勾选图书的书目信息并改名"
        applyButton.target = self
        applyButton.action = #selector(applySelected)
        applyButton.bezelStyle = .rounded
        let footer = NSStackView(views: [inclusionSummary, preserveDates, button("导出清单…", #selector(exportCSV)), NSView(),
                                      button("检查重名", #selector(checkNames)), applyButton])
        footer.spacing = 8
        let root = verticalStack([top, split, note, footer], spacing: 9)
        let host = NSView()
        window.contentView = host
        root.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14)
        ])
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        loadDetails()
        updateControls()
    }

    private var recognitionSettings: NSPopover?
    @objc private func showRecognitionSettings(_ sender: NSButton) {
        recognitionSettings?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat, leadingInset: CGFloat = 0) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: leadingInset, bottom: 0, right: 0)
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -leadingInset).isActive = true
        }
        return stack
    }
    private func button(_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b }
    private func configure(_ table: NSTableView,columns: [(String,String,CGFloat)]) {
        for (id,title,width) in columns { let c = NSTableColumn(identifier:.init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.delegate = self; table.dataSource = self; table.rowHeight = 29; table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .noColumnAutoresizing
    }
    private var splitPositioned = false
    func show(choose: Bool = false) {
        if let screen = NSScreen.main?.visibleFrame { var frame = window.frame; frame.size.width = min(frame.width,screen.width-32); frame.size.height = min(frame.height,screen.height-32); frame.origin = CGPoint(x:screen.midX-frame.width/2,y:screen.midY-frame.height/2); window.setFrame(frame,display:false) }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        if !splitPositioned {
            split.setPosition(split.bounds.width * 0.64, ofDividerAt: 0)
            splitPositioned = true
        }
        fitTableColumns()
        if choose { chooseFolder() }
    }
    func fitTableColumns() {
        guard table.tableColumns.count == 4,evidenceTable.tableColumns.count == 4 else { return }
        func fit(_ table: NSTableView,widths: [CGFloat]) {
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for (column,width) in zip(table.tableColumns,widths) { column.minWidth = 24; column.width = width }
            table.setFrameSize(NSSize(width:widths.reduce(0,+)+table.intercellSpacing.width*CGFloat(widths.count),height:table.frame.height))
        }
        let left = table.enclosingScrollView?.contentView.frame.width ?? 600, leftSpace = table.intercellSpacing.width*4+2
        let status: CGFloat = 101, check: CGFloat = 36
        let file = max(100, (left - check - status - leftSpace) * 0.49)
        fit(table,widths:[check,file,max(60,left-check-file-status-leftSpace),status])
        let right = evidenceTable.enclosingScrollView?.contentView.frame.width ?? 600, rightSpace = evidenceTable.intercellSpacing.width*4+2
        fit(evidenceTable,widths:[50,max(90,right-50-74-35-rightSpace),74,35]); selectionHeader.needsLayout = true
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposed, splitView.bounds.width * 0.55)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposed, splitView.bounds.width - 395 - splitView.dividerThickness)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) { fitTableColumns() }
    func windowDidResize(_ notification: Notification) {
        if splitPositioned {
            let width = split.bounds.width
            let maxPosition = width - 395 - split.dividerThickness
            let position = split.arrangedSubviews.first?.frame.width ?? width * 0.64
            if maxPosition > 0, position < width * 0.55 || position > maxPosition {
                split.setPosition(min(maxPosition, max(width * 0.55, position)), ofDividerAt: 0)
            }
        }
        fitTableColumns()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !isApplying else { return }; let updated = NamingPreferences.styles(); guard updated != namingStyles else { return }
        let selected = namingStyles.indices.contains(uniformStyle.indexOfSelectedItem) ? namingStyles[uniformStyle.indexOfSelectedItem].id : NamingPreferences.automatic
        namingStyles = updated; uniformStyle.removeAllItems(); uniformStyle.addItems(withTitles:updated.map(\.title)); uniformStyle.selectItem(at:updated.firstIndex(where:{$0.id == selected}) ?? 0)
        for item in items where !updated.contains(where:{$0.id == item.styleID}) { item.styleID = NamingPreferences.automatic }
        table.reloadData(); loadDetails()
    }
    @objc func chooseFolder() {
        guard !isApplying, !bookmarkFlowActive else { return }; let panel = NSOpenPanel(); panel.title = "选择待整理的图书文件夹"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in if response == .OK,let folder = panel.url { self?.loadFolder(folder) } }
    }
    @objc func rescanFolder() { if let folder,!isApplying { loadFolder(folder) } }
    func loadFolder(_ url: URL) {
        guard !isApplying, !bookmarkFlowActive else { return }; stopAnalysis(); folder = url; folderLabel.stringValue = url.path; folderLabel.toolTip = url.path
        items = []; selectedIndex = nil; planIssues = [:]; lastPages = [:]; table.reloadData(); loadDetails()
        let token = UUID(), deep = recursive.state == .on; generation = token; isAnalysing = true; updateControls(); note.stringValue = "正在扫描文件夹…"
        let operation = BlockOperation(); operation.addExecutionBlock { [weak self,weak operation] in
            let result = Result { try BatchNaming.discover(url,recursive:deep,cancelled:{operation?.isCancelled != false}) }
            DispatchQueue.main.async {
                guard let self,!self.closed,self.generation == token else { return }; self.isAnalysing = false
                switch result {
                case .success(let urls): self.items = urls.map { BatchNamingItem($0,styleID:self.namingStyles[self.uniformStyle.indexOfSelectedItem].id) }; self.table.reloadData(); self.note.stringValue = "发现 \(urls.count) 本图书。"; if !urls.isEmpty { self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); self.analysePending() } else { self.updateControls() }
                case .failure(let error): self.note.stringValue = error.localizedDescription; self.updateControls()
                }
            }
        }; queue.addOperation(operation)
    }
    @objc func analysePending() {
        guard !isApplying,!isAnalysing,!bookmarkFlowActive else { return }
        let pending = items.indices.filter { items[$0].proposal == nil && items[$0].outcome == nil }
        guard !pending.isEmpty else { note.stringValue = "所有项目均已分析；如需重新读取，请重新扫描文件夹。"; return }
        let inputs = pending.map { ($0,items[$0].url) }, token = UUID(), ocr = useOCR.state == .on, options = recognitionControls.options
        let forcePDFOCR = self.forcePDFOCR.state == .on
        generation = token; isAnalysing = true; updateControls()
        let operation = BlockOperation(); operation.addExecutionBlock { [weak self,weak operation] in
            for (position,input) in inputs.enumerated() {
                if operation?.isCancelled != false { break }; let (index,url) = input
                DispatchQueue.main.async { guard let self,!self.closed,self.generation == token else { return }; self.items[index].analysing = true; self.reloadRows(IndexSet(integer:index)) }
                let result = Result { try autoreleasepool { try BatchNaming.analyse(url,ocr:ocr,forcePDFOCR:forcePDFOCR,options:options,cancelled:{operation?.isCancelled != false},progress:{ text in
                    DispatchQueue.main.async { guard let self,!self.closed,self.generation == token else { return }; self.note.stringValue = "\(position+1)/\(inputs.count) · \(url.lastPathComponent) · \(text)" }
                }) } }
                DispatchQueue.main.async {
                    guard let self,!self.closed,self.generation == token else { return }; self.items[index].analysing = false
                    switch result { case .success(let proposal): self.items[index].proposal = proposal; self.items[index].error = nil
                    case .failure(let error): self.items[index].error = error.localizedDescription }
                    self.reloadRows(IndexSet(integer:index)); if self.selectedIndex == index { self.loadDetails() }
                }
            }
            DispatchQueue.main.async { guard let self,!self.closed,self.generation == token else { return }; self.isAnalysing = false; self.note.stringValue = "分析完成：\(self.items.filter{$0.proposal != nil}.count)/\(self.items.count) 本。核对候选、勾选后再应用。"; self.updateControls() }
        }; queue.addOperation(operation)
    }
    private func stopAnalysis() { generation = UUID(); queue.cancelAllOperations(); isAnalysing = false; for item in items { item.analysing = false }; updateControls() }
    @objc func stop() {
        if isApplying { stopRequested = true; note.stringValue = "正在完成当前图书，随后停止；已完成的改名会保留。" }
        else { stopAnalysis(); table.reloadData(); note.stringValue = "已停止分析，已完成的建议保留；可继续分析未完成项。" }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === table ? items.count : currentEvidence.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let field = CenteredTextField(labelWithString:""); field.font = .systemFont(ofSize:12); field.lineBreakMode = .byTruncatingMiddle
        if tableView === evidenceTable {
            let e = currentEvidence[row]
            switch column?.identifier.rawValue { case "field": field.stringValue = e.field; case "value": field.stringValue = e.value; case "source": field.stringValue = e.source+(e.inferred ? "（推测）" : ""); default: field.stringValue = e.page.map(String.init) ?? "" }
        } else {
            let item = items[row]
            switch column?.identifier.rawValue {
            case "include":
                let check = BatchRowCheckbox(checkboxWithTitle: "", target: self, action: #selector(includeChanged(_:)))
                check.tag = row
                check.state = item.included ? .on : .off
                check.isEnabled = !isApplying && item.proposal != nil && item.outcome == nil
                check.setAccessibilityLabel("纳入改名批次：" + item.url.lastPathComponent)
                return check
            case "file", "name":
                let isOriginal = column?.identifier.rawValue == "file"
                field.stringValue = isOriginal ? item.url.lastPathComponent : item.proposal == nil ? "" : item.displayName
                field.cell?.usesSingleLineMode = false
                field.maximumNumberOfLines = 2
                field.lineBreakMode = .byTruncatingTail
                field.toolTip = isOriginal ? item.url.path : field.stringValue
            default: field.stringValue = planIssues[row] ?? item.status; if planIssues[row] != nil || item.error != nil { field.textColor = .systemRed } else if !item.reviewReasons.isEmpty && !item.reviewed { field.textColor = .systemOrange }
            }
        }
        if field.toolTip == nil { field.toolTip = field.stringValue }; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === evidenceTable {
            let row = evidenceTable.selectedRow
            if currentEvidence.indices.contains(row), let page = currentEvidence[row].page, page > 0 { bookPreview.showPage(page - 1) }
            return
        }
        guard notification.object as? NSTableView === table else { return }
        let next = items.indices.contains(table.selectedRow) ? table.selectedRow : nil
        guard selectedIndex != next else { return }
        if let url = bookPreview.url { lastPages[url] = bookPreview.page }
        window.makeFirstResponder(table)
        selectedIndex = next
        sources.selectItem(at: 0)
        sourceField = nil
        detailScroll.contentView.scroll(to: .zero)
        loadDetails()
    }
    private func loadDetails() {
        let item = selectedIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }, proposal = item?.proposal
        bookPreview.load(item?.url, page: item.flatMap { lastPages[$0.url] } ?? 0)
        originalName.stringValue = item?.url.lastPathComponent ?? ""
        originalName.toolTip = item?.url.path
        let isFolder = item?.url.hasDirectoryPath == true || (try? item?.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = item?.url.pathExtension ?? ""
        nameExtension.stringValue = isFolder || ext.isEmpty ? "" : "." + ext
        supplementButton.isEnabled = item != nil && !isAnalysing && !isApplying && !bookmarkFlowActive
        for (index,key) in fieldKeys.enumerated() { fields[index].stringValue = proposal?.metadata[key] ?? ""; fields[index].isEnabled = proposal != nil && item?.outcome == nil && !isApplying; fieldStates[index].stringValue = proposal?.fieldStatus(key) ?? "" }
        updateEvidence(proposal)
        formatHint.stringValue = proposal.map { "命名格式："+NamingPreferences.pattern(item?.styleID ?? NamingPreferences.automatic,metadata:$0.metadata) } ?? ""
        finalName.stringValue = item?.stem ?? ""; finalName.toolTip = item?.displayName; finalName.isEnabled = proposal != nil && item?.outcome == nil && !isApplying
        reviewed.state = item?.reviewed == true ? .on : .off; reviewed.isEnabled = proposal != nil && item?.outcome == nil && !isApplying
        updateDetailNote(item)
    }

    private func updateEvidence(_ proposal: NamingProposal?) {
        currentEvidence = (proposal?.evidence ?? []).filter { sourceField == nil || $0.field == sourceField }
        currentEvidence = currentEvidence.enumerated().sorted {
            let first = BookMetadata.fields.firstIndex(of: $0.element.field) ?? BookMetadata.fields.count
            let second = BookMetadata.fields.firstIndex(of: $1.element.field) ?? BookMetadata.fields.count
            return first == second ? $0.offset < $1.offset : first < second
        }.map(\.element)
        evidenceTable.reloadData()
    }

    @objc private func sourceFilterChanged() {
        let index = sources.indexOfSelectedItem - 1
        sourceField = fieldKeys.indices.contains(index) ? fieldKeys[index] : nil
        updateEvidence(selectedIndex.flatMap { items[$0].proposal })
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let key = field.identifier?.rawValue, let index = fieldKeys.firstIndex(of: key) else { return }
        sources.selectItem(at: index + 1)
        sourceFilterChanged()
    }

    private func updateDetailNote(_ item: BatchNamingItem?) {
        let text: String
        if let item, item.proposal != nil {
            text = item.reviewReasons.isEmpty ? "来源信息未发现明显冲突；仍可查看原图核对。" : item.reviewReasons.joined(separator:"；")
        } else {
            text = "分析完成后可查看逐字段来源，手工修订或采用某一来源值。"
        }
        if detailNote.stringValue != text { detailNote.stringValue = text }
    }
    private func reloadRows(_ rows: IndexSet, columns: IndexSet = IndexSet(integersIn:0..<4)) {
        table.reloadData(forRowIndexes:rows,columnIndexes:columns)
    }
    @objc func includeChanged(_ sender: NSButton) {
        guard sender.tag >= 0 else { return }
        setIncluded(IndexSet(integer: sender.tag), to: sender.state == .on)
    }

    private func setIncluded(_ rows: IndexSet, to included: Bool?) {
        guard !isApplying else { return }
        for row in rows where items.indices.contains(row) && items[row].proposal != nil && items[row].outcome == nil {
            let item = items[row]
            item.included = included ?? !item.included
        }
        planIssues = [:]
        table.reloadData()
        updateControls()
    }

    @objc func toggleAll() {
        guard !isApplying, !isAnalysing else { return }
        let eligible = items.indices.filter { items[$0].proposal != nil && items[$0].outcome == nil }
        setIncluded(IndexSet(eligible), to: !eligible.allSatisfy { items[$0].included })
    }

    @objc func reviewChanged() {
        guard let index = selectedIndex, !isApplying, items[index].proposal != nil, items[index].outcome == nil else { return }
        let item = items[index]
        item.reviewed = reviewed.state == .on
        item.included = item.reviewed
        planIssues = [:]
        table.reloadData()
        updateControls()
    }
    @objc func uniformStyleChanged() {
        guard !isApplying,namingStyles.indices.contains(uniformStyle.indexOfSelectedItem) else { return }
        let id = namingStyles[uniformStyle.indexOfSelectedItem].id; AppSettings().set(id,"namingStyle")
        for item in items where item.outcome == nil { item.styleID = id }
        planIssues = [:]; table.reloadData(); loadDetails()
    }
    @objc func manageTemplates() {
        guard !isApplying,!window.hasDocumentDialog else { return }
        let item = selectedIndex.map {items[$0]}, pattern = NamingPreferences.pattern(item?.styleID ?? NamingPreferences.preferred(),metadata:item?.proposal?.metadata ?? [:])
        let controller = NamingTemplateWindow(pattern:pattern); templateWindow = controller
        controller.onChange = { [weak self] id in
            guard let self else { return }; self.namingStyles = NamingPreferences.styles(); self.uniformStyle.removeAllItems(); self.uniformStyle.addItems(withTitles:self.namingStyles.map(\.title))
            for item in self.items where !self.namingStyles.contains(where:{$0.id == item.styleID}) { item.styleID = NamingPreferences.automatic }
            let selected = id ?? NamingPreferences.preferred(); self.uniformStyle.selectItem(at:self.namingStyles.firstIndex(where:{$0.id == selected}) ?? 0)
            if id != nil { self.uniformStyleChanged() } else { self.table.reloadData(); self.loadDetails() }
        }
        controller.onClose = { [weak self] in self?.templateWindow = nil }; controller.show(on:window)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let index = selectedIndex,let field = notification.object as? NSTextField,items[index].proposal != nil,items[index].outcome == nil,!isApplying else { return }
        let item = items[index]
        if field === finalName {
            item.customName = field.stringValue.isEmpty ? nil : field.stringValue
        } else if let key = field.identifier?.rawValue, let fieldIndex = fieldKeys.firstIndex(of: key) {
            item.reviewed = true
            item.included = true
            reviewed.state = .on
            item.proposal!.metadata[key] = key == "出版日期" ? BookMetadata.date(field.stringValue) : field.stringValue
            let hint = "命名格式："+NamingPreferences.pattern(item.styleID,metadata:item.proposal!.metadata)
            if formatHint.stringValue != hint { formatHint.stringValue = hint }
            let stem = item.stem
            if finalName.stringValue != stem { finalName.stringValue = stem }
            let status = item.proposal!.fieldStatus(key)
            if fieldStates[fieldIndex].stringValue != status { fieldStates[fieldIndex].stringValue = status }
            updateDetailNote(item)
        }
        var rows = IndexSet(planIssues.keys)
        rows.insert(index)
        planIssues.removeAll()
        reloadRows(rows,columns:IndexSet([0, 2, 3]))
        updateControls()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === finalName, let index = selectedIndex,
              items.indices.contains(index) else { return }
        finalName.stringValue = items[index].stem
        finalName.toolTip = items[index].displayName
    }

    @objc func adoptEvidence() {
        guard let index = selectedIndex,!isApplying,items[index].outcome == nil,currentEvidence.indices.contains(evidenceTable.selectedRow) else { return }
        let value = currentEvidence[evidenceTable.selectedRow]; items[index].proposal?.metadata[value.field] = value.value; items[index].reviewed = true; items[index].included = true; planIssues = [:]; table.reloadData(); loadDetails(); updateControls()
    }
    @objc func showSources() {
        guard let index = selectedIndex,let proposal = items[index].proposal,!proposal.pages.isEmpty,!window.hasDocumentDialog else { return }
        let controller = NamingSourceWindow(url:items[index].url,proposal:proposal); sourceWindow = controller
        controller.onClosed = { [weak self] in self?.sourceWindow = nil }; controller.show(on:window)
    }
    @objc func supplementBookmarks() {
        guard !isApplying, !isAnalysing, !bookmarkFlowActive, !window.hasDocumentDialog,
              let index = selectedIndex, items.indices.contains(index) else { return }
        let item = items[index]
        let url = item.url
        if let problem = blockedReason?(url) { note.stringValue = problem; return }
        let selectedSSID = item.proposal?.metadata["SS号"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expected = item.outcome == nil ? item.proposal?.fingerprint : nil
        let currentPage = bookPreview.page
        loadingBookmarks = true
        note.stringValue = "正在打开书签查询…"
        updateControls()
        queue.addOperation { [weak self] in
            let result = Result { () throws -> (BookArchive, String) in
                let fingerprint = try BatchNaming.fingerprint(url)
                guard expected == nil || expected == fingerprint else {
                    throw ReaderFailure("图书已发生变化，请重新扫描后再补书签。")
                }
                let book = try BookArchive(url: url)
                guard !book.isPDZ else { throw ReaderFailure("这种格式只支持读取目录。") }
                guard try BatchNaming.fingerprint(url) == fingerprint else { throw ReaderFailure("图书已发生变化，请重试。") }
                return (book, fingerprint)
            }
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.loadingBookmarks = false
                switch result {
                case .failure(let error):
                    self.note.stringValue = error.localizedDescription
                case .success(let (book, fingerprint)):
                    self.note.stringValue = "正在核对「" + url.lastPathComponent + "」的书签"
                    let controller = OnlineReferences(ssid: selectedSSID.isEmpty ? FilenameDraft(book: book).ss : selectedSSID,
                                                      mode: .bookmarks)
                    self.referenceWindow = controller
                    controller.window.title = "补书签 — " + url.lastPathComponent
                    controller.onClosed = { [weak self] in
                        self?.referenceWindow = nil
                        self?.updateControls()
                    }
                    controller.onDirectory = { [weak self, weak controller] text in
                        guard let self, let controller else { return false }
                        let editor = BookEditor(book: book, allowPageRepair: false)
                        editor.currentPage = currentPage
                        guard editor.insertReferenceContents(text) else { return false }
                        self.bookmarkEditor = editor
                        editor.beforeSave = {
                            guard try BatchNaming.fingerprint(url) == fingerprint else {
                                throw ReaderFailure("图书已发生变化，请重新打开目录编辑。")
                            }
                        }
                        editor.onClosed = { [weak self] in
                            self?.bookmarkEditor = nil
                            self?.updateControls()
                        }
                        editor.onSaved = { [weak self] _ in self?.bookmarksSaved(for: item) }
                        controller.close()
                        NativeDialog.present(editor.window, on: self.window)
                        return true
                    }
                    controller.show(on: self.window)
                }
                self.updateControls()
            }
        }
    }

    private func bookmarksSaved(for item: BatchNamingItem) {
        loadingBookmarks = true
        updateControls()
        let url = item.url
        queue.addOperation { [weak self] in
            let result = Result { try BatchNaming.fingerprint(url) }
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.loadingBookmarks = false
                switch result {
                case .success(let fingerprint):
                    item.proposal?.fingerprint = fingerprint
                    self.note.stringValue = "书签已保存 · " + url.lastPathComponent
                    if self.bookPreview.url == url {
                        self.bookPreview.load(url, page: self.bookPreview.page, refresh: true)
                    }
                    self.onRenamed?(url, url)
                case .failure(let error):
                    self.note.stringValue = "书签已保存，请重新扫描后再改名。" + error.localizedDescription
                    item.included = false
                }
                self.table.reloadData()
                self.updateControls()
            }
        }
    }

    private func requests() -> [(Int,BatchNameRequest)] {
        items.indices.filter { items[$0].included && items[$0].proposal != nil && items[$0].outcome == nil }.map { index in
            let item = items[index], p = item.proposal!
            return (index,BatchNameRequest(path:item.url.path,stem:item.stem,metadata:p.metadata,fingerprint:p.fingerprint))
        }
    }
    @discardableResult @objc func checkNames() -> Bool {
        guard !isApplying else { return false }; window.makeFirstResponder(table)
        let input = requests(), errors = BatchNaming.preflight(input.map(\.1)); planIssues = [:]
        for (row,message) in errors { planIssues[input[row].0] = message }
        for (index,_) in input {
            let item = items[index]
            if item.proposal!.metadata["书名",default:""].trimmingCharacters(in:.whitespaces).isEmpty { planIssues[index] = "请先填写书名。" }
            if !item.reviewed,!item.reviewReasons.isEmpty { planIssues[index] = "有差异或缺失项，请先人工核对并确认。" }
            if let blocked = blockedReason?(item.url) { planIssues[index] = blocked }
        }
        note.stringValue = input.isEmpty ? "尚未勾选图书。" : planIssues.isEmpty ? "\(input.count) 项检查通过；应用前还会检查原文件是否变化。" : "\(planIssues.count) 项需处理，尚未执行改名。可取消这些项目的勾选。"
        table.reloadData(); updateControls(); return !input.isEmpty && planIssues.isEmpty
    }
    @objc func applySelected() {
        guard !isApplying,!isAnalysing,!bookmarkFlowActive else { return }
        if window.hasDocumentDialog { window.bringDocumentDialogForward(); return }
        guard checkNames() else { return }
        let input = requests(), token = UUID(), backup = false, dates = preserveDates.state == .on
        generation = token; isApplying = true; stopRequested = false; updateControls(); loadDetails()
        // One item is completed at a time; stopping never leaves a partially moved item.
        applyNext(input,position:0,generation:token,backup:backup,dates:dates)
    }
    private func applyNext(_ input: [(Int,BatchNameRequest)],position: Int,generation token: UUID,backup: Bool,dates: Bool) {
        guard !closed,generation == token else { return }
        guard position<input.count,!stopRequested else { isApplying = false; note.stringValue = "已完成 \(position)/\(input.count) 项；每项结果已列出。"; updateControls(); loadDetails(); return }
        let (index,request) = input[position]; note.stringValue = "正在处理 \(position+1)/\(input.count)：\(items[index].url.lastPathComponent)"
        if let error = blockedReason?(items[index].url) { items[index].outcome = "未改名："+error; applyNext(input,position:position+1,generation:token,backup:backup,dates:dates); return }
        queue.addOperation { [weak self] in
            let result = Result { try BatchNaming.apply(request,backup:backup,preserveDates:dates) }
            DispatchQueue.main.async {
                guard let self,!self.closed,self.generation == token else { return }
                switch result {
                case .success(let url): let original = self.items[index].url; self.items[index].url = url; self.items[index].outcome = "已完成"; self.items[index].included = false; self.onRenamed?(original,url)
                case .failure(let error): self.items[index].outcome = "失败："+error.localizedDescription
                }
                self.table.reloadData(); self.applyNext(input,position:position+1,generation:token,backup:backup,dates:dates)
            }
        }
    }
    @objc private func ocrOptionChanged() { updateControls() }
    private func updateControls() {
        let count = items.filter { $0.included && $0.proposal != nil && $0.outcome == nil }.count
        inclusionSummary.stringValue = "共 \(items.count) 本 · 已勾选 \(count) 本"
        applyButton.title = count == 0 ? "保存并改名" : "保存并改名 \(count) 本"
        applyButton.isEnabled = !isAnalysing && !isApplying && !bookmarkFlowActive && count > 0
        supplementButton.isEnabled = selectedIndex != nil && !isAnalysing && !isApplying && !bookmarkFlowActive
        scanButton.isEnabled = !isAnalysing && !isApplying && !items.isEmpty; stopButton.isEnabled = isAnalysing || isApplying
        recognitionControls.language.isEnabled = !isAnalysing && !isApplying; recognitionControls.layout.isEnabled = !isAnalysing && !isApplying
        uniformStyle.isEnabled = !isApplying; useOCR.isEnabled = !isAnalysing && !isApplying; recursive.isEnabled = !isAnalysing && !isApplying
        forcePDFOCR.isEnabled = useOCR.isEnabled && useOCR.state == .on
        preserveDates.isEnabled = !isApplying
        let eligible = items.filter {$0.proposal != nil && $0.outcome == nil}
        selectionHeader.check.state = count == 0 ? .off : count == eligible.count ? .on : .mixed
        selectionHeader.check.isEnabled = !isApplying && !isAnalysing && !eligible.isEmpty
    }
    @objc func exportCSV() {
        guard !isApplying else { return }; let panel = NSSavePanel(); panel.title = "导出批量命名清单"; panel.nameFieldStringValue = "图书命名建议.csv"
        panel.begin { [weak self] response in guard response == .OK,let self,let url = panel.url else { return }; do { try BatchNaming.csv(self.items).write(to:url,atomically:true,encoding:.utf8) } catch { self.note.stringValue = error.localizedDescription } }
    }
    @objc func closeWindow() {
        if bookmarkFlowActive { window.bringDocumentDialogForward(); return }
        if isApplying { stop(); return }; closed = true; stopAnalysis(); bookPreview.load(nil); sourceWindow?.closeWindow(); templateWindow?.close(); window.orderOut(nil); onClosed?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeWindow(); return false }
}
