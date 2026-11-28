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

final class BatchNamingWindow: NSObject, NSSplitViewDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
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
    private static let longKeys: Set<String> = ["参考文献格式", "摘要"]
    let fields = BookMetadata.fields.filter { !BatchNamingWindow.longKeys.contains($0) }.map { _ in CenteredTextField() }
    private let fieldKeys = BookMetadata.fields.filter { !BatchNamingWindow.longKeys.contains($0) }
    private let citationView = ChineseTextView(), abstractView = ChineseTextView()
    private let proofEntry = NamingProofEntry()
    private var listExpanded = false
    private let folderLabel = CenteredTextField(labelWithString:"尚未选择文件夹")
    private let note = CenteredTextField(wrappingLabelWithString:"选择文件夹后逐本分析。候选建议不会自动改名，需勾选并应用。")
    private let scanButton = NSButton(title:"分析未完成项",target:nil,action:nil)
    private let stopButton = NSButton(title:"停止",target:nil,action:nil)
    private let supplementButton = NSButton(title: "补书签…", target: nil, action: nil)
    private let inclusionSummary = CenteredTextField(labelWithString: "已勾选 0 本")
    private let originalName = CenteredTextField(labelWithString: "")
    let analysisStatus = CenteredTextField(wrappingLabelWithString: "")
    private let nameExtension = CenteredTextField(labelWithString: "")
    private let sources = NSPopUpButton()
    private weak var detailScroll: FormScrollView?
    private let split = NSSplitView()
    private let comparisonSplit = NSSplitView()
    let vectorPDF = NSButton(checkboxWithTitle: "矢量PDF", target: nil, action: nil)
    private let precisionRow = NSStackView()
    private let precisionLabel = CenteredTextField(labelWithString: "")
    private let resetVector = NSButton(title: "恢复自动", target: nil, action: nil)
    private(set) var referenceWindow: OnlineReferences?
    private(set) var bookmarkEditor: BookEditor?
    private var loadingBookmarks = false
    private var vectorOverrides: [URL: Bool] = [:]
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
        let formatRow = NamingFormLayout.row([listTitle, listHint, NSView(), button("展开书单", #selector(toggleBookList))])
        formatRow.spacing = 6
        let books = verticalStack([formatRow, list], spacing: 6)
        list.setContentHuggingPriority(.defaultLow, for: .vertical)

        for (key, field) in zip(fieldKeys, fields) {
            field.identifier = .init(key)
            field.delegate = self
        }

        reviewed.title = "已人工核对"
        reviewed.target = self
        reviewed.action = #selector(reviewChanged)
        supplementButton.target = self
        supplementButton.action = #selector(supplementBookmarks)
        supplementButton.bezelStyle = .rounded
        let heading = CenteredTextField(labelWithString: "图书信息")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailHeading = NSStackView(views: [heading, NSView(), supplementButton, reviewed])
        detailHeading.spacing = 7
        originalName.font = .systemFont(ofSize: 11)
        originalName.textColor = .secondaryLabelColor
        originalName.lineBreakMode = .byTruncatingMiddle
        analysisStatus.font = .systemFont(ofSize: 12)
        analysisStatus.maximumNumberOfLines = 2
        detailNote.font = .systemFont(ofSize: 11)
        detailNote.textColor = .secondaryLabelColor
        detailNote.maximumNumberOfLines = 3
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
        sources.addItems(withTitles: ["所有字段"] + BookMetadata.fields.map(BookMetadata.label))
        sources.target = self
        sources.action = #selector(sourceFilterChanged)
        let evidenceTools = NSStackView(views: [sources, NSView(), button("采用来源",#selector(adoptEvidence)),button("识别原文…",#selector(showSources))])
        evidenceTools.spacing = 5
        let groups = NamingFormLayout.groups(makeField, expanded: false, citationAction:
            NamingFormLayout.row([button("按当前信息生成引文", #selector(generateCitation)), NSView()]))
        let sourceSection = NamingDisclosure("比对来源",
            body: NamingFormLayout.column([detailNote, evidenceTools, evidence]), expanded: false)
        let detail = NamingFormLayout.column([originalName, analysisStatus] + groups + [NamingFormLayout.line(), sourceSection], spacing: 11)
        vectorPDF.target = self
        vectorPDF.action = #selector(vectorChanged)
        resetVector.target = self
        resetVector.action = #selector(restoreVectorSuggestion)
        resetVector.bezelStyle = .rounded
        precisionLabel.font = .systemFont(ofSize: 11)
        precisionLabel.textColor = .secondaryLabelColor
        precisionLabel.lineBreakMode = .byTruncatingTail
        precisionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [vectorPDF, precisionLabel, NSView(), resetVector] { precisionRow.addArrangedSubview(view) }
        precisionRow.spacing = 8
        let detailScroll = FormScrollView(detail)
        detailScroll.identifier = .init("book-information-form")
        self.detailScroll = detailScroll
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 156).isActive = true
        detailScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let naming = NamingFormLayout.column([
            NamingFormLayout.row([NamingFormLayout.heading("命名格式"), NSView(), button("管理格式…", #selector(manageTemplates))]),
            uniformStyle, precisionRow, nameRow
        ])
        naming.identifier = .init("book-naming-format")
        let information = verticalStack([detailHeading, detailScroll, NamingFormLayout.line(), naming], spacing: 8, leadingInset: 10)
        proofEntry.read = { [weak self] key in self?.selectedItem?.proposal?.metadata[key] ?? "" }
        proofEntry.write = { [weak self] key, value in self?.updateField(key, value: value, reflectEditor: true) }
        let original = NamingFormLayout.column([
            NamingFormLayout.heading("原页核对"), bookPreview, proofEntry
        ])
        bookPreview.titleVisible = false
        bookPreview.setContentHuggingPriority(.defaultLow, for: .vertical)
        comparisonSplit.isVertical = true
        comparisonSplit.dividerStyle = .thin
        comparisonSplit.delegate = self
        comparisonSplit.addArrangedSubview(original)
        comparisonSplit.addArrangedSubview(information)
        comparisonSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        comparisonSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(books)
        split.addArrangedSubview(comparisonSplit)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingMiddle
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inclusionSummary.font = .systemFont(ofSize: 12, weight: .medium)
        applyButton.toolTip = "保存勾选图书的图书信息并改名"
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
            split.setPosition(max(125, split.bounds.height * 0.27), ofDividerAt: 0)
            comparisonSplit.setPosition(comparisonSplit.bounds.width * 0.43, ofDividerAt: 0)
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
        max(proposed, splitView === split ? 106 : 340)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let limit = splitView === split ? split.bounds.height - split.dividerThickness - 324 : comparisonSplit.bounds.width - 385
        return min(proposed, limit)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) { fitTableColumns() }
    func windowDidResize(_ notification: Notification) {
        if splitPositioned {
            for panel in [split, comparisonSplit] {
                guard let first = panel.arrangedSubviews.first else { continue }
                let position = panel === split ? first.frame.height : first.frame.width
                let low = splitView(panel, constrainMinCoordinate: 0, ofSubviewAt: 0)
                let high = splitView(panel, constrainMaxCoordinate: .greatestFiniteMagnitude, ofSubviewAt: 0)
                if high >= low && (position < low || position > high) {
                    panel.setPosition(min(high, max(low, position)), ofDividerAt: 0)
                }
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
                case .success(let urls): self.items = urls.map { url in
                    let item = BatchNamingItem(url, styleID: self.namingStyles[self.uniformStyle.indexOfSelectedItem].id)
                    item.vectorOverride = self.vectorOverrides[url]
                    return item
                }; self.table.reloadData(); self.note.stringValue = "发现 \(urls.count) 本图书。"; if !urls.isEmpty { self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); self.analysePending() } else { self.updateControls() }
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
                DispatchQueue.main.async {
                    guard let self, !self.closed, self.generation == token else { return }
                    let item = self.items[index]
                    item.error = nil
                    item.analysing = true
                    self.reloadRows(IndexSet(integer: index))
                    if self.selectedIndex == index { self.updateAnalysisStatus(item) }
                }
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
    private func stopAnalysis() {
        generation = UUID()
        queue.cancelAllOperations()
        isAnalysing = false
        for item in items { item.analysing = false }
        updateAnalysisStatus(selectedItem)
        updateControls()
    }
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
        if let detailScroll { detailScroll.contentView.scroll(to: .zero); detailScroll.reflectScrolledClipView(detailScroll.contentView) }
        loadDetails()
    }
    private func loadDetails() {
        let item = selectedIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }, proposal = item?.proposal
        bookPreview.load(item?.url, page: item.flatMap { lastPages[$0.url] } ?? 0)
        originalName.stringValue = item.map { item in
            item.url.lastPathComponent + (item.isPDF && bookPreview.url == item.url && bookPreview.pageCount > 0
                ? " · PDF 物理 \(bookPreview.pageCount) 页" : "")
        } ?? ""
        originalName.toolTip = item?.url.path
        updateAnalysisStatus(item)
        let isFolder = item?.url.hasDirectoryPath == true || (try? item?.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = item?.url.pathExtension ?? ""
        nameExtension.stringValue = isFolder || ext.isEmpty ? "" : "." + ext
        supplementButton.isEnabled = item != nil && !isAnalysing && !isApplying && !bookmarkFlowActive
        let editable = proposal != nil && item?.outcome == nil && !isApplying
        for (index, key) in fieldKeys.enumerated() {
            fields[index].stringValue = proposal?.metadata[key] ?? ""
            fields[index].isEnabled = editable
            fields[index].toolTip = proposal?.fieldStatus(key)
        }
        citationView.string = proposal?.metadata["参考文献格式"] ?? ""
        abstractView.string = proposal?.metadata["摘要"] ?? ""
        citationView.isEditable = editable
        abstractView.isEditable = editable
        proofEntry.adopt.isEnabled = editable
        proofEntry.value.isEnabled = editable
        proofEntry.refresh()
        updateEvidence(proposal)
        refreshPrecision(item)
        finalName.stringValue = item?.stem ?? ""; finalName.toolTip = item?.displayName; finalName.isEnabled = proposal != nil && item?.outcome == nil && !isApplying
        reviewed.state = item?.reviewed == true ? .on : .off; reviewed.isEnabled = proposal != nil && item?.outcome == nil && !isApplying
        updateDetailNote(item)
    }

    private func updateAnalysisStatus(_ item: BatchNamingItem?) {
        let message: String
        if let item {
            if item.proposal != nil { message = "" }
            else if let error = item.error { message = "分析失败：" + error }
            else if item.analysing { message = "正在分析这本书…" }
            else { message = "尚未分析。可使用「分析未完成项」继续。" }
        } else { message = "从书单选择一本图书。" }
        analysisStatus.stringValue = message
        analysisStatus.toolTip = message.isEmpty ? nil : message
        analysisStatus.textColor = item?.error == nil ? .secondaryLabelColor : .systemRed
        analysisStatus.isHidden = message.isEmpty
    }

    private func refreshPrecision(_ item: BatchNamingItem?) {
        let pdf = item?.isPDF == true
        // Hide the entire row. Its otherwise-empty spacer can take the height of the form.
        precisionRow.isHidden = !pdf
        vectorPDF.isEnabled = pdf && item?.proposal != nil && item?.outcome == nil && !isApplying
        resetVector.isEnabled = vectorPDF.isEnabled && item?.vectorOverride != nil
        vectorPDF.state = item?.isMarkedVector == true ? .on : .off
        let detail = item?.proposal?.precision?.detail ?? "等待分析"
        precisionLabel.stringValue = item?.vectorOverride != nil ? "人工选择 · " + detail : detail
        precisionLabel.toolTip = precisionLabel.stringValue
    }

    @objc func vectorChanged() { setVectorOverride(vectorPDF.state == .on) }
    @objc func restoreVectorSuggestion() { setVectorOverride(nil) }
    private func setVectorOverride(_ value: Bool?) {
        guard let index = selectedIndex, items.indices.contains(index), vectorPDF.isEnabled else { return }
        let item = items[index]
        item.vectorOverride = value
        vectorOverrides[item.url] = value
        item.included = true
        let changed = IndexSet(planIssues.keys).union(IndexSet(integer: index))
        planIssues.removeAll()
        refreshPrecision(item)
        finalName.stringValue = item.stem
        reloadRows(changed, columns: IndexSet([0, 2, 3]))
        updateControls()
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
        sourceField = BookMetadata.fields.indices.contains(index) ? BookMetadata.fields[index] : nil
        updateEvidence(selectedIndex.flatMap { items[$0].proposal })
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let key = field.identifier?.rawValue, let index = BookMetadata.fields.firstIndex(of: key) else { return }
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
    private var selectedItem: BatchNamingItem? {
        guard let index = selectedIndex, items.indices.contains(index) else { return nil }
        return items[index]
    }

    private func makeField(_ key: String) -> NSView {
        if let index = fieldKeys.firstIndex(of: key) { return NamingFormLayout.field(key, fields[index]) }
        let text = key == "摘要" ? abstractView : citationView
        let scroll = ocrTextScroll(text, editable: true, font: .systemFont(ofSize: 13))
        text.delegate = self
        text.setAccessibilityLabel(BookMetadata.label(key))
        scroll.heightAnchor.constraint(equalToConstant: key == "摘要" ? 76 : 58).isActive = true
        return NamingFormLayout.field(key, scroll)
    }

    @objc private func toggleBookList(_ sender: NSButton) {
        listExpanded.toggle()
        let high = splitView(split, constrainMaxCoordinate: .greatestFiniteMagnitude, ofSubviewAt: 0)
        let wanted = max(125, split.bounds.height * (listExpanded ? 0.60 : 0.27))
        split.setPosition(max(106, min(high, wanted)), ofDividerAt: 0)
        sender.title = listExpanded ? "收起书单" : "展开书单"
    }

    @objc private func generateCitation() {
        guard let info = selectedItem?.proposal?.metadata,
              let draft = BookMetadata.citationDraft(info) else { return }
        updateField("参考文献格式", value: draft, reflectEditor: true)
    }

    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextView else { return }
        if text === abstractView { updateField("摘要", value: text.string) }
        else if text === citationView { updateField("参考文献格式", value: text.string) }
    }

    private func updateField(_ key: String, value: String, reflectEditor: Bool = false) {
        guard let index = selectedIndex, let item = selectedItem, item.proposal != nil,
              item.outcome == nil, !isApplying else { return }
        let normalized = BookMetadata.canonical([key: value])[key] ?? value
        item.proposal?.metadata[key] = normalized.components(separatedBy: .newlines).joined(separator: " ")
        if reflectEditor {
            if let fieldIndex = fieldKeys.firstIndex(of: key) { fields[fieldIndex].stringValue = normalized }
            else if key == "摘要" { abstractView.string = normalized }
            else if key == "参考文献格式" { citationView.string = normalized }
        }
        item.reviewed = true
        item.included = true
        reviewed.state = .on
        let stem = item.stem
        if finalName.stringValue != stem { finalName.stringValue = stem }
        proofEntry.refresh()
        updateDetailNote(item)
        reloadEditedRows(index)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let index = selectedIndex, let item = selectedItem, let field = notification.object as? NSTextField,
              item.proposal != nil, item.outcome == nil, !isApplying else { return }
        if field === finalName {
            let raw = item.isPDF ? VectorFilename.render(field.stringValue, marked: false) : field.stringValue
            item.customName = raw.isEmpty ? nil : raw
            reloadEditedRows(index)
        } else if let key = field.identifier?.rawValue, fieldKeys.contains(key) {
            updateField(key, value: field.stringValue)
        }
    }

    private func reloadEditedRows(_ index: Int) {
        var rows = IndexSet(planIssues.keys)
        rows.insert(index)
        planIssues.removeAll()
        reloadRows(rows, columns: IndexSet([0, 2, 3]))
        updateControls()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let index = selectedIndex,
              items.indices.contains(index) else { return }
        if field.identifier?.rawValue == "作者", let value = items[index].proposal?.metadata["作者"] { field.stringValue = value }
        guard field === finalName else { return }
        finalName.stringValue = items[index].stem
        finalName.toolTip = items[index].displayName
    }

    @objc func adoptEvidence() {
        guard let index = selectedIndex,!isApplying,items[index].outcome == nil,currentEvidence.indices.contains(evidenceTable.selectedRow) else { return }
        let value = currentEvidence[evidenceTable.selectedRow]
        updateField(value.field, value: value.value, reflectEditor: true)
        if let page = value.page { bookPreview.showPage(page - 1) }
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
                        editor.show(on: self.window)
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
            return (index,BatchNameRequest(path:item.url.path,stem:item.stem,metadata:BookMetadata.canonical(p.metadata),fingerprint:p.fingerprint))
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
        if let index = selectedIndex, items.indices.contains(index) { refreshPrecision(items[index]) }
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
