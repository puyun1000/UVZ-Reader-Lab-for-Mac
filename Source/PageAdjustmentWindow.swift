import AppKit
import UniformTypeIdentifiers

final class PageAdjustmentWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window = ChineseWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 760),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let before = BookProofCanvas()
    let after = BookProofCanvas()
    let scope = NSPopUpButton()
    let range = CenteredTextField()
    let pageField = CenteredTextField()
    let rotation = NSPopUpButton()
    let cropFields = (0..<4).map { _ in CenteredTextField() }
    let brightness = CenteredTextField()
    let contrast = CenteredTextField()
    let gamma = CenteredTextField()
    let automatic = NSButton(checkboxWithTitle: "自动对比度", target: nil, action: nil)
    private let countLabel = CenteredTextField(labelWithString: "")
    private let note = CenteredTextField(wrappingLabelWithString: "")
    private let status = CenteredTextField(labelWithString: "")
    private let saveButton = NSButton(title: "另存调整后的图书…", target: nil, action: nil)
    private let cancelButton = NSButton(title: "关闭", target: nil, action: nil)
    private let queue = OperationQueue()
    private let url: URL
    private let total: Int
    private var page: Int
    private var previewToken = UUID()
    private var source: NamingSource?
    private var fingerprint: String?
    private var cached: (Int, CGImage)?
    private var saveOperation: Operation?
    private var closed = false
    var onClose: (() -> Void)?
    var onSaved: ((URL) -> Void)?

    init(book: BookArchive, current: Int) {
        url = book.url
        total = book.pages.count
        page = current
        super.init()
        window.title = "页面调整 — " + book.title
        window.minSize = NSSize(width: 760, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        scope.addItems(withTitles: ["当前预览页", "指定页码", "全书"])
        range.placeholderString = "如 1,3-7"
        range.widthAnchor.constraint(equalToConstant: 160).isActive = true
        pageField.alignment = .center
        pageField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        pageField.target = self
        pageField.action = #selector(jump)
        pageField.setAccessibilityLabel("调整预览物理页码")
        rotation.addItems(withTitles: ["不旋转", "顺时针 90°", "180°", "逆时针 90°"])
        for popup in [scope, rotation] { popup.target = self; popup.action = #selector(refresh) }
        automatic.target = self
        automatic.action = #selector(refresh)
        for (field, value) in zip(cropFields + [brightness, contrast, gamma], ["0", "0", "0", "0", "0", "1", "1"]) {
            field.stringValue = value
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 49).isActive = true
        }
        for field in cropFields + [brightness, contrast, gamma, range] {
            field.delegate = self
            field.target = self
            field.action = #selector(refresh)
        }
        func labeled(_ text: String, _ view: NSView) -> [NSView] {
            [CenteredTextField(labelWithString: text), view]
        }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.spacing = 8
            return row
        }
        let pageTools = row([button("上一页", #selector(previous)), pageField, countLabel,
                             button("下一页", #selector(next)), NSView(), button("缩小", #selector(smaller)),
                             button("放大", #selector(larger)), button("整页", #selector(fit))])
        let targetTools = row(labeled("应用范围", scope) + [range, NSView()] + labeled("旋转", rotation))
        let cropTools = row([CenteredTextField(labelWithString: "裁边 %")] +
                            zip(["左", "右", "上", "下"], cropFields).flatMap { labeled($0, $1) } + [NSView()])
        cropTools.toolTip = "按旋转前所见页面计算。各边输入 0 到 49。"
        let toneTools = row([automatic] + labeled("亮度", brightness) + labeled("对比度", contrast) + labeled("Gamma", gamma) + [NSView()])
        toneTools.toolTip = "亮度 −0.5 至 0.5，对比度 0.25 至 3，Gamma 0.25 至 4。"

        func column(_ title: String, _ canvas: BookProofCanvas) -> NSStackView {
            let column = NSStackView(views: [CenteredTextField(labelWithString: title), canvas])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            canvas.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            return column
        }
        let pair = row([column("原页", before), column("调整预览", after)])
        pair.distribution = .fillEqually
        pair.alignment = .top
        for view in pair.arrangedSubviews { view.heightAnchor.constraint(equalTo: pair.heightAnchor).isActive = true }
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveButton.target = self
        saveButton.action = #selector(saveAs)
        saveButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(close)
        cancelButton.bezelStyle = .rounded
        let footer = row([status, NSView(), cancelButton, saveButton])
        let root = NSStackView(views: [pageTools, pair, targetTools, cropTools, toneTools, note, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        window.contentView = host
        host.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14)
        ])
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        pair.setContentHuggingPriority(.defaultLow, for: .vertical)
        refresh()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func settings() throws -> (PageAdjustment, IndexSet) {
        func number(_ field: NSTextField) throws -> Double {
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(raw) else { throw ReaderFailure("请输入有效数值。") }
            return value
        }
        let edit = try PageAdjustment(rotation: rotation.indexOfSelectedItem, left: number(cropFields[0])/100,
                                      right: number(cropFields[1])/100, top: number(cropFields[2])/100,
                                      bottom: number(cropFields[3])/100, automaticContrast: automatic.state == .on,
                                      brightness: number(brightness), contrast: number(contrast), gamma: number(gamma))
        try edit.validate()
        let pages: IndexSet
        switch scope.indexOfSelectedItem {
        case 1: pages = try PageAdjustment.pages(range.stringValue, count: total)
        case 2: pages = IndexSet(integersIn: 0..<total)
        default: pages = IndexSet(integer: page)
        }
        return (edit, pages)
    }

    func controlTextDidEndEditing(_ notification: Notification) { refresh() }
    @objc private func previous() { navigate(page - 1) }
    @objc private func next() { navigate(page + 1) }
    @objc private func jump() { if let value = Int(pageField.stringValue), value > 0 { navigate(value - 1) } else { refresh() } }
    private func navigate(_ index: Int) {
        if (0..<total).contains(index), saveOperation == nil { page = index }
        refresh()
    }
    @objc private func smaller() { before.zoom(1 / 1.35); after.zoom(1 / 1.35) }
    @objc private func larger() { before.zoom(1.35); after.zoom(1.35) }
    @objc private func fit() { before.fitPage(); after.fitPage() }

    @objc func refresh() {
        guard !closed, saveOperation == nil else { return }
        pageField.stringValue = String(page + 1)
        countLabel.stringValue = "/ \(total)"
        range.isEnabled = scope.indexOfSelectedItem == 1
        let token = UUID()
        previewToken = token
        queue.cancelAllOperations()
        saveButton.isEnabled = false
        let draft = Result { try settings() }
        let index = page
        let retainedSource = source
        let retainedFingerprint = fingerprint
        let retainedImage = cached?.0 == index ? cached?.1 : nil
        if retainedImage == nil { before.show(nil); after.show(nil) }
        status.stringValue = "正在读取第 \(index + 1) 页…"
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation, url, total] in
            guard operation?.isCancelled == false else { return }
            let loaded = Result { () throws -> (NamingSource, String, CGImage) in
                let mark = try retainedFingerprint ?? BatchNaming.fingerprint(url, cancelled: { operation?.isCancelled != false })
                let source = try retainedSource ?? NamingSource(url)
                guard source.pageCount == total else { throw ReaderFailure("图书页数已变化，请重新打开。") }
                let raw = try retainedImage ?? source.image(at: index)
                return (source, mark, raw)
            }
            let prepared = Result { () throws -> CGImage in
                let (_, _, raw) = try loaded.get()
                let (edit, pages) = try draft.get()
                return pages.contains(index) ? try edit.image(raw) : raw
            }
            DispatchQueue.main.async {
                guard let self, !self.closed, self.previewToken == token else { return }
                do {
                    let (source, mark, raw) = try loaded.get()
                    self.source = source
                    self.fingerprint = mark
                    self.cached = (index, raw)
                    self.before.show(raw)
                    let adjusted = try prepared.get()
                    let (edit, pages) = try draft.get()
                    self.after.show(adjusted)
                    self.saveButton.isEnabled = edit.active
                    self.status.stringValue = pages.contains(index) ? "将调整 \(pages.count) 页" : "本页不在所选范围 · 将调整 \(pages.count) 页"
                    self.note.stringValue = self.saveNote(edit)
                } catch {
                    self.after.show(nil)
                    self.status.stringValue = error.localizedDescription
                }
            }
        }
        queue.addOperation(operation)
    }

    private func saveNote(_ edit: PageAdjustment) -> String {
        let ext = url.pathExtension.lowercased()
        if ["djvu", "djv"].contains(ext), edit.crops || edit.tone.active {
            return "另存为同格式副本。裁边或色调调整会有损重新编码所选 DjVu 页，所选页的文字层和页面注释会被移除。"
        }
        if ["pdf", "uvz", "zip"].contains(ext), edit.tone.active {
            return "另存为同格式副本。色调调整会将所选 PDF 或文本 PDG 页转为图像，影响这些页的文字选取和交互注释。"
        }
        return "另存为同格式副本。PDF 与文本 PDG 的旋转、裁边保留原有文字层。"
    }

    @objc func saveAs() {
        guard saveOperation == nil, let mark = fingerprint, window.makeFirstResponder(nil) else { return }
        do {
            let (edit, pages) = try settings()
            guard edit.active else { throw ReaderFailure("请至少调整一项。") }
            let panel = NSSavePanel()
            let ext = url.pathExtension
            if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
            panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "（已调整）." + ext
            panel.directoryURL = url.deletingLastPathComponent()
            panel.title = "另存调整后的图书"
            panel.message = saveNote(edit)
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let output = panel.url { self?.save(output, edit: edit, pages: pages, mark: mark) }
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    func saveCopy(to output: URL) throws {
        guard saveOperation == nil, let mark = fingerprint else { throw ReaderFailure("页面仍在读取。") }
        let (edit, pages) = try settings()
        save(output, edit: edit, pages: pages, mark: mark)
    }

    private func save(_ output: URL, edit: PageAdjustment, pages: IndexSet, mark: String) {
        queue.cancelAllOperations()
        previewToken = UUID()
        saveButton.isEnabled = false
        cancelButton.title = "停止保存"
        status.stringValue = "正在准备 \(pages.count) 页…"
        let cancellation = Operation()
        saveOperation = cancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self, url] in
            let result = Result {
                try PageAdjustmentWriter.save(from: url, to: output, pages: pages, edit: edit, expectedFingerprint: mark,
                                               cancelled: { cancellation.isCancelled }, progress: { done in
                    DispatchQueue.main.async { self?.status.stringValue = done == pages.count ? "正在核验副本…" : "正在处理 \(done)/\(pages.count) 页…" }
                })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.saveOperation = nil
                self.cancelButton.title = "关闭"
                switch result {
                case .success: self.onSaved?(output); self.close()
                case .failure(let error): self.status.stringValue = error.localizedDescription; self.saveButton.isEnabled = true
                }
            }
        }
    }

    @objc func close() {
        if let saveOperation {
            saveOperation.cancel()
            status.stringValue = "正在停止保存…"
            return
        }
        closed = true
        queue.cancelAllOperations()
        NativeDialog.dismiss(window)
        onClose?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}
