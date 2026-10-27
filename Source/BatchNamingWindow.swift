import AppKit

final class NamingSourceWindow: NSObject, NSWindowDelegate {
    let window = ChineseWindow(contentRect:NSRect(x:0,y:0,width:1080,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    let chooser = NSPopUpButton(), image = PageProofImageView(), text = ChineseTextView()
    let imageScroll = NSScrollView()
    private let url: URL, proposal: NamingProposal
    private let queue = OperationQueue()
    private var generation = UUID(), closed = false
    var onClosed: (() -> Void)?
    init(url: URL, proposal: NamingProposal) {
        self.url = url; self.proposal = proposal; super.init(); window.title = "核对原图与识别文字 — "+url.lastPathComponent; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:760,height:540); window.delegate = self
        for page in proposal.pages { chooser.addItem(withTitle:"\(page.role) · 物理\(page.physical) · \(page.file)") }
        chooser.target = self; chooser.action = #selector(pageChanged)
        image.imageScaling = .scaleProportionallyUpOrDown
        imageScroll.scrollerStyle = .overlay; imageScroll.documentView = image; imageScroll.hasVerticalScroller = true; imageScroll.hasHorizontalScroller = true; imageScroll.autohidesScrollers = true; imageScroll.allowsMagnification = true; imageScroll.minMagnification = 0.05; imageScroll.maxMagnification = 4; imageScroll.borderType = .bezelBorder
        imageScroll.widthAnchor.constraint(greaterThanOrEqualToConstant:350).isActive = true
        let scroll = ocrTextScroll(text,editable:false)
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin; split.addArrangedSubview(imageScroll); split.addArrangedSubview(scroll); scroll.widthAnchor.constraint(greaterThanOrEqualToConstant:320).isActive = true
        let close = NSButton(title:"关闭",target:self,action:#selector(closeWindow)); close.bezelStyle = .rounded
        let fit = NSButton(title:"适合整页",target:self,action:#selector(fitPage)), minus = NSButton(title:"缩小",target:self,action:#selector(zoomOut)), plus = NSButton(title:"放大",target:self,action:#selector(zoomIn))
        for button in [fit,minus,plus] { button.bezelStyle = .rounded }
        chooser.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let row = NSStackView(views:[chooser,NSView(),minus,plus,fit,close]); row.spacing = 10
        let root = NSStackView(views:[row,split]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        let host = NSView(); window.contentView = host; root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:host.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-16),row.widthAnchor.constraint(equalTo:root.widthAnchor),split.widthAnchor.constraint(equalTo:root.widthAnchor)])
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
    }
    func show(on parent: NSWindow) { NativeDialog.present(window,on:parent); window.contentView?.layoutSubtreeIfNeeded(); (imageScroll.superview as? NSSplitView)?.setPosition(window.contentView!.bounds.width*0.52,ofDividerAt:0); pageChanged() }
    @objc func pageChanged() {
        guard proposal.pages.indices.contains(chooser.indexOfSelectedItem) else { return }
        let page = proposal.pages[chooser.indexOfSelectedItem], token = UUID(); generation = token; queue.cancelAllOperations(); image.image = nil; text.string = page.text
        queue.addOperation { [weak self,url,proposal] in
            let result = Result { () throws -> CGImage in
                guard try BatchNaming.fingerprint(url) == proposal.fingerprint else { throw ReaderFailure("图书已变化，请重新分析。") }
                return try BookArchive(url:url).pageImage(at:page.physical-1)
            }
            DispatchQueue.main.async {
                guard let self,!self.closed,self.generation == token else { return }
                switch result { case .success(let cg): self.image.image = NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height)); self.image.frame = CGRect(x:0,y:0,width:cg.width,height:cg.height); self.fitPage()
                case .failure(let error): self.text.string = error.localizedDescription+"\n\n原识别文字：\n"+page.text }
            }
        }
    }
    @objc func fitPage() {
        guard let size = image.image?.size,size.width>0,size.height>0 else { return }
        let available = imageScroll.contentView.frame.size
        imageScroll.setMagnification(max(imageScroll.minMagnification,min(available.width/size.width,available.height/size.height)),centeredAt:CGPoint(x:size.width/2,y:size.height/2))
    }
    @objc func zoomIn() { imageScroll.magnification = min(imageScroll.maxMagnification,imageScroll.magnification*1.4) }
    @objc func zoomOut() { imageScroll.magnification = max(imageScroll.minMagnification,imageScroll.magnification/1.4) }
    @objc func closeWindow() { closed = true; generation = UUID(); queue.cancelAllOperations(); NativeDialog.dismiss(window); onClosed?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeWindow(); return false }
}

