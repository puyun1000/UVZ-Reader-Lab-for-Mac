import AppKit

final class EditorField: CenteredTextField {
    var row = 0
    var column = ""
    var isInfo = false
}

/// A draft-only editor. Changes reach the book only after the Save button succeeds.
final class BookEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate {
    let window = ChineseWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 790), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let contentsTable = ContentsOutlineView()
    let structuralUndo = UndoManager()
    var editingUndoManager: UndoManager? { textActive ? textView.undoManager : (window.firstResponder is NSTextView ? window.firstResponder?.undoManager : structuralUndo) }
    private(set) var regionOCR: RegionOCRController?
    var currentPage = 0
    let textView = ContentsTextView()
    let categoryPopup = NSPopUpButton()
    let baseField = CenteredTextField(string: "1")
    private var textPane: NSView!
    let modeControl = NSSegmentedControl()
    let categoryControl = NSSegmentedControl()
    private let pageSummary = CenteredTextField(wrappingLabelWithString: "")
    private var textActive = false
    private var basePage = 1
    private var activeCategory = 0
    private var treeRoots: [EditorTreeNode] = []
    private var treeNodes: [EditorTreeNode] = []
    private let editorArea = NSView()
    private var contentsPane: NSView!
    private(set) var draft: BookEditDraft
    private var book: BookArchive
    private let message = CenteredTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private(set) var pageRepair: PageRepairWindow?
    var onPageRepaired: ((BookArchive,[Int:Int]) -> Void)?
    var onSaved: (([URL]) -> Void)?
    var onClosed: (() -> Void)?
    private var busy = false
    init(book: BookArchive) {
        self.book = book; draft = BookEditDraft(book: book)
        super.init()
        structuralUndo.groupsByEvent = false
        window.title = "编辑目录 — " + book.title; window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 960, height: 680)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.edgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16)
        let host = NSView(); window.contentView = host
        root.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: host.leadingAnchor), root.trailingAnchor.constraint(equalTo: host.trailingAnchor), root.topAnchor.constraint(equalTo: host.topAnchor), root.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        let heading = CenteredTextField(labelWithString: "目录编辑：TAB 缩进文字录入，也可切换树形调整。")
        let location = CenteredTextField(wrappingLabelWithString: "保存位置：" + book.editingLocation + "\n备份默认关闭，可在“文件 → 保存前备份原文件”中勾选。保存前的修改均为草稿。")
        location.font = .systemFont(ofSize: 11); location.textColor = .secondaryLabelColor
        editorArea.translatesAutoresizingMaskIntoConstraints = false
        modeControl.segmentCount = 2; modeControl.trackingMode = .selectOne
        modeControl.setLabel("文本录入", forSegment: 0); modeControl.setLabel("树形调整", forSegment: 1)
        modeControl.setWidth(120, forSegment: 0); modeControl.setWidth(120, forSegment: 1)
        modeControl.selectedSegment = 0; modeControl.target = self; modeControl.action = #selector(editorModeChanged)
        let check = makeButton("页面编码校对…",#selector(repairPages)); check.isEnabled = book.canCorrectPages
        let warning = PageInspection.structural(book).count
        let checkHint = CenteredTextField(labelWithString: warning > 0 ? "发现 \(warning) 条页面编码提示" : "")
        checkHint.textColor = .systemOrange
        let tabButtons = NSStackView(views: [modeControl, NSView(),checkHint,check]); tabButtons.spacing = 8
        let chapterView = tablePane(contentsTable, columns: [("title", "目录名称", 450), ("type", "页面类型", 90), ("page", "页号", 100), ("physical", "物理页", 85)], controls: [
            makeButton("前插", #selector(insertBefore)), makeButton("后插", #selector(addChapter)), makeButton("新增子项", #selector(addChild)), makeButton("删除", #selector(removeChapter)),
            makeButton("上移", #selector(moveUp)), makeButton("下移", #selector(moveDown)), makeButton("降一级", #selector(indent)), makeButton("升一级", #selector(outdent)), makeButton("展开", #selector(expandTree)), makeButton("折叠", #selector(collapseTree)), makeButton("改页码", #selector(offsetPages))])
        contentsPane = chapterView
        contentsTable.performEdit = { [weak self] action in self?.performStructure(action) }
        textPane = buildTextPane()
        renderText(); textActive = true; showPane(textPane); modeControl.selectedSegment = 0
        rebuildTree()
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        message.stringValue = book.contentsNotice.map { $0 + " 保存会按当前列表重建目录。" } ?? "文本模式支持撤销、TAB／Shift+TAB 和回车自动缩进；无页码的标题可作为分组。"
        saveButton.target = self; saveButton.action = #selector(saveDraft); saveButton.keyEquivalent = "\r"; saveButton.bezelStyle = .rounded
        let cancel = makeButton("取消", #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [NSView(), cancel, saveButton]); footer.spacing = 10
        for view in [heading, location, tabButtons, editorArea, message, footer] { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        editorArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        editorArea.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button
    }
    @objc func repairPages() {
        finishEditing(); guard !busy,book.canCorrectPages,!window.hasDocumentDialog,commitText() else { return }
        let targets = draft.chapters.compactMap { chapter -> InspectionTarget? in
            guard let target = chapter.unresolvedTarget,let address = try? PageAddressing.address(target),address.group >= 0,address.group < 8 else { return nil }
            return InspectionTarget(title:chapter.title,group:address.group,number:address.number)
        }
        let controller = PageRepairWindow(book:book,current:currentPage,extra:targets); pageRepair = controller
        controller.onApplied = { [weak self] updated,map in
            guard let self else { return }
            self.currentPage = map[self.currentPage] ?? 0
            for index in self.draft.chapters.indices {
                if self.draft.chapters[index].page > 0 { self.draft.chapters[index].page = (map[self.draft.chapters[index].page-1] ?? 0)+1 }
                if let target = self.draft.chapters[index].unresolvedTarget,let physical = try? PageAddressing(updated,base:self.basePage).resolve(target) { self.draft.chapters[index].page = physical; self.draft.chapters[index].unresolvedTarget = nil }
            }
            self.book = updated; self.structuralUndo.removeAllActions(); self.renderText(); self.rebuildTree()
            self.message.stringValue = "页面编码已纠正；目录草稿与阅读位置已同步。目录草稿仍需单独保存。"
            self.onPageRepaired?(updated,map)
        }
        controller.onClosed = { [weak self] in self?.pageRepair = nil }
        controller.show(on:window)
    }
    @objc func editorModeChanged() { if modeControl.selectedSegment == 0 { showContentsTab() } else { showStructureTab() } }
    @objc func showContentsTab() {
        guard !textActive else { modeControl.selectedSegment = 0; return }
        finishEditing(); renderText(); textActive = true; showPane(textPane); modeControl.selectedSegment = 0; updateScope()
    }
    @objc func showStructureTab() {
        finishEditing(); guard commitText() else { modeControl.selectedSegment = textActive ? 0 : 1; return }
        textActive = false; rebuildTree(); showPane(contentsPane); modeControl.selectedSegment = 1
        message.stringValue = "树形显示全部页面类型。页号可直接修改；非正文使用 cov／bok／leg／fow／!／att／bac 前缀，红色页号须在保存前修正。"
        message.textColor = .secondaryLabelColor
    }
    var isTextMode: Bool { textActive }
    @objc func expandTree() { contentsTable.expandItem(nil, expandChildren: true) }
    @objc func collapseTree() { contentsTable.collapseItem(nil, collapseChildren: true) }
    private var selectedChapterIndex: Int { (contentsTable.item(atRow: contentsTable.selectedRow) as? EditorTreeNode)?.index ?? -1 }
    private func rebuildTree() {
        treeRoots = []; treeNodes = draft.chapters.indices.map(EditorTreeNode.init)
        var parents: [(Int, EditorTreeNode)] = []
        for node in treeNodes {
            let level = draft.chapters[node.index].level
            while let last = parents.last, last.0 >= level { parents.removeLast() }
            if let parent = parents.last, level > 0 { parent.1.children.append(node) } else { treeRoots.append(node) }
            parents.append((level, node))
        }
        contentsTable.reloadData(); contentsTable.expandItem(nil, expandChildren: true); updateScope()
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? EditorTreeNode)?.children.count ?? treeRoots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? EditorTreeNode)?.children ?? treeRoots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! EditorTreeNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? { tableView(contentsTable, viewFor: tableColumn, row: (item as! EditorTreeNode).index) }
    private func buildTextPane() -> NSView {
        categoryPopup.addItems(withTitles: ["全部类型", "封面", "书名", "版权", "前言", "目录", "正文", "附录", "封底"])
        categoryPopup.target = self; categoryPopup.action = #selector(categoryChanged)
        categoryControl.segmentCount = 9; categoryControl.trackingMode = .selectOne; categoryControl.selectedSegment = 0
        for (index,title) in ["全部", "封面", "书名", "版权", "前言", "目录", "正文", "附录", "封底"].enumerated() { categoryControl.setLabel(title,forSegment:index); categoryControl.setWidth(82,forSegment:index) }
        categoryControl.target = self; categoryControl.action = #selector(categorySelected); categoryControl.isHidden = !book.usesPDGNumbering
        pageSummary.font = .systemFont(ofSize: 11); pageSummary.textColor = .secondaryLabelColor
        baseField.widthAnchor.constraint(equalToConstant: 56).isActive = true; baseField.delegate = self
        let base = NSStackView(views: [CenteredTextField(labelWithString: "正文第 1 页所在物理页"), baseField]); base.spacing = 6; base.isHidden = book.usesPDGNumbering
        let split = makeButton("分离末尾页码", #selector(splitPageNumbers))
        let tools = NSStackView(views: [base, TextConversion.button(for:textView), NSView(), makeButton("降一级", #selector(indentText)), makeButton("升一级", #selector(outdentText)), split]); tools.spacing = 6
        textView.setFrameSize(NSSize(width: 780, height: 400)); textView.minSize = NSSize(width: 0, height: 300); textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false; textView.allowsUndo = true; textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticSpellingCorrectionEnabled = false; textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle(); paragraph.defaultTabInterval = 32; paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        let hint = CenteredTextField(wrappingLabelWithString: book.usesPDGNumbering ? "每行：标题 ⇥ 页号；行首 TAB 定层级。分区内直接填该类型数字页号；全部类型时非正文加 cov／bok／leg／fow／!／att／bac 前缀。@15 表示物理第 15 页。" : "每行：标题 ⇥ 页码；行首 TAB 定层级。先设置正文基准页再录入；基准页之前用 -1、-2 等，@15 表示物理第 15 页。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let extra = NSStackView(views: [makeButton("框选识别…", #selector(openRegionOCR)), makeButton("查找与替换…", #selector(findReplace)), makeButton("批量增减页码…", #selector(offsetPages)), CenteredTextField(labelWithString: "多行选中后可用 TAB / Shift+TAB 调整层级")]); extra.spacing = 8
        let stack = NSStackView(views: [categoryControl, pageSummary, tools, extra, scroll, hint]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        for view in [categoryControl, pageSummary, tools, extra, scroll, hint] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func selectedTextChapters() -> [BookEditDraft.Chapter] {
        activeCategory == 0 ? draft.chapters : draft.chapters.filter { ContentsTextCodec.category($0, book: book) == activeCategory - 1 }
    }
    private func renderText() { textView.string = ContentsTextCodec.text(selectedTextChapters(), book: book, base: basePage, localGroup: activeCategory == 0 ? nil : activeCategory - 1); textView.undoManager?.removeAllActions(); updateScope() }
    @discardableResult private func commitText(strict: Bool = false) -> Bool {
        guard textActive else { return true }
        do {
            let previous = draft.chapters
            let parsed = try ContentsTextCodec.chapters(textView.string, book: book, base: basePage, defaultGroup: activeCategory == 0 ? 5 : activeCategory - 1, allowUnresolved: !strict)
            if activeCategory == 0 { draft.chapters = parsed }
            else {
                let slots = draft.chapters.indices.filter { ContentsTextCodec.category(draft.chapters[$0], book: book) == activeCategory - 1 }
                let selected = Set(slots); var updated: [BookEditDraft.Chapter] = [], next = 0
                for index in draft.chapters.indices {
                    if selected.contains(index) {
                        if next < parsed.count { updated.append(parsed[next]); next += 1 }
                        if index == slots.last { updated.append(contentsOf: parsed.dropFirst(next)); next = parsed.count }
                    } else { updated.append(draft.chapters[index]) }
                }
                if slots.isEmpty {
                    let insertion = updated.firstIndex { $0.page > 0 && ContentsTextCodec.category($0,book:book) > activeCategory - 1 } ?? updated.count
                    updated.insert(contentsOf:parsed,at:insertion)
                }
                draft.chapters = updated
            }
            if previous != draft.chapters { structuralUndo.removeAllActions() }; updateScope()
            return true
        } catch { message.stringValue = error.localizedDescription; message.textColor = .systemRed; return false }
    }
    @objc func categoryChanged() {
        let next = categoryPopup.indexOfSelectedItem
        guard commitText() else { categoryPopup.selectItem(at: activeCategory); categoryControl.selectedSegment = activeCategory; return }
        activeCategory = next; categoryControl.selectedSegment = next; renderText()
    }
    @objc func categorySelected() { categoryPopup.selectItem(at: categoryControl.selectedSegment); categoryChanged() }
    private func updateScope() {
        guard categoryControl.segmentCount > 0 else { return }
        for index in 0..<9 {
            let title = index == 0 ? "全部" : PageAddressing.titles[index - 1]
            let count = index == 0 ? draft.chapters.count : draft.chapters.filter { ContentsTextCodec.category($0,book:book) == index - 1 }.count
            categoryControl.setLabel(title + (count > 0 ? " +\(count)" : ""),forSegment:index)
        }
        let map = PageAddressing(book,base:basePage)
        if activeCategory == 0 { pageSummary.stringValue = "全部类型：裸数字表示正文页号，前置页面请加类型前缀；树形可显示全部条目及层级。" }
        else {
            let group = activeCategory - 1, count = selectedTextChapters().count
            pageSummary.stringValue = "\(PageAddressing.titles[group])分区：页号范围 \(map.rangeDescription(in:group))，共 \(map.pages(in:group).count) 页、\(count) 条目录。此区裸数字直接表示\(PageAddressing.titles[group])页号，其他分区内容保留。"
        }
    }
    private func baseChanged() {
        let next = baseField.integerValue
        guard (1...book.pages.count).contains(next) else { message.stringValue = "正文基准页应在 1—\(book.pages.count) 之间。"; message.textColor = .systemRed; baseField.integerValue = basePage; return }
        guard commitText() else { baseField.integerValue = basePage; return }
        basePage = next; renderText()
    }
    @objc func splitPageNumbers() {
        let updated = ContentsTextCodec.splitTrailingNumbers(textView.string)
        textView.insertText(updated, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
    }
    private func showPane(_ pane: NSView) {
        editorArea.subviews.forEach { $0.removeFromSuperview() }
        pane.translatesAutoresizingMaskIntoConstraints = false; editorArea.addSubview(pane)
        NSLayoutConstraint.activate([pane.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor), pane.trailingAnchor.constraint(equalTo: editorArea.trailingAnchor), pane.topAnchor.constraint(equalTo: editorArea.topAnchor), pane.bottomAnchor.constraint(equalTo: editorArea.bottomAnchor)])
        window.contentView?.layoutSubtreeIfNeeded()
    }
    private func tablePane(_ table: NSTableView, columns: [(String, String, CGFloat)], controls: [NSButton]) -> NSView {
        for (id, title, width) in columns { let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column); if id == "title", let outline = table as? NSOutlineView { outline.outlineTableColumn = column; outline.indentationPerLevel = 18 } }
        table.delegate = self; table.dataSource = self; table.rowHeight = 29; table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true; table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let buttons: NSView
        do {
            let flow = FlowToolbar(); flow.groups = controls
            let height = flow.heightAnchor.constraint(equalToConstant: 48); height.isActive = true
            flow.onHeight = { value in if abs(height.constant - value) > 0.5 { height.constant = value } }; buttons = flow
        }
        let stack = NSStackView(views: [scroll, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 400))
        container.autoresizingMask = [.width, .height]
        stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)])
        return container
    }
    func numberOfRows(in tableView: NSTableView) -> Int { draft.chapters.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue else { return nil }
        let field = EditorField(); field.row = row; field.column = column; field.delegate = self
        field.isBordered = false; field.backgroundColor = .clear; field.font = .systemFont(ofSize: 12)
        let chapter = draft.chapters[row], group = ContentsTextCodec.category(chapter,book:book)
        switch column {
        case "title": field.stringValue = chapter.title
        case "page": field.stringValue = chapter.unresolvedTarget ?? PageAddressing(book,base:basePage).token(chapter.page)
        case "type": field.stringValue = chapter.page == 0 && chapter.unresolvedTarget == nil ? "分组" : (PageAddressing.titles.indices.contains(group) ? PageAddressing.titles[group] : "物理页"); field.isEditable = false
        default: field.stringValue = chapter.page > 0 ? String(chapter.page) : ""; field.isEditable = false
        }
        if let target = chapter.unresolvedTarget { field.textColor = .systemRed; field.toolTip = "页号 \(target) 未匹配；可直接修正页号，或使用 @加物理页码。" }
        else { field.toolTip = "层级 \(chapter.level + 1) · 物理第 \(chapter.page) 页" }
        return field
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === baseField { baseChanged(); return }
        guard let field = notification.object as? EditorField, !busy else { return }
        if draft.chapters.indices.contains(field.row) {
            switch field.column {
            case "title": draft.chapters[field.row].title = field.stringValue
            case "page":
                let target = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                do { draft.chapters[field.row].page = target.isEmpty ? 0 : try PageAddressing(book,base:basePage).resolve(target); draft.chapters[field.row].unresolvedTarget = nil }
                catch { draft.chapters[field.row].page = 0; draft.chapters[field.row].unresolvedTarget = target; message.stringValue = error.localizedDescription; message.textColor = .systemRed }
                reload(field.row)
            case "level": draft.chapters[field.row].level = (Int(field.stringValue) ?? 0) - 1; reload(field.row)
            default: break
            }
        }
    }
    private func finishEditing() { window.makeFirstResponder(nil) }
    private func reload(_ row: Int? = nil) {
        rebuildTree(); if let row, treeNodes.indices.contains(row) { let visible = contentsTable.row(forItem: treeNodes[row]); if visible >= 0 { contentsTable.selectRowIndexes(IndexSet(integer: visible), byExtendingSelection: false); contentsTable.scrollRowToVisible(visible) } }
    }
    @objc func addChapter() {
        guard !busy else { return }; finishEditing()
        let selected = selectedChapterIndex
        let index = selected < 0 ? draft.chapters.count : subtreeEnd(selected)
        let level = selected < 0 ? 0 : draft.chapters[selected].level
        var updated = draft.chapters; updated.insert(.init(title: "新目录", page: selected < 0 ? 1 : draft.chapters[selected].page, level: level), at: index); restoreStructure(updated, selection: IndexSet(integer: index))
    }
    @objc func addChild() {
        guard !busy else { return }; finishEditing(); let row = selectedChapterIndex
        guard draft.chapters.indices.contains(row) else { addChapter(); return }
        let parent = draft.chapters[row]
        guard parent.level < 32 else { message.stringValue = "目录最多 33 级，不能再添加子项。"; return }
        var updated = draft.chapters; updated.insert(.init(title: "新子目录", page: parent.page, level: parent.level + 1), at: row + 1); restoreStructure(updated, selection: IndexSet(integer: row + 1))
    }
    private var selectedIndices: IndexSet { IndexSet(contentsTable.selectedRowIndexes.compactMap { (contentsTable.item(atRow: $0) as? EditorTreeNode)?.index }) }
    private func select(_ indices: IndexSet) {
        let rows = IndexSet(indices.compactMap { index -> Int? in guard treeNodes.indices.contains(index) else { return nil }; let row = contentsTable.row(forItem: treeNodes[index]); return row >= 0 ? row : nil })
        contentsTable.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { contentsTable.scrollRowToVisible(first) }
    }
    private func restoreStructure(_ chapters: [BookEditDraft.Chapter], selection: IndexSet) {
        guard chapters != draft.chapters else { select(selection); return }
        let previous = draft.chapters, oldSelection = selectedIndices
        structuralUndo.beginUndoGrouping(); defer { structuralUndo.endUndoGrouping() }
        structuralUndo.registerUndo(withTarget: self) { $0.restoreStructure(previous, selection: oldSelection) }
        structuralUndo.setActionName("目录调整")
        draft.chapters = chapters; rebuildTree(); select(selection)
    }
    func performStructure(_ action: ContentsOperations.Action) {
        guard !busy else { return }; finishEditing()
        do {
            let result = try ContentsOperations.apply(action, chapters: draft.chapters, selected: selectedIndices)
            restoreStructure(result.chapters, selection: result.selection)
            message.textColor = .secondaryLabelColor; message.stringValue = "已调整选中目录及其子项；支持 Command / Shift 多选，TAB 降级、Shift+TAB 升级，Control+↑↓ 移动。"
        } catch { message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    }
    @objc func insertBefore() {
        guard !busy else { return }; finishEditing(); let row = selectedChapterIndex
        guard draft.chapters.indices.contains(row) else { addChapter(); return }
        let item = draft.chapters[row]; var updated = draft.chapters
        updated.insert(.init(title: "新目录", page: item.page, level: item.level), at: row)
        restoreStructure(updated, selection: IndexSet(integer: row))
    }
    private func subtreeEnd(_ row: Int) -> Int { var end = row + 1; while end < draft.chapters.count, draft.chapters[end].level > draft.chapters[row].level { end += 1 }; return end }
    @objc func removeChapter() { performStructure(.delete) }
    @objc func moveUp() { performStructure(.up) }
    @objc func moveDown() { performStructure(.down) }
    @objc func indent() { performStructure(.indent) }
    @objc func outdent() { performStructure(.outdent) }
    @objc func indentText() { window.makeFirstResponder(textView); textView.shiftIndent(1) }
    @objc func outdentText() { window.makeFirstResponder(textView); textView.shiftIndent(-1) }
    @objc func offsetPages() {
        finishEditing()
        let alert = NSAlert(); alert.messageText = "批量增减页码"; alert.informativeText = "对选中的目录行增减物理页码；无页码的分组保持不变。文本未选择时处理全文。"
        let field = CenteredTextField(string: "0"); field.frame = NSRect(x: 0, y: 0, width: 240, height: 26); alert.accessoryView = field; alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        NativeDialog.alert(alert, on: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, let delta = Int(field.stringValue) else { return }
            do {
                if self.textActive {
                    let text = self.textView.string as NSString, selected = self.textView.selectedRange()
                    let range = selected.length == 0 ? NSRange(location: 0, length: text.length) : text.lineRange(for: NSRange(location: selected.location, length: max(0, selected.length - 1)))
                    var rows = try ContentsTextCodec.chapters(text.substring(with: range), book: self.book, base: self.basePage, defaultGroup: self.activeCategory == 0 ? 5 : self.activeCategory - 1)
                    for i in rows.indices where rows[i].page > 0 { let value = rows[i].page.addingReportingOverflow(delta); guard !value.overflow, (1...self.book.pages.count).contains(value.partialValue) else { throw ReaderFailure("调整后页码超出文档，本次未应用。") }; rows[i].page = value.partialValue }
                    let replacement = ContentsTextCodec.text(rows, book: self.book, base: self.basePage, localGroup: self.activeCategory == 0 ? nil : self.activeCategory - 1) + (text.substring(with: range).hasSuffix("\n") ? "\n" : "")
                    self.textView.insertText(replacement, replacementRange: range)
                } else {
                    var rows = self.draft.chapters; let selection = self.selectedIndices
                    guard !selection.isEmpty else { throw ReaderFailure("请先选择要调整的目录行。") }
                    for i in selection where rows[i].page > 0 { let value = rows[i].page.addingReportingOverflow(delta); guard !value.overflow, (1...self.book.pages.count).contains(value.partialValue) else { throw ReaderFailure("调整后页码超出文档，本次未应用。") }; rows[i].page = value.partialValue }
                    self.restoreStructure(rows, selection: selection)
                }
                self.message.textColor = .secondaryLabelColor; self.message.stringValue = "已批量调整页码，可撤销。"
            } catch { self.message.stringValue = error.localizedDescription; self.message.textColor = .systemRed }
        }
    }
    @objc func findReplace() {
        let alert = NSAlert(); alert.messageText = "查找与替换目录文本"; alert.informativeText = "查找会选中下一个匹配；替换全部作用于选中区域，无选择时作用于全文。支持正则表达式，替换中可用 $1 等分组。"
        let find = CenteredTextField(), replace = CenteredTextField(), regex = NSButton(checkboxWithTitle: "正则表达式", target: nil, action: nil)
        find.placeholderString = "查找内容"; replace.placeholderString = "替换为"
        let panel = NSStackView(views: [find, replace, regex]); panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 8; panel.frame = NSRect(x: 0, y: 0, width: 440, height: 94)
        find.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true; replace.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        alert.accessoryView = panel; alert.addButton(withTitle: "查找下一个"); alert.addButton(withTitle: "替换全部"); alert.addButton(withTitle: "取消")
        NativeDialog.alert(alert, on: window) { [weak self] response in
            guard let self, response != .alertThirdButtonReturn, !find.stringValue.isEmpty else { return }
            do {
                let pattern = regex.state == .on ? find.stringValue : NSRegularExpression.escapedPattern(for: find.stringValue), expression = try NSRegularExpression(pattern: pattern)
                let source = self.textView.string as NSString, selection = self.textView.selectedRange()
                if response == .alertFirstButtonReturn {
                    let start = NSMaxRange(selection), remaining = NSRange(location: start, length: source.length - start)
                    guard let match = expression.firstMatch(in: self.textView.string, range: remaining) ?? expression.firstMatch(in: self.textView.string, range: NSRange(location: 0, length: start)) else { throw ReaderFailure("未找到匹配内容。") }
                    self.window.makeFirstResponder(self.textView); self.textView.setSelectedRange(match.range); self.textView.scrollRangeToVisible(match.range)
                } else {
                    let range = selection.length > 0 ? selection : NSRange(location: 0, length: source.length), old = source.substring(with: range)
                    let replacement = regex.state == .on ? replace.stringValue : NSRegularExpression.escapedTemplate(for: replace.stringValue)
                    let updated = expression.stringByReplacingMatches(in: old, range: NSRange(location: 0, length: (old as NSString).length), withTemplate: replacement)
                    self.textView.insertText(updated, replacementRange: range)
                }
            } catch { self.message.stringValue = error.localizedDescription; self.message.textColor = .systemRed }
        }
    }
    @objc func openRegionOCR() {
        guard !busy, regionOCR == nil, !window.hasDocumentDialog else { return }; finishEditing()
        let controller = RegionOCRController(book: book,page: currentPage,allowCursor: true); regionOCR = controller
        controller.onClosed = { [weak self] in self?.regionOCR = nil }
        controller.onImport = { [weak self] text,atEnd in self?.insertRecognizedContents(text,atEnd: atEnd) }
        controller.show(on: window)
    }
    @discardableResult func insertReferenceContents(_ text:String)->Bool {
        guard !busy,!window.hasDocumentDialog else{return false}
        if !textActive {showContentsTab()}
        guard commitText() else{return false}
        activeCategory=0;categoryPopup.selectItem(at:0);categoryControl.selectedSegment=0;renderText()
        insertRecognizedContents(text,atEnd:true,sourceName:"在线参考目录")
        return true
    }
    func insertRecognizedContents(_ text: String,atEnd: Bool,sourceName:String = "框选识别结果") {
        if !textActive { showContentsTab() }
        let source = textView.string, position = atEnd ? (source as NSString).length : textView.selectedRange().location
        let (value,range) = ContentsOCRText.inserting(text,into: source,at: position)
        textView.breakUndoCoalescing(); textView.insertText(value,replacementRange: range); textView.breakUndoCoalescing()
        textView.setSelectedRange(NSRange(location: range.location+(value as NSString).length,length: 0)); textView.scrollRangeToVisible(textView.selectedRange())
        message.textColor = .secondaryLabelColor; message.stringValue = "已添加\(sourceName)。可继续修正页码、TAB层级；保存前不会改写图书，Command+Z 可撤销此次添加。"
        window.makeFirstResponder(textView)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if !busy { cancel() }; return false }
    @objc func cancel() { guard !busy else { return }; if window.hasDocumentDialog { window.bringDocumentDialogForward(); return }; regionOCR?.close(); NativeDialog.dismiss(window); onClosed?() }
    @objc func saveDraft() {
        if window.hasDocumentDialog { window.bringDocumentDialogForward(); return }
        guard !busy else { return }; finishEditing()
        guard commitText(strict: true) else { return }
        do {
            draft.chapters = try ContentsTextCodec.chapters(ContentsTextCodec.text(draft.chapters,book:book,base:basePage),book:book,base:basePage)
            _ = try draft.validated(for: book); _ = try draft.encodedInfo()
            busy = true; saveButton.isEnabled = false; contentsTable.isEnabled = false
            message.stringValue = "正在校验并保存，请稍候…"
            let savingDraft = draft, savingBook = book, backup = AppSettings().backups
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try savingBook.saveEdits(savingDraft, backup: backup, preserveDates: AppSettings().preserveFileDates, writeInfo: false) }
                DispatchQueue.main.async {
                    guard let self else { return }; self.busy = false; self.saveButton.isEnabled = true; self.contentsTable.isEnabled = true
                    switch result {
                    case .success(let backups): NativeDialog.dismiss(self.window); self.onSaved?(backups); self.onClosed?()
                    case .failure(let error): self.message.stringValue = error.localizedDescription; self.message.textColor = .systemRed
                    }
                }
            }
        } catch { message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    }
}
