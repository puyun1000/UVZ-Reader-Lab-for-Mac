import AppKit

/// A single draft for book information, copyright OCR and naming.
final class RenameSheet: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSSplitViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 830), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let nameField = NSTextField(), templateField = NSTextField(), style = NSPopUpButton()
    let keys = BookMetadata.fields.filter { $0 != "摘要" }
    let fields: [NSTextField]
    let abstractView = NSTextView(), recognitionText = NSTextView(), extractionText = NSTextView()
    let infoTable = NSTableView(), infoSplit = NSSplitView()
    let saveMetadata = NSButton(checkboxWithTitle: "将图书信息保存到 BookInfo.dat", target: nil, action: nil)
    let preserveDates = NSButton(checkboxWithTitle: "保持文件日期不变（创建日期与修改日期）", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let pageField = NSTextField(string: "1")
    private let evidenceArea = NSView(), evidenceMode = NSSegmentedControl()
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
    private var recognitionSources: [NamingEvidence] = []
    private var recognitionNotes: [String] = []
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
        fields = BookMetadata.fields.filter { $0 != "摘要" }.map { NSTextField(string: draft.values[$0] ?? "") }
        custom = draft.values.keys.filter { !BookMetadata.fields.contains($0) }.sorted().map { ($0, draft.values[$0]!) }
        super.init()
        window.title = "书籍信息与重命名 — " + book.title
        window.minSize = NSSize(width: 980, height: 740); window.isReleasedWhenClosed = false; window.delegate = self
        let host = NSView(); window.contentView = host
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18), root.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18), root.topAnchor.constraint(equalTo: host.topAnchor, constant: 16), root.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16)])
        let old = NSTextField(labelWithString: "当前文件：" + book.url.lastPathComponent); old.lineBreakMode = .byTruncatingMiddle; old.toolTip = book.url.path
        recognizeButton.target = self; recognizeButton.action = #selector(recognizeCopyright); recognizeButton.bezelStyle = .rounded
        pageField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let source = NSStackView(views: [recognizeButton, button("识别当前阅读页", #selector(recognizeCurrentPage)), NSTextField(labelWithString: "物理页"), pageField, button("识别此页", #selector(recognizeChosenPage)), NSView()]); source.spacing = 8
        for (key, field) in zip(keys, fields) { field.delegate = self; if key == "出版日期" { field.placeholderString = "YYYY.MM，例如 2026.03" } }
        let grid = NSGridView(views: zip(keys, fields).map { [NSTextField(labelWithString: $0.0), $0.1] }); grid.columnSpacing = 12; grid.rowSpacing = 6; grid.column(at: 0).width = 68
        for row in keys.indices { grid.row(at: row).height = 26 }
        grid.heightAnchor.constraint(equalToConstant: 282).isActive = true
        let abstract = ocrTextScroll(abstractView, editable: true); abstract.heightAnchor.constraint(equalToConstant: 64).isActive = true; abstractView.string = original["摘要"] ?? ""
        for (key, label, width) in [("key", "自定义字段", 120.0), ("value", "内容", 300.0)] { let column = NSTableColumn(identifier: .init(key)); column.title = label; column.width = width; infoTable.addTableColumn(column) }
        infoTable.dataSource = self; infoTable.delegate = self; infoTable.rowHeight = 27; infoTable.usesAlternatingRowBackgroundColors = true; infoTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let customScroll = NSScrollView(); customScroll.documentView = infoTable; customScroll.hasVerticalScroller = true; customScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        let customTools = NSStackView(views: [button("新增字段", #selector(addInfo)), button("删除自定义字段", #selector(removeInfo)), NSView()]); customTools.spacing = 8
        let form = NSStackView(views: [grid, NSTextField(labelWithString: "摘要"), abstract, customScroll, customTools]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 8
        for view in [grid, abstract, customScroll, customTools] { view.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -12).isActive = true }
        evidenceMode.segmentCount = 2; evidenceMode.setLabel("提取结果", forSegment: 0); evidenceMode.setLabel("识别原文", forSegment: 1); evidenceMode.trackingMode = .selectOne; evidenceMode.selectedSegment = 0; evidenceMode.target = self; evidenceMode.action = #selector(evidenceChanged)
        let evidenceTools = NSStackView(views: [evidenceMode, NSView(), button("放大原文…", #selector(enlargeRecognition))]); evidenceTools.spacing = 8
        let extractionHint = NSTextField(wrappingLabelWithString: "自动提取并补入左侧空缺栏，已有信息保留。可在“识别原文”中修正文字，再重新提取。")
        extractionHint.font = .systemFont(ofSize: 11); extractionHint.textColor = .secondaryLabelColor
        let right = NSStackView(views: [evidenceTools, evidenceArea, button("从原文重新提取并补齐", #selector(extractAgain)), extractionHint]); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        for view in [evidenceTools, evidenceArea, extractionHint] { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        infoSplit.isVertical = true; infoSplit.dividerStyle = .thin; infoSplit.delegate = self
        infoSplit.addArrangedSubview(FormScrollView(form)); infoSplit.addArrangedSubview(right)
        infoSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        style.addItems(withTitles: FilenameTemplate.presets + ["自定义格式"]); style.target = self; style.action = #selector(styleChanged)
        style.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let generator = NSStackView(views: [NSTextField(labelWithString: "命名格式"), style, button("生成规范名称", #selector(generateName))]); generator.spacing = 8
        templateField.stringValue = FilenameTemplate.presets[0]; templateField.delegate = self
        let hint = NSTextField(wrappingLabelWithString: "可用字段：" + BookMetadata.fields.map { "{" + $0 + "}" }.joined(separator: " ") + "。可编辑格式；扩展名保留为 ." + book.url.pathExtension)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        nameField.stringValue = book.url.deletingPathExtension().lastPathComponent
        let filename = NSStackView(views: [NSTextField(labelWithString: "新文件名"), nameField]); filename.spacing = 8
        saveMetadata.state = .on; preserveDates.state = AppSettings().preserveFileDates ? .on : .off
        let options = NSStackView(views: [saveMetadata, preserveDates]); options.spacing = 16
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        message.stringValue = book.isZip ? "手动更改与识别补齐均为草稿。可仅保存信息，也可一起重命名；目录由独立窗口编辑。" : "图书信息保存在同名 .uvzmeta 文件夹内；重命名时一并迁移，文档内容保持原样。"
        saveButton.target = self; saveButton.action = #selector(rename); saveButton.bezelStyle = .rounded; saveButton.keyEquivalent = "\r"
        let infoButton = button("仅保存信息", #selector(saveInformation))
        let cancel = button("取消", #selector(close)); cancel.keyEquivalent = "\u{1b}"
        let bottom = NSStackView(views: [NSView(), cancel, infoButton, saveButton]); bottom.spacing = 10
        for view in [old, source, infoSplit, generator, templateField, hint, filename, options, message, bottom] { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        if !book.canRename { nameField.isEnabled = false; style.isEnabled = false; templateField.isEnabled = false; saveButton.isHidden = true; message.stringValue = "PDG 文件夹可在此保存 BookInfo.dat；文件夹名称请在访达中修改。" }
        updateSummary(added: []); evidenceChanged()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b }
    func prepareForDisplay() {
        window.contentView?.layoutSubtreeIfNeeded(); infoSplit.setPosition(infoSplit.bounds.width * 0.53, ofDividerAt: 0); pageField.integerValue = currentPage + 1
        if AppSettings().metadataOCR, book.pages.contains(where: { $0.key.group == 2 }) { recognizeCopyright() }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 400 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - 330 }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === templateField { style.selectItem(at: FilenameTemplate.presets.count) }
        if let field = notification.object as? NSTextField, let index = fields.firstIndex(where: { $0 === field }) { editedKeys.insert(keys[index]) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? EditorField, custom.indices.contains(field.row) else { return }
        if field.column == "key" { custom[field.row].0 = field.stringValue } else { custom[field.row].1 = field.stringValue }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { custom.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = EditorField(); field.row = row; field.column = tableColumn?.identifier.rawValue ?? "value"; field.delegate = self
        field.stringValue = field.column == "key" ? custom[row].0 : custom[row].1; field.isBordered = false; field.backgroundColor = .clear; return field
    }
    @objc func addInfo() { window.makeFirstResponder(nil); custom.append(("新字段", "")); infoTable.reloadData(); infoTable.selectRowIndexes(IndexSet(integer: custom.count-1), byExtendingSelection: false); infoTable.scrollRowToVisible(custom.count-1) }
    @objc func removeInfo() { window.makeFirstResponder(nil); if custom.indices.contains(infoTable.selectedRow) { custom.remove(at: infoTable.selectedRow); infoTable.reloadData() } }
    @objc func styleChanged() { templateField.stringValue = style.indexOfSelectedItem < FilenameTemplate.presets.count ? FilenameTemplate.presets[style.indexOfSelectedItem] : AppSettings().customTemplate }
    @objc func generateName() {
        window.makeFirstResponder(nil)
        do {
            let custom = style.indexOfSelectedItem >= FilenameTemplate.presets.count
            let format = custom ? templateField.stringValue : FilenameTemplate.presets[style.indexOfSelectedItem]
            nameField.stringValue = try FilenameTemplate.render(format, metadata: metadataSnapshot)
            if custom { AppSettings().set(format, "customTemplate") }
            message.textColor = .secondaryLabelColor; message.stringValue = "已生成，可继续修改最终文件名。点击保存后生效。"
        } catch { show(error) }
    }
    @objc func evidenceChanged() {
        evidenceArea.subviews.forEach { $0.removeFromSuperview() }
        let scroll = evidenceMode.selectedSegment == 0 ? ocrTextScroll(extractionText, editable: false) : ocrTextScroll(recognitionText, editable: true)
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
        let source = book, cached = cachedCopyrightText
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CopyrightMetadata.recognize(book: source, currentPage: page, cached: cached) }
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
    func applyRecognition(_ values: [String: String]) {
        window.makeFirstResponder(nil); extracted = values; var added: Set<String> = []
        let stored = BookMetadata.canonical(book.metadata)
        for (key, value) in values {
            if let index = keys.firstIndex(of: key) {
                let field = fields[index], empty = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let inferredTitle = key == "书名" && stored[key, default: ""].isEmpty && field.stringValue == original[key] && !editedKeys.contains(key)
                if empty || inferredTitle { field.stringValue = value; added.insert(key) }
            } else if key == "摘要", abstractView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { abstractView.string = value; added.insert(key) }
        }
        updateSummary(added: added); evidenceMode.selectedSegment = 0; evidenceChanged(); message.textColor = .secondaryLabelColor
        message.stringValue = added.isEmpty ? "已逐项列出；没有可补齐的空缺项。可核对原文或手动修改左侧。" : "已补齐：" + BookMetadata.fields.filter { added.contains($0) }.joined(separator: "、") + "。请核对后保存。"
    }
    private func updateSummary(added: Set<String>) {
        extractionText.string = BookMetadata.fields.map { key in
            guard let value = extracted[key], !value.isEmpty else { return key + "：未识别" }
            let sources = recognitionSources.filter { $0.field == key }.map { "    "+$0.source+($0.page.map { " · 物理第 \($0) 页" } ?? "")+($0.inferred ? "（推测）" : "")+"："+$0.value }.joined(separator:"\n")
            return key+"："+value+"\n    "+(added.contains(key) ? "已补入左侧" : "已有信息保留，请核对")+(sources.isEmpty ? "" : "\n"+sources)
        }.joined(separator: "\n\n")
        if !recognitionNotes.isEmpty { extractionText.string += "\n\n核对提示：\n"+recognitionNotes.joined(separator:"\n") }
    }
    private func show(_ error: Error) { message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    @objc func rename() { submit(rename: true) }
    @objc func saveInformation() { submit(rename: false) }
    private func submit(rename: Bool) {
        guard !busy, !recognitionRunning else { message.stringValue = "正在识别，请稍候或取消。"; return }; window.makeFirstResponder(nil)
        do {
            let names = keys + ["摘要"] + custom.map { $0.0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard Set(names).count == names.count else { throw ReaderFailure("自定义字段名称重复或与标准字段重名，请修改。") }
            let metadata = !rename || saveMetadata.state == .on ? metadataSnapshot : nil
            if let metadata { var draft = BookEditDraft(book: book); draft.metadata = metadata; _ = try draft.encodedInfo() }
            let keep = preserveDates.state == .on
            busy = true
            defer { busy = false }
            try onRename?(rename ? nameField.stringValue : book.url.deletingPathExtension().lastPathComponent, metadata, keep)
            AppSettings().set(keep, "preserveFileDates"); busy = false; close()
        } catch { show(error) }
    }
    @objc func close() { guard !busy else { return }; closed = true; reviewWindow?.window.close(); NativeDialog.dismiss(window); onClose?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}
