import AppKit

/// A single draft for book information, copyright OCR and naming.
final class RenameSheet: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSSplitViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let window = ChineseWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 880), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let nameField = CenteredTextField(), templateField = CenteredTextField(), style = NSPopUpButton()
    let keys = BookMetadata.fields.filter { $0 != "摘要" }
    let fields: [NSTextField]
    let abstractView = ChineseTextView(), recognitionText = ChineseTextView(), extractionText = ChineseTextView()
    let infoTable = NSTableView(), sourceTable = NSTableView(), infoSplit = NSSplitView()
    let saveMetadata = NSButton(checkboxWithTitle: "将图书信息保存到 BookInfo.dat", target: nil, action: nil)
    let preserveDates = NSButton(checkboxWithTitle: "保持文件日期不变（创建日期与修改日期）", target: nil, action: nil)
    private let message = CenteredTextField(wrappingLabelWithString: "")
    private let pageField = CenteredTextField(string: "1")
    private let evidenceArea = NSView(), evidenceMode = NSSegmentedControl()
    let recognitionControls = RecognitionControls()
    private let recognizeButton = NSButton(title: "识别并交叉核对", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存并重命名", target: nil, action: nil)
    private let book: BookArchive
    private(set) var recognitionRunning = false
    private(set) var reviewWindow: OCRTextReview?
    private var closed = false, busy = false
    private var original: [String: String]
    private var custom: [(String, String)]
    private var editedKeys: Set<String> = []
    private var extracted: [String: String] = [:]
    private(set) var recognitionSources: [NamingEvidence] = []
    private var recognitionNotes: [String] = []
    private var namingStyles = NamingPreferences.styles()
    private(set) var templateWindow: NamingTemplateWindow?
    private var nameEdited = false
    private var autoChanges: [String:(String,String)] = [:]
    private var selectionExplanations: [String:String] = [:]
    private var uncertainKeys = Set<String>()
    var currentPage = 0
    var cachedCopyrightText: [Int: String] = [:]
    var onRename: ((String, [String: String]?, Bool) throws -> Void)?
    var onClose: (() -> Void)?
    var metadataSnapshot: [String: String] {
        var values = Dictionary(uniqueKeysWithValues: zip(keys, fields.map(\.stringValue)))
        values["出版日期"] = BookMetadata.date(values["出版日期"] ?? "")
        values["摘要"] = abstractView.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        for (key, value) in custom { values[key.trimmingCharacters(in: .whitespacesAndNewlines)] = value }
        return values
    }
    init(book: BookArchive) {
        self.book = book
        let draft = FilenameDraft(book: book); original = draft.values
        fields = BookMetadata.fields.filter { $0 != "摘要" }.map { CenteredTextField(string: draft.values[$0] ?? "") }
        custom = draft.values.keys.filter { !BookMetadata.fields.contains($0) }.sorted().map { ($0, draft.values[$0]!) }
        super.init()
        window.title = "书籍信息与重命名 — " + book.title
        window.minSize = NSSize(width: 980, height: 790); window.isReleasedWhenClosed = false; window.delegate = self
        let host = NSView(); window.contentView = host
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18), root.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18), root.topAnchor.constraint(equalTo: host.topAnchor, constant: 16), root.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16)])
        let old = CenteredTextField(labelWithString: "当前文件：" + book.url.lastPathComponent); old.lineBreakMode = .byTruncatingMiddle; old.toolTip = book.url.path
        recognizeButton.target = self; recognizeButton.action = #selector(recognizeCopyright); recognizeButton.bezelStyle = .rounded
        pageField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let recognitionOptions = NSStackView(views:[CenteredTextField(labelWithString:"文字识别"),recognitionControls.language,recognitionControls.layout,NSView()]); recognitionOptions.spacing = 8
        let source = NSStackView(views: [recognizeButton, button("识别当前阅读页", #selector(recognizeCurrentPage)), CenteredTextField(labelWithString: "物理页"), pageField, button("识别此页", #selector(recognizeChosenPage)), NSView()]); source.spacing = 8
        for (key, field) in zip(keys, fields) { field.delegate = self; if key == "出版日期" { field.placeholderString = "YYYY.MM，例如 2026.03" } }
        let grid = NSGridView(views: zip(keys, fields).map { [CenteredTextField(labelWithString: $0.0), $0.1] }); grid.columnSpacing = 12; grid.rowSpacing = 6; grid.column(at: 0).width = 68
        for row in keys.indices { grid.row(at: row).height = 26 }
        grid.heightAnchor.constraint(equalToConstant: 282).isActive = true
        let abstract = ocrTextScroll(abstractView, editable: true); abstract.heightAnchor.constraint(equalToConstant: 64).isActive = true; abstractView.string = original["摘要"] ?? ""; abstractView.delegate = self
        for (key, label, width) in [("key", "自定义字段", 120.0), ("value", "内容", 300.0)] { let column = NSTableColumn(identifier: .init(key)); column.title = label; column.width = width; infoTable.addTableColumn(column) }
        infoTable.dataSource = self; infoTable.delegate = self; infoTable.rowHeight = 27; infoTable.usesAlternatingRowBackgroundColors = true; infoTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let customScroll = NSScrollView(); customScroll.documentView = infoTable; customScroll.hasVerticalScroller = true; customScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        let customTools = NSStackView(views: [button("新增字段", #selector(addInfo)), button("删除自定义字段", #selector(removeInfo)), NSView()]); customTools.spacing = 8
        let form = NSStackView(views: [grid, CenteredTextField(labelWithString: "摘要"), abstract, customScroll, customTools]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 8
        for view in [grid, abstract, customScroll, customTools] { view.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -12).isActive = true }
        evidenceMode.segmentCount = 3; evidenceMode.setLabel("比对结果", forSegment: 0); evidenceMode.setLabel("字段来源",forSegment:1); evidenceMode.setLabel("识别原文", forSegment: 2); evidenceMode.trackingMode = .selectOne; evidenceMode.selectedSegment = 0; evidenceMode.target = self; evidenceMode.action = #selector(evidenceChanged)
        let evidenceTools = NSStackView(views: [evidenceMode, NSView(), button("放大原文…", #selector(enlargeRecognition))]); evidenceTools.spacing = 8
        let extractionHint = CenteredTextField(wrappingLabelWithString: "自动比较已有信息与各页著录，优先采用明确且相互印证的内容。手工修改的字段保留；双击来源值可手动采用。保存前可撤回本次自动调整。")
        extractionHint.font = .systemFont(ofSize: 11); extractionHint.textColor = .secondaryLabelColor
        let right = NSStackView(views: [evidenceTools, evidenceArea, NSStackView(views:[button("重新比对原文", #selector(extractAgain)),button("撤回自动调整",#selector(undoAutomatic))]), extractionHint]); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        for view in [evidenceTools, evidenceArea, extractionHint] { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        infoSplit.isVertical = true; infoSplit.dividerStyle = .thin; infoSplit.delegate = self
        infoSplit.addArrangedSubview(FormScrollView(form)); infoSplit.addArrangedSubview(right)
        infoSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        style.addItems(withTitles:namingStyles.map(\.title)+["自定义（未保存）"]); style.selectItem(at:namingStyles.firstIndex(where:{$0.id == NamingPreferences.preferred()}) ?? 0); style.target = self; style.action = #selector(styleChanged)
        style.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let generator = NSStackView(views: [CenteredTextField(labelWithString: "命名格式"), style, button("生成规范名称", #selector(generateName)),button("管理格式…",#selector(manageTemplates))]); generator.spacing = 8
        templateField.stringValue = FilenameTemplate.presets[0]; templateField.delegate = self
        let hint = CenteredTextField(wrappingLabelWithString: "可用字段：" + BookMetadata.fields.map { "{" + $0 + "}" }.joined(separator: " ") + "。可编辑格式；扩展名保留为 ." + book.url.pathExtension)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        nameField.stringValue = book.url.deletingPathExtension().lastPathComponent
        let filename = NSStackView(views: [CenteredTextField(labelWithString: "新文件名"), nameField]); filename.spacing = 8
        saveMetadata.state = ["pdf","djvu","djv"].contains(book.url.pathExtension.lowercased()) ? .off : .on; preserveDates.state = AppSettings().preserveFileDates ? .on : .off
        saveMetadata.isHidden = book.storesNativeInformation
        let options = NSStackView(views: [saveMetadata, preserveDates]); options.spacing = 16
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        message.stringValue = book.storesNativeInformation ? "图书信息直接写入文档；保存并重命名会同时保存信息和文件名，不新建旁置文件。" : book.isZip ? "手动更改与识别补齐均为草稿。可仅保存信息，也可一起重命名；目录由独立窗口编辑。" : "图书信息保存在同名 .uvzmeta 文件夹内；重命名时一并迁移，文档内容保持原样。"
        saveButton.target = self; saveButton.action = #selector(rename); saveButton.bezelStyle = .rounded; saveButton.keyEquivalent = "\r"
        let infoButton = button("仅保存信息", #selector(saveInformation))
        let cancel = button("取消", #selector(close)); cancel.keyEquivalent = "\u{1b}"
        let bottom = NSStackView(views: [NSView(), cancel, infoButton, saveButton]); bottom.spacing = 10
        for view in [old, source, recognitionOptions, infoSplit, generator, templateField, hint, filename, options, message, bottom] { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        if !book.canRename { nameField.isEnabled = false; style.isEnabled = false; templateField.isEnabled = false; saveButton.isHidden = true; message.stringValue = "PDG 文件夹可在此保存 BookInfo.dat；文件夹名称请在访达中修改。" }
        for (id,title,width) in [("field","字段",65.0),("value","来源值",250.0),("source","来源",100.0),("page","物理页",55.0)] { let c = NSTableColumn(identifier:.init(id)); c.title = title; c.width = width; sourceTable.addTableColumn(c) }
        sourceTable.delegate = self; sourceTable.dataSource = self; sourceTable.target = self; sourceTable.doubleAction = #selector(adoptSource); sourceTable.rowHeight = 28; sourceTable.usesAlternatingRowBackgroundColors = true
        refreshName(); updateSummary(added: []); evidenceChanged()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b }
    func windowDidBecomeKey(_ notification: Notification) {
        let updated = NamingPreferences.styles(); guard updated != namingStyles else { return }
        let selected = selectedStyleID; namingStyles = updated; style.removeAllItems(); style.addItems(withTitles:updated.map(\.title)+["自定义（未保存）"])
        style.selectItem(at:selected == "draft" ? updated.count : updated.firstIndex(where:{$0.id == selected}) ?? 0); refreshName()
    }
    func prepareForDisplay() {
        window.contentView?.layoutSubtreeIfNeeded(); infoSplit.setPosition(infoSplit.bounds.width * 0.53, ofDividerAt: 0); pageField.integerValue = currentPage + 1
        if AppSettings().metadataOCR, book.pages.contains(where: { $0.key.group == 2 }) { recognizeCopyright() }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 400 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - 330 }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === templateField { style.selectItem(at:namingStyles.count) }
        if notification.object as? NSTextField === nameField { nameEdited = true }
        if let field = notification.object as? NSTextField, let index = fields.firstIndex(where: { $0 === field }) { editedKeys.insert(keys[index]); refreshName() }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? EditorField, custom.indices.contains(field.row) else { return }
        if field.column == "key" { custom[field.row].0 = field.stringValue } else { custom[field.row].1 = field.stringValue }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === sourceTable ? recognitionSources.count : custom.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sourceTable {
            let e = recognitionSources[row], key = tableColumn?.identifier.rawValue
            let text = key == "field" ? e.field : key == "value" ? e.value : key == "source" ? e.source+(e.inferred ? "（推测）" : "") : e.page.map(String.init) ?? ""
            let f = CenteredTextField(labelWithString:text); f.lineBreakMode = .byTruncatingMiddle; f.toolTip = text; return f
        }
        let field = EditorField(); field.row = row; field.column = tableColumn?.identifier.rawValue ?? "value"; field.delegate = self
        field.stringValue = field.column == "key" ? custom[row].0 : custom[row].1; field.isBordered = false; field.backgroundColor = .clear; return field
    }
    @objc func addInfo() { window.makeFirstResponder(nil); custom.append(("新字段", "")); infoTable.reloadData(); infoTable.selectRowIndexes(IndexSet(integer: custom.count-1), byExtendingSelection: false); infoTable.scrollRowToVisible(custom.count-1) }
    @objc func removeInfo() { window.makeFirstResponder(nil); if custom.indices.contains(infoTable.selectedRow) { custom.remove(at: infoTable.selectedRow); infoTable.reloadData() } }
    var selectedStyleID: String { namingStyles.indices.contains(style.indexOfSelectedItem) ? namingStyles[style.indexOfSelectedItem].id : "draft" }
    var selectedPattern: String { selectedStyleID == "draft" ? templateField.stringValue : NamingPreferences.pattern(selectedStyleID,metadata:metadataSnapshot) }
    @objc func styleChanged() { if selectedStyleID != "draft" { AppSettings().set(selectedStyleID,"namingStyle") }; nameEdited = false; refreshName() }
    private func refreshName() {
        if selectedStyleID != "draft" { templateField.stringValue = selectedPattern }
        if !nameEdited,let name = try? FilenameTemplate.render(selectedPattern,metadata:metadataSnapshot) { nameField.stringValue = name }
    }
    @objc func generateName() {
        window.makeFirstResponder(nil)
        do { nameField.stringValue = try FilenameTemplate.render(selectedPattern,metadata:metadataSnapshot); nameEdited = false; message.textColor = .secondaryLabelColor; message.stringValue = "规范名称已更新，保存后生效。自定义格式可在“管理格式”中保存。" }
        catch { show(error) }
    }
    @objc func manageTemplates() {
        guard !window.hasDocumentDialog else { return }
        let controller = NamingTemplateWindow(pattern:selectedPattern); templateWindow = controller
        controller.onChange = { [weak self] id in
            guard let self else { return }; let selected = id ?? self.selectedStyleID; self.namingStyles = NamingPreferences.styles(); self.style.removeAllItems(); self.style.addItems(withTitles:self.namingStyles.map(\.title)+["自定义（未保存）"]); self.style.selectItem(at:self.namingStyles.firstIndex(where:{$0.id == selected}) ?? 0); self.styleChanged()
        }
        controller.onClose = { [weak self] in self?.templateWindow = nil }; controller.show(on:window)
    }
    func textDidChange(_ notification: Notification) { if notification.object as? NSTextView === abstractView { editedKeys.insert("摘要") } }
    @objc func adoptSource() {
        guard recognitionSources.indices.contains(sourceTable.selectedRow) else { return }
        let e = recognitionSources[sourceTable.selectedRow]
        if let index = keys.firstIndex(of:e.field) { fields[index].stringValue = e.value }
        else if e.field == "摘要" { abstractView.string = e.value }
        editedKeys.insert(e.field); extracted[e.field] = e.value; selectionExplanations[e.field] = "手工采用"+e.source; uncertainKeys.remove(e.field); refreshName(); updateSummary(added:[])
    }
    @objc func undoAutomatic() {
        for (key,pair) in autoChanges where !editedKeys.contains(key) {
            if let index = keys.firstIndex(of:key),fields[index].stringValue == pair.1 { fields[index].stringValue = pair.0 }
            else if key == "摘要",abstractView.string == pair.1 { abstractView.string = pair.0 }
        }
        autoChanges = [:]; refreshName(); message.stringValue = "已撤回最近一次自动调整；手工修改保留。尚未保存的内容不会影响原书。"
    }
    @objc func evidenceChanged() {
        evidenceArea.subviews.forEach { $0.removeFromSuperview() }
        let scroll: NSScrollView
        if evidenceMode.selectedSegment == 1 { scroll = NSScrollView(); scroll.documentView = sourceTable; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder }
        else { scroll = evidenceMode.selectedSegment == 0 ? ocrTextScroll(extractionText,editable:false) : ocrTextScroll(recognitionText,editable:true) }
        scroll.translatesAutoresizingMaskIntoConstraints = false; evidenceArea.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: evidenceArea.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: evidenceArea.trailingAnchor), scroll.topAnchor.constraint(equalTo: evidenceArea.topAnchor), scroll.bottomAnchor.constraint(equalTo: evidenceArea.bottomAnchor)])
    }
    @objc func enlargeRecognition() {
        if reviewWindow == nil { reviewWindow = OCRTextReview(text: recognitionText.string) }
        reviewWindow?.text.string = recognitionText.string; reviewWindow?.show(above: window)
    }
    @objc func recognizeCopyright() { startRecognition(page: nil) }
    @objc func recognizeCurrentPage() { startRecognition(page: currentPage) }
    @objc func recognizeChosenPage() {
        guard (1...book.pages.count).contains(pageField.integerValue) else { message.stringValue = "物理页应在 1—\(book.pages.count) 之间。"; return }; startRecognition(page: pageField.integerValue - 1)
    }
    private func startRecognition(page: Int?) {
        guard !busy, !recognitionRunning else { return }; window.makeFirstResponder(nil); recognitionRunning = true
        recognizeButton.isEnabled = false; message.stringValue = "正在本机识别版权页、封面及书名页并核对…"; message.textColor = .secondaryLabelColor
        let source = book, cached = cachedCopyrightText, options = recognitionControls.options
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CopyrightMetadata.recognize(book: source, currentPage: page, cached: cached, options:options) }
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }; self.recognitionRunning = false; self.recognizeButton.isEnabled = true
                switch result {
                case .success(let result): self.recognitionText.string = result.text; self.reviewWindow?.text.string = result.text; self.recognitionSources = result.evidence; self.recognitionNotes = result.notes; self.applyRecognition(result.values)
                case .failure(let error): self.show(error)
                }
            }
        }
    }
    @objc func extractAgain() { guard !recognitionRunning, !busy else { return }; let analysis = BibliographicExtraction.analyse(recognitionText.string); recognitionSources = analysis.evidence.map { NamingEvidence(field:$0.field,value:$0.value,source:$0.source,page:nil,inferred:$0.inferred) }; recognitionNotes = analysis.notes; applyRecognition(analysis.values) }
    func applyRecognition(_ values: [String: String],evidence: [NamingEvidence]? = nil) {
        if let evidence { recognitionSources = evidence }
        window.makeFirstResponder(nil)
        if recognitionSources.isEmpty { recognitionSources = values.map { NamingEvidence(field:$0.key,value:$0.value,source:"出版信息",page:nil,inferred:false) } }
        let before = metadataSnapshot
        for key in keys where book.metadata[key,default:""].isEmpty && !before[key,default:""].isEmpty && !editedKeys.contains(key) && !recognitionSources.contains(where:{$0.field == key && $0.source == "文件名"}) {
            recognitionSources.append(NamingEvidence(field:key,value:before[key]!,source:"文件名",page:nil,inferred:true))
        }
        let selection = MetadataResolver.select(original:before,evidence:recognitionSources,locked:editedKeys)
        extracted = selection.values; selectionExplanations = selection.explanations; uncertainKeys = selection.uncertain; autoChanges = [:]
        for (key,value) in selection.values where value != before[key,default:""] && !editedKeys.contains(key) {
            autoChanges[key] = (before[key,default:""],value)
            if let index = keys.firstIndex(of:key) { fields[index].stringValue = value } else if key == "摘要" { abstractView.string = value }
        }
        // Show actual evidence on demand, grouped by field. Low-quality layout guesses remain labelled.
        recognitionSources = recognitionSources.enumerated().sorted { a,b in let x = BookMetadata.fields.firstIndex(of:a.element.field) ?? 99,y = BookMetadata.fields.firstIndex(of:b.element.field) ?? 99; return x != y ? x<y : a.offset<b.offset }.map(\.element)
        sourceTable.reloadData(); refreshName(); updateSummary(added:Set(autoChanges.keys)); evidenceMode.selectedSegment = 0; evidenceChanged()
        message.textColor = .secondaryLabelColor; message.stringValue = autoChanges.isEmpty ? "已自动比对；没有需要替换的字段。" : "已自动调整："+BookMetadata.fields.filter {autoChanges[$0] != nil}.joined(separator:"、")+"。请核对后保存，也可撤回调整。"
    }
    private func updateSummary(added: Set<String>) {
        extractionText.string = BookMetadata.fields.compactMap { key -> String? in
            guard let value = extracted[key],!value.isEmpty else { return nil }
            let change = autoChanges[key].map { "\n    原值："+($0.0.isEmpty ? "空缺" : $0.0) } ?? ""
            return key+"："+value+change+"\n    "+(selectionExplanations[key] ?? "等待比对")+(uncertainKeys.contains(key) ? "；请核对" : "")
        }.joined(separator:"\n\n")
        if extractionText.string.isEmpty { extractionText.string = "识别后在此显示逐项推荐值与采用理由；详细证据在“字段来源”，完整文字在“识别原文”。" }
        let usefulNotes = recognitionNotes.filter { !$0.contains("来源信息有差异") && !$0.contains("已参与自动比对") }
        if !usefulNotes.isEmpty { extractionText.string += "\n\n核对提示：\n"+Array(Set(usefulNotes)).sorted().joined(separator:"\n") }
    }
    private func show(_ error: Error) { message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    @objc func rename() { submit(rename: true) }
    @objc func saveInformation() { submit(rename: false) }
    private func submit(rename: Bool) {
        guard !busy, !recognitionRunning else { message.stringValue = "正在识别，请稍候或取消。"; return }; window.makeFirstResponder(nil)
        do {
            let names = keys + ["摘要"] + custom.map { $0.0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard Set(names).count == names.count else { throw ReaderFailure("自定义字段名称重复或与标准字段重名，请修改。") }
            let metadata = !rename || book.storesNativeInformation || saveMetadata.state == .on ? metadataSnapshot : nil
            if let metadata { var draft = BookEditDraft(book: book); draft.metadata = metadata; _ = try draft.encodedInfo() }
            let keep = preserveDates.state == .on
            busy = true
            defer { busy = false }
            try onRename?(rename ? nameField.stringValue : book.url.deletingPathExtension().lastPathComponent, metadata, keep)
            AppSettings().set(keep, "preserveFileDates"); busy = false; close()
        } catch { show(error) }
    }
    @objc func close() { guard !busy else { return }; closed = true; reviewWindow?.window.close(); templateWindow?.close(); NativeDialog.dismiss(window); onClose?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}