final class BatchSelectionHeader: NSTableHeaderView {
    let check = NSButton(checkboxWithTitle:"",target:nil,action:nil)
    override init(frame: NSRect) { super.init(frame:frame); check.allowsMixedState = true; check.toolTip = "全选或取消全部已分析的图书"; check.setAccessibilityLabel("选择全部图书"); addSubview(check) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() { super.layout(); guard tableView?.tableColumns.isEmpty == false else { return }; let rect = headerRect(ofColumn:0); check.frame = CGRect(x:rect.midX-9,y:rect.midY-9,width:18,height:18) }
}

final class BatchNamingWindow: NSObject, NSSplitViewDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let recognitionControls = RecognitionControls()
    let window = ChineseWindow(contentRect:NSRect(x:0,y:0,width:1380,height:940),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
    let table = NSTableView(), evidenceTable = NSTableView()
    let recursive = NSButton(checkboxWithTitle:"包含子文件夹",target:nil,action:nil)
    let useOCR = NSButton(checkboxWithTitle:"识别图像并交叉核对",target:nil,action:nil)
    let metadataHint = CenteredTextField(labelWithString:"改名时同步保存全部核对后的图书信息")
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
        super.init(); window.title = "批量规范命名"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:1100,height:790); window.delegate = self; window.identifier = .init("UVZBatchNaming")
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        useOCR.state = .on; preserveDates.state = AppSettings().preserveFileDates ? .on : .off
        uniformStyle.addItems(withTitles:namingStyles.map(\.title)); uniformStyle.selectItem(at:namingStyles.firstIndex(where:{$0.id == NamingPreferences.preferred()}) ?? 0); uniformStyle.target = self; uniformStyle.action = #selector(uniformStyleChanged)
        folderLabel.lineBreakMode = .byTruncatingMiddle; folderLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let choose = button("选择文件夹…",#selector(chooseFolder)); let rescan = button("重新扫描",#selector(rescanFolder))
        let top = NSStackView(views:[choose,folderLabel,rescan,recursive,useOCR]); top.spacing = 10
        scanButton.target = self; scanButton.action = #selector(analysePending); scanButton.bezelStyle = .rounded
        stopButton.target = self; stopButton.action = #selector(stop); stopButton.bezelStyle = .rounded
        let tools = NSStackView(views:[scanButton,stopButton,button("检查重名",#selector(checkNames)),NSView(),CenteredTextField(labelWithString:"命名格式"),uniformStyle,button("管理格式…",#selector(manageTemplates))]); tools.spacing = 8
        configure(table,columns:[("include","",34),("file","当前文件",170),("name","规范名称",260),("status","核对状态",120)])
        selectionHeader.check.target = self; selectionHeader.check.action = #selector(toggleAll); table.headerView = selectionHeader
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.hasHorizontalScroller = true; list.borderType = .bezelBorder
        for (key,field) in zip(fieldKeys,fields) { field.identifier = .init(key); field.delegate = self }
        let grid = NSGridView(views:fieldKeys.indices.map { [CenteredTextField(labelWithString:fieldKeys[$0]),fields[$0],fieldStates[$0]] }); grid.rowSpacing = 5; grid.columnSpacing = 8; grid.column(at:0).width = 66; grid.column(at:2).width = 90
        for state in fieldStates { state.font = .systemFont(ofSize:11); state.textColor = .secondaryLabelColor }
        for index in fieldKeys.indices { grid.row(at:index).height = 26 }
        reviewed.target = self; reviewed.action = #selector(reviewChanged)
        configure(evidenceTable,columns:[("field","字段",65),("value","来源值",240),("source","来源",90),("page","物理页",50)])
        evidenceTable.target = self; evidenceTable.doubleAction = #selector(adoptEvidence)
        let evidence = NSScrollView(); evidence.documentView = evidenceTable; evidence.hasVerticalScroller = true; evidence.hasHorizontalScroller = true; evidence.borderType = .bezelBorder; evidence.heightAnchor.constraint(greaterThanOrEqualToConstant:100).isActive = true
        let evidenceTools = NSStackView(views:[button("采用所选来源值",#selector(adoptEvidence)),button("原图与识别原文…",#selector(showSources)),NSView()]); evidenceTools.spacing = 8
        detailNote.font = .systemFont(ofSize:11); detailNote.textColor = .secondaryLabelColor; detailNote.maximumNumberOfLines = 4
        let detail = NSStackView(views:[CenteredTextField(labelWithString:"图书信息与来源核对"),grid,reviewed,detailNote,evidence,evidenceTools]); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 8
        for view in [grid,reviewed,detailNote,evidence,evidenceTools] { view.widthAnchor.constraint(equalTo:detail.widthAnchor).isActive = true }
        let split = NSSplitView(); split.delegate = self; split.isVertical = true; split.dividerStyle = .thin; split.addArrangedSubview(list); split.addArrangedSubview(detail)
        list.widthAnchor.constraint(greaterThanOrEqualToConstant:450).isActive = true; detail.widthAnchor.constraint(greaterThanOrEqualToConstant:490).isActive = true; split.heightAnchor.constraint(greaterThanOrEqualToConstant:400).isActive = true
        formatHint.font = .systemFont(ofSize:11); formatHint.textColor = .secondaryLabelColor
        finalName.delegate = self; finalName.identifier = .init("final-name"); finalName.placeholderString = "可手工修订最终名称，扩展名自动保留"
        let nameRow = NSStackView(views:[CenteredTextField(labelWithString:"最终名称"),finalName]); nameRow.spacing = 8
        let options = NSStackView(views:[metadataHint,preserveDates,NSView(),button("导出清单…",#selector(exportCSV))]); options.spacing = 12
        note.font = .systemFont(ofSize:11); note.textColor = .secondaryLabelColor
        applyButton.target = self; applyButton.action = #selector(applySelected); applyButton.bezelStyle = .rounded
        let footer = NSStackView(views:[note,NSView(),button("关闭",#selector(closeWindow)),applyButton]); footer.spacing = 10
        let recognitionOptions = NSStackView(views:[CenteredTextField(labelWithString:"文字识别"),recognitionControls.language,recognitionControls.layout,NSView()]); recognitionOptions.spacing = 8
        let root = NSStackView(views:[top,tools,recognitionOptions,split,formatHint,nameRow,options,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        let host = NSView(); window.contentView = host; root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:host.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-16)])
        for view in [top,tools,recognitionOptions,split,formatHint,nameRow,options,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        split.setContentHuggingPriority(.defaultLow,for:.vertical)
        window.contentView?.layoutSubtreeIfNeeded(); split.setPosition(680,ofDividerAt:0); loadDetails(); updateControls()
    }
    private func button(_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b }
    private func configure(_ table: NSTableView,columns: [(String,String,CGFloat)]) {
        for (id,title,width) in columns { let c = NSTableColumn(identifier:.init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.delegate = self; table.dataSource = self; table.rowHeight = 29; table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .noColumnAutoresizing
    }
    func show(choose: Bool = false) {
        if let screen = NSScreen.main?.visibleFrame { var frame = window.frame; frame.size.width = min(frame.width,screen.width-32); frame.size.height = min(frame.height,screen.height-32); frame.origin = CGPoint(x:screen.midX-frame.width/2,y:screen.midY-frame.height/2); window.setFrame(frame,display:false) }
        window.makeKeyAndOrderFront(nil); window.contentView?.layoutSubtreeIfNeeded(); fitTableColumns(); if choose { chooseFolder() }
    }
    func fitTableColumns() {
        guard table.tableColumns.count == 4,evidenceTable.tableColumns.count == 4 else { return }
        func fit(_ table: NSTableView,widths: [CGFloat]) {
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for (column,width) in zip(table.tableColumns,widths) { column.minWidth = 24; column.width = width }
            table.setFrameSize(NSSize(width:widths.reduce(0,+)+table.intercellSpacing.width*CGFloat(widths.count),height:table.frame.height))
        }
        let left = table.enclosingScrollView?.contentView.frame.width ?? 600, leftSpace = table.intercellSpacing.width*4+2
        let file = max(90,left*0.25),status: CGFloat = 96,check: CGFloat = 32
        fit(table,widths:[check,file,max(60,left-check-file-status-leftSpace),status])
        let right = evidenceTable.enclosingScrollView?.contentView.frame.width ?? 600, rightSpace = evidenceTable.intercellSpacing.width*4+2
        fit(evidenceTable,widths:[50,max(90,right-50-96-50-rightSpace),96,50]); selectionHeader.needsLayout = true
    }
    func splitViewDidResizeSubviews(_ notification: Notification) { fitTableColumns() }
    func windowDidResize(_ notification: Notification) { fitTableColumns() }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !isApplying else { return }; let updated = NamingPreferences.styles(); guard updated != namingStyles else { return }
        let selected = namingStyles.indices.contains(uniformStyle.indexOfSelectedItem) ? namingStyles[uniformStyle.indexOfSelectedItem].id : NamingPreferences.automatic
        namingStyles = updated; uniformStyle.removeAllItems(); uniformStyle.addItems(withTitles:updated.map(\.title)); uniformStyle.selectItem(at:updated.firstIndex(where:{$0.id == selected}) ?? 0)
        for item in items where !updated.contains(where:{$0.id == item.styleID}) { item.styleID = NamingPreferences.automatic }
        table.reloadData(); loadDetails()
    }
    @objc func chooseFolder() {
        guard !isApplying else { return }; let panel = NSOpenPanel(); panel.title = "选择待整理的图书文件夹"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in if response == .OK,let folder = panel.url { self?.loadFolder(folder) } }
    }
    @objc func rescanFolder() { if let folder,!isApplying { loadFolder(folder) } }
    func loadFolder(_ url: URL) {
        guard !isApplying else { return }; stopAnalysis(); folder = url; folderLabel.stringValue = url.path; folderLabel.toolTip = url.path
        items = []; selectedIndex = nil; planIssues = [:]; table.reloadData(); loadDetails()
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
        guard !isApplying,!isAnalysing else { return }
        let pending = items.indices.filter { items[$0].proposal == nil && items[$0].outcome == nil }
        guard !pending.isEmpty else { note.stringValue = "所有项目均已分析；如需重新读取，请重新扫描文件夹。"; return }
        let inputs = pending.map { ($0,items[$0].url) }, token = UUID(), ocr = useOCR.state == .on, options = recognitionControls.options
        generation = token; isAnalysing = true; updateControls()
        let operation = BlockOperation(); operation.addExecutionBlock { [weak self,weak operation] in
            for (position,input) in inputs.enumerated() {
                if operation?.isCancelled != false { break }; let (index,url) = input
                DispatchQueue.main.async { guard let self,!self.closed,self.generation == token else { return }; self.items[index].analysing = true; self.table.reloadData() }
                let result = Result { try autoreleasepool { try BatchNaming.analyse(url,ocr:ocr,options:options,cancelled:{operation?.isCancelled != false},progress:{ text in
                    DispatchQueue.main.async { guard let self,!self.closed,self.generation == token else { return }; self.note.stringValue = "\(position+1)/\(inputs.count) · \(url.lastPathComponent) · \(text)" }
                }) } }
                DispatchQueue.main.async {
                    guard let self,!self.closed,self.generation == token else { return }; self.items[index].analysing = false
                    switch result { case .success(let proposal): self.items[index].proposal = proposal; self.items[index].error = nil
                    case .failure(let error): self.items[index].error = error.localizedDescription }
                    self.table.reloadData(); if self.selectedIndex == index { self.loadDetails() }
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
            case "include": let check = NSButton(checkboxWithTitle:"",target:self,action:#selector(includeChanged(_:))); check.tag = row; check.state = item.included ? .on : .off; check.isEnabled = !isApplying && item.proposal != nil && item.outcome == nil; return check
            case "file": field.stringValue = item.url.lastPathComponent; field.toolTip = item.url.path
            case "name": field.stringValue = item.proposal == nil ? "" : item.displayName
            default: field.stringValue = planIssues[row] ?? item.status; if planIssues[row] != nil || item.error != nil { field.textColor = .systemRed } else if item.proposal?.reviewReasons.isEmpty == false && !item.reviewed { field.textColor = .systemOrange }
            }
        }
        if field.toolTip == nil { field.toolTip = field.stringValue }; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === table else { return }
        window.makeFirstResponder(table); selectedIndex = items.indices.contains(table.selectedRow) ? table.selectedRow : nil; loadDetails()
    }
    private func loadDetails() {
        let item = selectedIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }, proposal = item?.proposal
        for (index,key) in fieldKeys.enumerated() { fields[index].stringValue = proposal?.metadata[key] ?? ""; fields[index].isEnabled = proposal != nil && item?.outcome == nil && !isApplying; fieldStates[index].stringValue = proposal?.fieldStatus(key) ?? "" }
        currentEvidence = (proposal?.evidence ?? []).enumerated().sorted { a,b in let x = BookMetadata.fields.firstIndex(of:a.element.field) ?? 99,y = BookMetadata.fields.firstIndex(of:b.element.field) ?? 99; return x != y ? x<y : a.offset<b.offset }.map(\.element); evidenceTable.reloadData()
        formatHint.stringValue = proposal.map { "命名格式："+NamingPreferences.pattern(item?.styleID ?? NamingPreferences.automatic,metadata:$0.metadata) } ?? ""
        finalName.stringValue = item?.stem ?? ""; finalName.isEnabled = proposal != nil && item?.outcome == nil && !isApplying
        reviewed.state = item?.reviewed == true ? .on : .off; reviewed.isEnabled = proposal != nil && item?.outcome == nil && !isApplying
        detailNote.stringValue = proposal.map { $0.reviewReasons.isEmpty ? "来源信息未发现明显冲突；仍可查看原图核对。" : $0.reviewReasons.joined(separator:"；") } ?? "分析完成后可查看逐字段来源，手工修订或采用某一来源值。"
    }
    @objc func includeChanged(_ sender: NSButton) { guard !isApplying,items.indices.contains(sender.tag) else { return }; items[sender.tag].included = sender.state == .on; planIssues = [:]; table.reloadData(); updateControls() }
    @objc func toggleAll() {
        guard !isApplying,!isAnalysing else { return }
        let eligible = items.filter {$0.proposal != nil && $0.outcome == nil}
        let include = !eligible.isEmpty && !eligible.allSatisfy(\.included)
        for item in items { item.included = include && item.proposal != nil && item.outcome == nil }
        planIssues = [:]; table.reloadData(); updateControls()
    }
    @objc func reviewChanged() { guard let index = selectedIndex,!isApplying,items[index].outcome == nil else { return }; items[index].reviewed = reviewed.state == .on; table.reloadData(); updateControls() }
    @objc func uniformStyleChanged() {
        guard !isApplying,namingStyles.indices.contains(uniformStyle.indexOfSelectedItem) else { return }
        let id = namingStyles[uniformStyle.indexOfSelectedItem].id; AppSettings().set(id,"namingStyle")
        for item in items where item.outcome == nil { item.styleID = id; item.customName = nil }
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
        if field === finalName { items[index].customName = field.stringValue }
        else if let key = field.identifier?.rawValue,fieldKeys.contains(key) {
            items[index].proposal!.metadata[key] = key == "出版日期" ? BookMetadata.date(field.stringValue) : field.stringValue
            items[index].customName = nil; items[index].reviewed = false; reviewed.state = .off
            formatHint.stringValue = "命名格式："+NamingPreferences.pattern(items[index].styleID,metadata:items[index].proposal!.metadata); finalName.stringValue = items[index].stem
            for (i,key) in fieldKeys.enumerated() { fieldStates[i].stringValue = items[index].proposal!.fieldStatus(key) }
        }
        detailNote.stringValue = items[index].proposal!.reviewReasons.joined(separator:"；")
        planIssues = [:]; table.reloadData(); updateControls()
    }
    @objc func adoptEvidence() {
        guard let index = selectedIndex,!isApplying,items[index].outcome == nil,currentEvidence.indices.contains(evidenceTable.selectedRow) else { return }
        let value = currentEvidence[evidenceTable.selectedRow]; items[index].proposal?.metadata[value.field] = value.value; items[index].customName = nil; items[index].reviewed = false; planIssues = [:]; table.reloadData(); loadDetails()
    }
    @objc func showSources() {
        guard let index = selectedIndex,let proposal = items[index].proposal,!proposal.pages.isEmpty,!window.hasDocumentDialog else { return }
        let controller = NamingSourceWindow(url:items[index].url,proposal:proposal); sourceWindow = controller
        controller.onClosed = { [weak self] in self?.sourceWindow = nil }; controller.show(on:window)
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
            if !item.reviewed,!item.proposal!.reviewReasons.isEmpty { planIssues[index] = "有差异或缺失项，请先人工核对并确认。" }
            if let blocked = blockedReason?(item.url) { planIssues[index] = blocked }
        }
        note.stringValue = input.isEmpty ? "尚未勾选图书。" : planIssues.isEmpty ? "\(input.count) 项检查通过；应用前还会检查原文件是否变化。" : "\(planIssues.count) 项需处理，尚未执行改名。可取消这些项目的勾选。"
        table.reloadData(); updateControls(); return !input.isEmpty && planIssues.isEmpty
    }
    @objc func applySelected() {
        guard !isApplying,!isAnalysing else { return }
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
    private func updateControls() {
        applyButton.isEnabled = !isAnalysing && !isApplying && items.contains { $0.included && $0.proposal != nil && $0.outcome == nil }
        scanButton.isEnabled = !isAnalysing && !isApplying && !items.isEmpty; stopButton.isEnabled = isAnalysing || isApplying
        recognitionControls.language.isEnabled = !isAnalysing && !isApplying; recognitionControls.layout.isEnabled = !isAnalysing && !isApplying
        uniformStyle.isEnabled = !isApplying; useOCR.isEnabled = !isAnalysing && !isApplying; recursive.isEnabled = !isAnalysing && !isApplying
        preserveDates.isEnabled = !isApplying
        let eligible = items.filter {$0.proposal != nil && $0.outcome == nil}, count = eligible.filter(\.included).count
        selectionHeader.check.state = count == 0 ? .off : count == eligible.count ? .on : .mixed
        selectionHeader.check.isEnabled = !isApplying && !isAnalysing && !eligible.isEmpty
    }
    @objc func exportCSV() {
        guard !isApplying else { return }; let panel = NSSavePanel(); panel.title = "导出批量命名清单"; panel.nameFieldStringValue = "图书命名建议.csv"
        panel.begin { [weak self] response in guard response == .OK,let self,let url = panel.url else { return }; do { try BatchNaming.csv(self.items).write(to:url,atomically:true,encoding:.utf8) } catch { self.note.stringValue = error.localizedDescription } }
    }
    @objc func closeWindow() {
        if isApplying { stop(); return }; closed = true; stopAnalysis(); sourceWindow?.closeWindow(); templateWindow?.close(); window.orderOut(nil); onClosed?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeWindow(); return false }
}
