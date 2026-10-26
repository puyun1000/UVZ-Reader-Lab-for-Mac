import AppKit

final class PageProofImageView: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric) }
}
final class PageRepairWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let window = ChineseWindow(contentRect:NSRect(x:0,y:0,width:1220,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    let pageTable = NSTableView(), findingTable = NSTableView()
    let typePopup = NSPopUpButton(), numberField = CenteredTextField(string:"1")
    let search = NSSearchField(), physicalField = CenteredTextField(string:"1")
    let preview = PageProofImageView()
    let backup = NSButton(checkboxWithTitle:"保存前备份",target:nil,action:nil)
    let preserveDates = NSButton(checkboxWithTitle:"保持文件日期",target:nil,action:nil)
    private let message = CenteredTextField(wrappingLabelWithString:"")
    private let evidenceLabel = CenteredTextField(wrappingLabelWithString:"点选检查结果可查看原图和核对依据。")
    private let saveButton = NSButton(title:"应用编码修改",target:nil,action:nil)
    private let scanButton = NSButton(title:"检查疑似错编",target:nil,action:nil)
    private let book: BookArchive
    private let extra: [InspectionTarget]
    private var rows: [Int] = []
    private(set) var pending: [Int:PageCorrection] = [:]
    private(set) var findings: [PageFinding]
    private(set) var isSaving = false
    private(set) var didScan = false
    private var closed = false, scanGeneration = UUID(), previewGeneration = UUID()
    private let scanQueue = OperationQueue(), previewQueue = OperationQueue()
    var onApplied: ((BookArchive,[Int:Int]) -> Void)?
    var onClosed: (() -> Void)?
    init(book: BookArchive, current: Int, extra: [InspectionTarget] = [], findings: [PageFinding]? = nil) {
        self.book = book; self.extra = extra; self.findings = findings ?? PageInspection.structural(book)
        super.init(); rows = Array(book.pages.indices)
        window.title = "页面编码校对 — " + book.title; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:1000,height:760); window.delegate = self
        scanQueue.maxConcurrentOperationCount = 1; scanQueue.qualityOfService = .utility
        previewQueue.maxConcurrentOperationCount = 1; previewQueue.qualityOfService = .userInitiated
        let intro = CenteredTextField(wrappingLabelWithString:"选择一页或多页，设置正确类型及起始页号后加入修改。多选按现有页面顺序连续编号。先核对右侧原图，再应用；已有目录会跟随原页面，图像内容不改变。")
        search.placeholderString = "按文件名或类型筛选"; search.target = self; search.action = #selector(filterRows)
        physicalField.widthAnchor.constraint(equalToConstant:60).isActive = true; physicalField.target = self; physicalField.action = #selector(goPhysical)
        let navigation = NSStackView(views:[search,CenteredTextField(labelWithString:"物理页"),physicalField,button("定位",#selector(goPhysical))]); navigation.spacing = 8
        configure(pageTable,columns:[("file","现有文件",185),("type","现有类型",65),("number","页号",65),("target","修改预览",190)])
        pageTable.allowsMultipleSelection = true
        let pages = NSScrollView(); pages.documentView = pageTable; pages.hasVerticalScroller = true; pages.hasHorizontalScroller = true; pages.borderType = .bezelBorder
        preview.imageScaling = .scaleProportionallyUpOrDown; preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        let left = NSStackView(views:[navigation,pages]); left.orientation = .vertical; left.alignment = .leading; left.spacing = 8
        navigation.widthAnchor.constraint(equalTo:left.widthAnchor).isActive = true; pages.widthAnchor.constraint(equalTo:left.widthAnchor).isActive = true
        let main = NSSplitView(); main.isVertical = true; main.dividerStyle = .thin; main.addArrangedSubview(left); main.addArrangedSubview(preview)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant:530).isActive = true; preview.widthAnchor.constraint(greaterThanOrEqualToConstant:320).isActive = true
        typePopup.addItems(withTitles:Array(PageAddressing.titles.prefix(8))); numberField.widthAnchor.constraint(equalToConstant:80).isActive = true
        let edits = NSStackView(views:[CenteredTextField(labelWithString:"改为"),typePopup,CenteredTextField(labelWithString:"起始页号"),numberField,button("加入修改",#selector(queueSelection)),button("撤回所选",#selector(removeSelection)),button("清空修改",#selector(clearChanges)),NSView()]); edits.spacing = 8
        configure(findingTable,columns:[("finding","检查结果（疑似问题须核对原图）",1120)])
        let issues = NSScrollView(); issues.documentView = findingTable; issues.hasVerticalScroller = true; issues.hasHorizontalScroller = true; issues.borderType = .bezelBorder; issues.heightAnchor.constraint(equalToConstant:120).isActive = true
        scanButton.target = self; scanButton.action = #selector(startScan); scanButton.bezelStyle = .rounded
        let checking = NSStackView(views:[scanButton,button("采用所选建议",#selector(useFinding)),CenteredTextField(labelWithString:"建议只加入修改列表，确认后才写入图书。"),NSView()]); checking.spacing = 8
        backup.state = AppSettings().backups ? .on : .off; preserveDates.state = AppSettings().preserveFileDates ? .on : .off
        saveButton.target = self; saveButton.action = #selector(applyChanges); saveButton.bezelStyle = .rounded
        let close = button("关闭",#selector(closeWindow)); close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views:[backup,preserveDates,NSView(),close,saveButton]); footer.spacing = 12
        message.font = .systemFont(ofSize:11); message.textColor = .secondaryLabelColor
        evidenceLabel.font = .systemFont(ofSize:12); evidenceLabel.textColor = .secondaryLabelColor
        let root = NSStackView(views:[intro,main,edits,checking,issues,evidenceLabel,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        let host = NSView(); window.contentView = host; root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:host.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-16),main.heightAnchor.constraint(greaterThanOrEqualToConstant:260)])
        for view in [intro,main,edits,checking,issues,evidenceLabel,message,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        main.setContentHuggingPriority(.defaultLow,for:.vertical)
        window.contentView?.layoutSubtreeIfNeeded(); main.setPosition(620,ofDividerAt:0)
        pageTable.selectRowIndexes(IndexSet(integer:min(max(0,current),rows.count-1)),byExtendingSelection:false)
        updateMessage()
    }
    private func button(_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b }
    private func configure(_ table: NSTableView, columns: [(String,String,CGFloat)]) {
        for (id,title,width) in columns { let column = NSTableColumn(identifier:.init(id)); column.title = title; column.width = width; table.addTableColumn(column) }
        table.dataSource = self; table.delegate = self; table.rowHeight = 29; table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }
    func show(on parent: NSWindow) { NativeDialog.present(window,on:parent); window.contentView?.layoutSubtreeIfNeeded(); selectPreview(); startScan() }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === pageTable ? rows.count : findings.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = CenteredTextField(labelWithString:""); field.lineBreakMode = .byTruncatingMiddle; field.font = .systemFont(ofSize:12)
        if tableView === findingTable { field.stringValue = findings[row].text; field.toolTip = findings[row].text; return field }
        let index = rows[row], page = book.pages[index]
        switch tableColumn?.identifier.rawValue {
        case "type": field.stringValue = PageAddressing.titles[page.key.group]
        case "number": field.stringValue = String(page.number)
        case "target": if let change = pending[index] { field.stringValue = PageAddressing.titles[change.group]+" "+String(change.number); field.textColor = .controlAccentColor }
        default: field.stringValue = page.name
        }
        field.toolTip = field.stringValue; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === pageTable { selectPreview() }
        else if findingTable.selectedRow >= 0 {
            let finding = findings[findingTable.selectedRow]; evidenceLabel.stringValue = finding.text
            if let physical = finding.page { selectPhysical(physical) }
        }
    }
    private var selected: [Int] { pageTable.selectedRowIndexes.map { rows[$0] }.sorted() }
    func selectPhysical(_ physical: Int) {
        guard book.pages.indices.contains(physical-1) else { return }
        if !rows.contains(physical-1) { search.stringValue = ""; rows = Array(book.pages.indices); pageTable.reloadData() }
        if let row = rows.firstIndex(of:physical-1) { pageTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); pageTable.scrollRowToVisible(row) }
    }
    @objc func goPhysical() { selectPhysical(physicalField.integerValue) }
    @objc func filterRows() {
        let value = search.stringValue.lowercased()
        rows = book.pages.indices.filter { value.isEmpty || book.pages[$0].name.lowercased().contains(value) || PageAddressing.titles[book.pages[$0].key.group].contains(value) }
        pageTable.reloadData(); if !rows.isEmpty { pageTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
    }
    private func selectPreview() {
        guard let index = selected.first else { preview.image = nil; return }
        physicalField.integerValue = index+1
        let page = book.pages[index], change = pending[index]
        typePopup.selectItem(at:min(change?.group ?? page.key.group,7)); numberField.integerValue = change?.number ?? page.number
        let generation = UUID(); previewGeneration = generation; previewQueue.cancelAllOperations(); preview.image = nil
        previewQueue.addOperation { [weak self,book] in
            let image = try? book.pageImage(at:index)
            DispatchQueue.main.async { guard let self,!self.closed,self.previewGeneration == generation else { return }; self.preview.image = image.map { NSImage(cgImage:$0,size:NSSize(width:$0.width,height:$0.height)) } }
        }
    }
    @objc func queueSelection() {
        guard !isSaving, !selected.isEmpty, let number = Int(numberField.stringValue.trimmingCharacters(in:.whitespaces)), number >= 0, number <= 999999-selected.count+1 else { message.stringValue = "请选择页面，并输入有效的起始页号。"; return }
        let group = typePopup.indexOfSelectedItem
        for (offset,index) in selected.enumerated() { pending[index] = PageCorrection(page:index+1,group:group,number:number+offset) }
        pageTable.reloadData(); updateMessage()
    }
    @objc func removeSelection() { guard !isSaving else { return }; for index in selected { pending.removeValue(forKey:index) }; pageTable.reloadData(); updateMessage() }
    @objc func clearChanges() { guard !isSaving else { return }; pending.removeAll(); pageTable.reloadData(); updateMessage() }
    @objc func useFinding() {
        guard !isSaving,findingTable.selectedRow >= 0, let change = findings[findingTable.selectedRow].suggestion else { message.stringValue = "此项没有可直接采用的建议，请选择图像后手动设置。"; return }
        selectPhysical(change.page); pending[change.page-1] = change; typePopup.selectItem(at:change.group); numberField.integerValue = change.number
        pageTable.reloadData(); updateMessage()
    }
    private func updateMessage() {
        saveButton.isEnabled = !pending.isEmpty && !isSaving
        guard !pending.isEmpty else { message.stringValue = "检查只读图书，不自动改编码。缺失的图像无法由改页号恢复。"; message.textColor = .secondaryLabelColor; return }
        do { _ = try PageCorrectionPlan(book:book,changes:Array(pending.values)); message.stringValue = "待应用 \(pending.count) 页。保存将重排页面并同步已有目录，阅读位置跟随原图像。"; message.textColor = .secondaryLabelColor }
        catch { message.stringValue = error.localizedDescription; message.textColor = .systemRed; saveButton.isEnabled = false }
    }
    @objc func startScan() {
        guard !isSaving else { return }; let generation = UUID(); scanGeneration = generation; scanQueue.cancelAllOperations(); scanButton.isEnabled = false; didScan = false
        message.stringValue = "正在核对目录与候选页面文字…"
        let operation = BlockOperation(); operation.addExecutionBlock { [weak self,weak operation,book,extra] in
            let result = Result { try PageInspection.scan(book,extra:extra,cancelled:{ operation?.isCancelled != false },progress:{ done,total in
                DispatchQueue.main.async { guard let self,!self.closed,self.scanGeneration == generation else { return }; self.message.stringValue = "已核对 \(done) / \(total) 个目录与候选页面；可随时关闭。" }
            }) }
            DispatchQueue.main.async {
                guard let self,!self.closed,self.scanGeneration == generation else { return }; self.scanButton.isEnabled = true; self.didScan = true
                switch result { case .success(let findings): self.findings = findings; self.findingTable.reloadData(); self.message.stringValue = "检查完成：\(findings.count) 条提示。请选中提示查看原图，建议须人工确认。"
                case .failure(let error): self.message.stringValue = "部分页面未能核对："+error.localizedDescription }
            }
        }; scanQueue.addOperation(operation)
    }
    @objc func applyChanges() {
        guard !isSaving,!pending.isEmpty else { return }
        let changes = Array(pending.values)
        do { _ = try PageCorrectionPlan(book:book,changes:changes) } catch { message.stringValue = error.localizedDescription; return }
        isSaving = true; saveButton.isEnabled = false; pageTable.isEnabled = false; findingTable.isEnabled = false; scanQueue.cancelAllOperations(); scanGeneration = UUID()
        message.stringValue = "正在校验图书并应用页面编码…"
        let backups = backup.state == .on, preserve = preserveDates.state == .on
        DispatchQueue.global(qos:.userInitiated).async { [weak self,book] in
            let result = Result { () throws -> (BookArchive,[Int:Int]) in
                let plan = try PageCorrectionPlan(book:book,changes:changes)
                _ = try book.correctPages(changes,backup:backups,preserveDates:preserve)
                let updated = try BookArchive(url:book.url); return (updated,try plan.indexMap(from:book,to:updated))
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.isSaving = false; self.pageTable.isEnabled = true; self.findingTable.isEnabled = true
                switch result {
                case .success(let (updated,map)): self.onApplied?(updated,map); self.closeWindow()
                case .failure(let error): self.message.stringValue = error.localizedDescription; self.message.textColor = .systemRed; self.saveButton.isEnabled = true; self.scanButton.isEnabled = true
                }
            }
        }
    }
    @objc func closeWindow() { guard !isSaving else { return }; closed = true; scanGeneration = UUID(); previewGeneration = UUID(); scanQueue.cancelAllOperations(); previewQueue.cancelAllOperations(); NativeDialog.dismiss(window); onClosed?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeWindow(); return false }
}
