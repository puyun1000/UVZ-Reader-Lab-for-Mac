import AppKit

/// A single draft for book information, copyright OCR and naming.
final class RenameSheet: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSSplitViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let window = ChineseWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 880), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let vectorPDF = NSButton(checkboxWithTitle: "矢量PDF", target: nil, action: nil)
    private let precisionLabel = CenteredTextField(labelWithString: "")
    private var precision: PDFPrecision.Result?
    private var vectorOverride: Bool?
    private var isPDF: Bool { book.url.pathExtension.lowercased() == "pdf" }
    private var markedAtOpen: Bool { VectorFilename.hasMarker(book.url.deletingPathExtension().lastPathComponent) }
    let nameField = CenteredTextField(), templateField = CenteredTextField(), style = NSPopUpButton()
    private static let longFields = ["参考文献格式", "摘要"]
    let keys = BookMetadata.fields.filter { !RenameSheet.longFields.contains($0) }
    let fields: [NSTextField]
    let citationView = ChineseTextView(), abstractView = ChineseTextView(), recognitionText = ChineseTextView(), extractionText = ChineseTextView()
    let infoTable = NSTableView(), sourceTable = NSTableView(), infoSplit = NSSplitView()
    let saveMetadata = NSButton(checkboxWithTitle: "将图书信息保存到 BookInfo.dat", target: nil, action: nil)
    let preserveDates = NSButton(checkboxWithTitle: "保持文件日期不变（创建日期与修改日期）", target: nil, action: nil)
    private let message = CenteredTextField(wrappingLabelWithString: "")
    private let evidenceArea = NSView(), evidenceMode = NSSegmentedControl()
    let originalPreview = BatchBookPreview()
    private let evidencePopover = NSPopover()
    private let recognitionPopover = NSPopover()
    private let resultsButton = NSButton(title: "识别结果…", target: nil, action: nil)
    private let resetVector = NSButton(title: "恢复自动", target: nil, action: nil)
    private let templateHelp = CenteredTextField(wrappingLabelWithString: "")
    private let footerStatus = NSStackView()
    let proofEntry = NamingProofEntry()
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
        for key in Self.longFields {
            values[key] = longValue(key).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        for (key, value) in custom { values[key.trimmingCharacters(in: .whitespacesAndNewlines)] = value }
        return BookMetadata.canonical(values)
    }
    init(book: BookArchive) {
        self.book = book
        let draft = FilenameDraft(book: book); original = draft.values
        fields = BookMetadata.fields.filter { !RenameSheet.longFields.contains($0) }.map { CenteredTextField(string: draft.values[$0] ?? "") }
        custom = draft.values.keys.filter { !BookMetadata.fields.contains($0) }.sorted().map { ($0, draft.values[$0]!) }
        super.init()
        window.title = "图书信息与重命名 — " + book.title
        window.minSize = NSSize(width: 900, height: 650)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSView()
        window.contentView = host
        let physical = isPDF ? " · PDF 物理 \(book.pages.count) 页" : ""
        let old = CenteredTextField(labelWithString: book.url.lastPathComponent + physical)
        old.lineBreakMode = .byTruncatingMiddle
        old.toolTip = book.url.path
        old.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        recognizeButton.target = self
        recognizeButton.action = #selector(recognizeCopyright)
        recognizeButton.bezelStyle = .rounded
        let top = row([old, NSView(), recognizeButton, button("识别选项…", #selector(showRecognitionOptions))])

        for (key, field) in zip(keys, fields) {
            field.delegate = self
            field.identifier = .init(key)
            field.setAccessibilityLabel(BookMetadata.label(key))
        }
        fields[keys.firstIndex(of: "出版日期")!].placeholderString = "如 2021.08"
        fields[keys.firstIndex(of: "版本说明")!].placeholderString = "如 修订版"
        fields[keys.firstIndex(of: "数字版次")!].placeholderString = "如 第2版"
        let quote = row([button("按当前信息生成引文", #selector(generateCitation)), NSView()])
        let groups = NamingFormLayout.groups(makeField, expanded: true, citationAction: quote)
        let form = column(groups + [
            NamingFormLayout.line(),
            NamingDisclosure("自定义字段", body: configureCustomFields(), expanded: !custom.isEmpty)
        ], spacing: 12)
        let scroll = FormScrollView(form)
        scroll.identifier = .init("book-information-form")
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        resultsButton.target = self
        resultsButton.action = #selector(showEvidence)
        resultsButton.bezelStyle = .rounded
        resultsButton.isEnabled = false
        let proof = column([
            row([heading("原页核对"), NSView(), button("识别此页", #selector(recognizeChosenPage)), resultsButton]),
            originalPreview, proofEntry
        ])
        proof.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 0)
        originalPreview.titleVisible = false
        proofEntry.read = { [weak self] key in self?.metadataSnapshot[key] ?? "" }
        proofEntry.write = { [weak self] key, value in
            guard let self else { return }
            self.setValue(value, for: key)
            self.editedKeys.insert(key)
            self.refreshName()
        }
        proofEntry.refresh()
        originalPreview.setContentHuggingPriority(.defaultLow, for: .vertical)
        infoSplit.isVertical = true
        infoSplit.dividerStyle = .thin
        infoSplit.delegate = self
        infoSplit.addArrangedSubview(scroll)
        infoSplit.addArrangedSubview(proof)
        infoSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        infoSplit.setContentHuggingPriority(.defaultLow, for: .vertical)

        style.addItems(withTitles: namingStyles.map(\.title) + ["自定义（未保存）"])
        style.selectItem(at: namingStyles.firstIndex(where: { $0.id == NamingPreferences.preferred() }) ?? 0)
        style.target = self
        style.action = #selector(styleChanged)
        style.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        vectorPDF.target = self
        vectorPDF.action = #selector(vectorChanged)
        vectorPDF.isHidden = !isPDF
        precisionLabel.font = .systemFont(ofSize: 11)
        precisionLabel.textColor = .secondaryLabelColor
        precisionLabel.lineBreakMode = .byTruncatingTail
        precisionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resetVector.target = self
        resetVector.action = #selector(restoreVectorSuggestion)
        resetVector.bezelStyle = .rounded
        let vectorLine = row([vectorPDF, precisionLabel, NSView(), resetVector])
        vectorLine.isHidden = !isPDF
        templateField.delegate = self
        templateField.setAccessibilityLabel("自定义命名格式")
        templateHelp.stringValue = BookMetadata.fields.map { "{" + $0 + "}" }.joined(separator: " ")
        templateHelp.font = .systemFont(ofSize: 11)
        templateHelp.textColor = .secondaryLabelColor
        nameField.delegate = self
        nameField.setAccessibilityLabel("最终文件名")
        nameField.stringValue = book.url.deletingPathExtension().lastPathComponent
        let ext = book.url.pathExtension
        let extensionLabel = CenteredTextField(labelWithString: ext.isEmpty ? "" : "." + ext)
        extensionLabel.textColor = .secondaryLabelColor
        extensionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let naming = column([
            row([heading("命名格式"), NSView(), button("管理格式…", #selector(manageTemplates))]),
            style, templateField, templateHelp, vectorLine,
            row([nameField, extensionLabel, button("重新生成", #selector(generateName))])
        ])
        naming.identifier = .init("book-naming-format")
        saveMetadata.state = book.storesNativeInformation ? .off : .on
        saveMetadata.isHidden = book.storesNativeInformation
        preserveDates.title = "保持文件日期"
        preserveDates.state = AppSettings().preserveFileDates ? .on : .off
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let undo = button("撤回自动调整", #selector(undoAutomatic))
        footerStatus.addArrangedSubview(message)
        footerStatus.addArrangedSubview(NSView())
        footerStatus.addArrangedSubview(undo)
        footerStatus.spacing = 8
        footerStatus.isHidden = true
        saveButton.target = self
        saveButton.action = #selector(rename)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancel = button("取消", #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        let bottom = row([preserveDates, saveMetadata, NSView(), cancel, button("仅保存信息", #selector(saveInformation)), saveButton])
        let root = column([top, NamingFormLayout.line(), infoSplit, NamingFormLayout.line(), naming, footerStatus, bottom], spacing: 10)
        root.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14)
        ])
        if !book.canRename {
            nameField.isEnabled = false
            style.isEnabled = false
            templateField.isEnabled = false
            saveButton.isHidden = true
            naming.isHidden = true
        }
        configureEvidence()
        for (id,title,width) in [("field","字段",65.0),("value","来源值",250.0),("source","来源",100.0),("page","物理页",55.0)] { let c = NSTableColumn(identifier:.init(id)); c.title = title; c.width = width; sourceTable.addTableColumn(c) }
        sourceTable.delegate = self; sourceTable.dataSource = self; sourceTable.target = self; sourceTable.doubleAction = #selector(adoptSource); sourceTable.rowHeight = 28; sourceTable.usesAlternatingRowBackgroundColors = true
        refreshName(); updateSummary(added: []); evidenceChanged()
    }
    private func row(_ views: [NSView]) -> NSStackView { NamingFormLayout.row(views) }
    private func column(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView { NamingFormLayout.column(views, spacing: spacing) }
    private func heading(_ title: String) -> NSTextField { NamingFormLayout.heading(title) }

    private func longValue(_ key: String) -> String {
        key == "参考文献格式" ? citationView.string : key == "摘要" ? abstractView.string : ""
    }

    private func setValue(_ value: String, for key: String) {
        if let index = keys.firstIndex(of: key) { fields[index].stringValue = value }
        else if key == "参考文献格式" { citationView.string = value }
        else if key == "摘要" { abstractView.string = value }
    }

    private func makeField(_ key: String) -> NSView {
        if let index = keys.firstIndex(of: key) { return NamingFormLayout.field(key, fields[index]) }
        let view = key == "摘要" ? abstractView : citationView
        let scroll = ocrTextScroll(view, editable: true, font: .systemFont(ofSize: 13))
        view.delegate = self
        view.string = original[key] ?? ""
        view.setAccessibilityLabel(BookMetadata.label(key))
        scroll.heightAnchor.constraint(equalToConstant: key == "摘要" ? 76 : 58).isActive = true
        return NamingFormLayout.field(key, scroll)
    }

    private func configureCustomFields() -> NSView {
        for (key, label, width) in [("key", "自定义字段", 120.0), ("value", "内容", 280.0)] {
            let column = NSTableColumn(identifier: .init(key))
            column.title = label
            column.width = width
            infoTable.addTableColumn(column)
        }
        infoTable.dataSource = self
        infoTable.delegate = self
        infoTable.rowHeight = 27
        infoTable.usesAlternatingRowBackgroundColors = true
        infoTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = infoTable
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        return column([scroll, row([button("新增字段", #selector(addInfo)), button("删除自定义字段", #selector(removeInfo)), NSView()])])
    }

    private func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func configureEvidence() {
        evidenceMode.segmentCount = 3
        for (i, label) in ["比对结果", "字段来源", "识别原文"].enumerated() {
            evidenceMode.setLabel(label, forSegment: i)
        }
        evidenceMode.selectedSegment = 0
        evidenceMode.target = self
        evidenceMode.action = #selector(evidenceChanged)
        let pane = column([
            row([evidenceMode, NSView(), button("放大原文…", #selector(enlargeRecognition))]),
            evidenceArea,
            row([NSView(), button("重新比对原文", #selector(extractAgain)), button("撤回自动调整", #selector(undoAutomatic))])
        ])
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 590, height: 430))
        pin(pane, in: controller.view, inset: 12)
        evidencePopover.contentViewController = controller
        evidencePopover.contentSize = NSSize(width: 590, height: 430)
        evidencePopover.behavior = .semitransient
    }

    @objc func showEvidence() {
        if evidencePopover.isShown { evidencePopover.performClose(nil); return }
        evidencePopover.show(relativeTo: resultsButton.bounds, of: resultsButton, preferredEdge: .maxY)
    }

    @objc private func showRecognitionOptions(_ sender: NSButton) {
        if recognitionPopover.isShown { recognitionPopover.performClose(nil); return }
        if recognitionPopover.contentViewController == nil {
            let options = column([
                row([CenteredTextField(labelWithString: "识别语言"), recognitionControls.language]),
                row([CenteredTextField(labelWithString: "版式"), recognitionControls.layout])
            ])
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 82))
            pin(options, in: controller.view, inset: 12)
            recognitionPopover.contentViewController = controller
            recognitionPopover.contentSize = controller.view.bounds.size
            recognitionPopover.behavior = .transient
        }
        recognitionPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func generateCitation() {
        window.makeFirstResponder(nil)
        guard let draft = BookMetadata.citationDraft(metadataSnapshot) else { show(ReaderFailure("请先填写书名。")); return }
        citationView.string = draft
        editedKeys.insert("参考文献格式")
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b }
    func windowDidBecomeKey(_ notification: Notification) {
        let updated = NamingPreferences.styles(); guard updated != namingStyles else { return }
        let selected = selectedStyleID; namingStyles = updated; style.removeAllItems(); style.addItems(withTitles:updated.map(\.title)+["自定义（未保存）"])
        style.selectItem(at:selected == "draft" ? updated.count : updated.firstIndex(where:{$0.id == selected}) ?? 0); refreshName()
    }
    @objc private func restoreVectorSuggestion() {
        vectorOverride = nil
        updateVectorName()
    }
    @objc private func vectorChanged() {
        vectorOverride = vectorPDF.state == .on
        updateVectorName()
    }

    private func updateVectorName() {
        let marked = vectorOverride ?? (markedAtOpen || precision?.kind == .vector)
        vectorPDF.state = marked ? .on : .off
        resetVector.isEnabled = vectorOverride != nil
        if vectorOverride != nil { precisionLabel.stringValue = "人工选择 · " + (precision?.detail ?? "正在检查页面精度") }
        else { precisionLabel.stringValue = precision?.detail ?? "正在检查页面精度" }
        precisionLabel.toolTip = precisionLabel.stringValue
        if isPDF { nameField.stringValue = VectorFilename.render(nameField.stringValue, marked: marked) }
    }

    func prepareForDisplay() {
        if isPDF {
            let url = book.url
            updateVectorName()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = (try? NamingSource(url))?.pdf.map { PDFPrecision.inspect($0) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.precision = result ?? .init(kind: .uncertain, samplePages: [], rasterPages: [], estimatedImageDPI: nil)
                    self.updateVectorName()
                }
            }
        }
        originalPreview.load(book.url, page: currentPage)
        window.contentView?.layoutSubtreeIfNeeded(); infoSplit.setPosition(infoSplit.bounds.width * 0.56, ofDividerAt: 0)
        if AppSettings().metadataOCR, book.pages.contains(where: { $0.key.group == 2 }) { recognizeCopyright() }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 400 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - 330 }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === templateField { style.selectItem(at:namingStyles.count); refreshName() }
        if notification.object as? NSTextField === nameField { nameEdited = true }
        if let field = notification.object as? NSTextField, let index = fields.firstIndex(where: { $0 === field }) {
            editedKeys.insert(keys[index]); proofEntry.refresh(); refreshName()
        }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, let index = fields.firstIndex(where: { $0 === field }), keys[index] == "作者" {
            field.stringValue = BookMetadata.author(field.stringValue)
            return
        }
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
        let custom = selectedStyleID == "draft"
        templateField.isHidden = !custom
        templateHelp.isHidden = !custom
        if !custom { templateField.stringValue = selectedPattern }
        if !nameEdited,let name = try? FilenameTemplate.render(selectedPattern,metadata:metadataSnapshot) { nameField.stringValue = name; if isPDF { updateVectorName() } }
    }
    @objc func generateName() {
        window.makeFirstResponder(nil)
        do { nameField.stringValue = try FilenameTemplate.render(selectedPattern,metadata:metadataSnapshot); if isPDF { updateVectorName() }; nameEdited = false; message.textColor = .secondaryLabelColor; message.stringValue = "已更新最终文件名" }
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
    func textDidChange(_ notification: Notification) {
        if notification.object as? NSTextView === abstractView { editedKeys.insert("摘要") }
        else if notification.object as? NSTextView === citationView { editedKeys.insert("参考文献格式") }
    }
    @objc func adoptSource() {
        guard recognitionSources.indices.contains(sourceTable.selectedRow) else { return }
        let e = recognitionSources[sourceTable.selectedRow]
        setValue(e.value, for: e.field)
        if let page = e.page { originalPreview.showPage(page - 1); evidencePopover.performClose(nil) }
        editedKeys.insert(e.field); extracted[e.field] = e.value; selectionExplanations[e.field] = "手工采用"+e.source; uncertainKeys.remove(e.field); refreshName(); updateSummary(added:[])
    }
    @objc func undoAutomatic() {
        for (key,pair) in autoChanges where !editedKeys.contains(key) {
            if (keys.firstIndex(of: key).map { fields[$0].stringValue } ?? longValue(key)) == pair.1 { setValue(pair.0, for: key) }
        }
        autoChanges = [:]; refreshName(); message.stringValue = "已撤回最近一次自动调整；手工修改保留。尚未保存的内容不会影响原书。"
    }
    @objc func evidenceChanged() {
        evidenceArea.subviews.forEach { $0.removeFromSuperview() }
        let scroll: NSScrollView
        switch evidenceMode.selectedSegment {
        case 1:
            scroll = NSScrollView()
            scroll.documentView = sourceTable
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.borderType = .bezelBorder
        case 0: scroll = ocrTextScroll(extractionText, editable: false)
        default: scroll = ocrTextScroll(recognitionText, editable: true)
        }
        pin(scroll, in: evidenceArea)
        evidencePopover.contentViewController?.view.layoutSubtreeIfNeeded()
    }

    @objc func enlargeRecognition() {
        if reviewWindow == nil { reviewWindow = OCRTextReview(text: recognitionText.string) }
        reviewWindow?.text.string = recognitionText.string; reviewWindow?.show(above: window)
    }
    @objc func recognizeCopyright() { startRecognition(page: nil) }
    @objc func recognizeChosenPage() {
        startRecognition(page: originalPreview.url == book.url && originalPreview.pageCount > 0 ? originalPreview.page : currentPage)
    }
    private func startRecognition(page: Int?) {
        guard !busy, !recognitionRunning else { return }; window.makeFirstResponder(nil); recognitionRunning = true
        footerStatus.isHidden = false
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
            setValue(value, for: key)
        }
        // Show actual evidence on demand, grouped by field. Low-quality layout guesses remain labelled.
        recognitionSources = recognitionSources.enumerated().sorted { a,b in let x = BookMetadata.fields.firstIndex(of:a.element.field) ?? 99,y = BookMetadata.fields.firstIndex(of:b.element.field) ?? 99; return x != y ? x<y : a.offset<b.offset }.map(\.element)
        sourceTable.reloadData(); proofEntry.refresh(); refreshName(); updateSummary(added:Set(autoChanges.keys)); resultsButton.isEnabled = true
        if let page = recognitionSources.first(where: { $0.page != nil && $0.source == "出版信息" })?.page { originalPreview.showPage(page - 1) }
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
    private func show(_ error: Error) { footerStatus.isHidden = false; message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    @objc func rename() { submit(rename: true) }
    @objc func saveInformation() { submit(rename: false) }
    private func submit(rename: Bool) {
        guard !busy, !recognitionRunning else { message.stringValue = "正在识别，请稍候或取消。"; return }; window.makeFirstResponder(nil)
        do {
            let names = BookMetadata.fields + custom.map { $0.0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard Set(names).count == names.count else { throw ReaderFailure("自定义字段名称重复或与标准字段重名，请修改。") }
            let metadata = !rename || book.storesNativeInformation || saveMetadata.state == .on ? metadataSnapshot : nil
            if let metadata { var draft = BookEditDraft(book: book); draft.metadata = metadata; _ = try draft.encodedInfo() }
            let keep = preserveDates.state == .on
            busy = true
            defer { busy = false }
            if rename && isPDF { updateVectorName() }
            try onRename?(rename ? nameField.stringValue : book.url.deletingPathExtension().lastPathComponent, metadata, keep)
            AppSettings().set(keep, "preserveFileDates"); busy = false; close()
        } catch { show(error) }
    }
    @objc func close() { guard !busy else { return }; closed = true; evidencePopover.performClose(nil); recognitionPopover.performClose(nil); reviewWindow?.window.close(); templateWindow?.close(); NativeDialog.dismiss(window); onClose?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}
/// Shared layout for the editable book record in both naming windows.
enum NamingFormLayout {
    static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    static func column(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    static func pair(_ first: NSView, _ second: NSView) -> NSStackView {
        let result = row([first, second])
        result.alignment = .top
        result.spacing = 12
        NSLayoutConstraint.activate([
            first.widthAnchor.constraint(equalTo: result.widthAnchor, multiplier: 0.5, constant: -6),
            second.widthAnchor.constraint(equalTo: first.widthAnchor)
        ])
        return result
    }

    static func heading(_ title: String) -> NSTextField {
        let field = CenteredTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    static func field(_ key: String, _ editor: NSView) -> NSStackView {
        let label = CenteredTextField(labelWithString: BookMetadata.label(key))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        editor.setAccessibilityLabel(BookMetadata.label(key))
        editor.identifier = .init(key)
        return column([label, editor], spacing: 3)
    }

    static func line() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    static func groups(_ view: (String) -> NSView, expanded: Bool, citationAction: NSView? = nil) -> [NSView] {
        let basic = column([
            heading("基本信息"),
            view("ISBN"), view("书名"), view("作者"),
            pair(view("版本说明"), view("丛书名"))
        ])
        basic.identifier = .init("book-basic-information")
        let publication = column([
            heading("出版与形态"),
            pair(view("出版地"), view("出版社")),
            pair(view("出版日期"), view("数字版次")),
            pair(view("页数"), view("形态项")),
            pair(view("原书定价"), view("币种"))
        ])
        let classification = column([
            pair(view("中图法分类号"), view("主题词")),
            pair(view("SS号"), view("DX号"))
        ])
        let description = column([view("参考文献格式"), view("摘要")] + (citationAction.map { [$0] } ?? []))
        return [
            basic, line(), publication, line(),
            NamingDisclosure("分类、主题与标识", body: classification, expanded: expanded), line(),
            NamingDisclosure("参考文献格式与内容提要", body: description, expanded: expanded)
        ]
    }
}

final class NamingDisclosure: NSStackView {
    private let body: NSView
    private let toggle: NSButton

    init(_ title: String, body: NSView, expanded: Bool) {
        self.body = body
        toggle = NSButton(title: title, target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        detachesHiddenViews = true
        toggle.target = self
        toggle.action = #selector(change)
        toggle.isBordered = false
        toggle.font = .systemFont(ofSize: 13, weight: .semibold)
        toggle.imagePosition = .imageLeading
        toggle.alignment = .left
        addArrangedSubview(toggle)
        addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        body.isHidden = !expanded
        updateIndicator()
    }

    required init(coder: NSCoder) { fatalError("init(coder:)") }

    @objc private func change() {
        body.isHidden.toggle()
        updateIndicator()
        enclosingScrollView?.needsLayout = true
    }

    private func updateIndicator() {
        toggle.image = NSImage(systemSymbolName: body.isHidden ? "chevron.right" : "chevron.down",
                               accessibilityDescription: body.isHidden ? "折叠" : "已展开")
    }
}

/// Enter a value while looking at its source page without leaving the preview.
final class NamingProofEntry: NSStackView {
    private let keys = ["出版日期", "数字版次", "作者", "原书定价", "页数"]
    let picker = NSPopUpButton()
    let value = CenteredTextField()
    let adopt = NSButton(title: "采用", target: nil, action: nil)
    var read: ((String) -> String)?
    var write: ((String, String) -> Void)?

    init() {
        super.init(frame: .zero)
        spacing = 7
        alignment = .centerY
        picker.addItems(withTitles: keys.map(BookMetadata.label))
        picker.setAccessibilityLabel("当前核对字段")
        picker.target = self
        picker.action = #selector(refresh)
        value.setAccessibilityLabel("原页核对值")
        adopt.bezelStyle = .rounded
        adopt.target = self
        adopt.action = #selector(apply)
        for view in [picker, value, adopt] { addArrangedSubview(view) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:)") }

    private var key: String? { keys.indices.contains(picker.indexOfSelectedItem) ? keys[picker.indexOfSelectedItem] : nil }

    @objc func refresh() { if let key { value.stringValue = read?(key) ?? "" } }

    @objc private func apply() {
        guard let key else { return }
        window?.makeFirstResponder(nil)
        write?(key, value.stringValue)
        refresh()
    }
}
