import AppKit

final class NamingTemplateWindow: NSObject,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let window = ChineseWindow(contentRect:NSRect(x:0,y:0,width:850,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    let table = NSTableView(), name = NSTextField(), pattern = NSTextField()
    private let message = NSTextField(wrappingLabelWithString:"")
    private var values: [SavedNamingTemplate] = []
    var onChange: ((String?) -> Void)?
    var onClose: (() -> Void)?
    init(pattern: String) {
        super.init(); window.title = "管理命名格式"; window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width:680,height:400)
        for (id,title,width) in [("name","格式名称",180.0),("pattern","命名格式",600.0)] { let c = NSTableColumn(identifier:.init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.delegate = self; table.dataSource = self; table.rowHeight = 28; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        self.pattern.stringValue = pattern; name.stringValue = "我的格式"; name.placeholderString = "例如：古籍书名与版本"; self.pattern.placeholderString = "使用 {书名}、{作者} 等字段"
        let grid = NSGridView(views:[[NSTextField(labelWithString:"格式名称"),name],[NSTextField(labelWithString:"命名格式"),self.pattern]]); grid.column(at:0).width = 70; grid.columnSpacing = 10; grid.rowSpacing = 8
        let hint = NSTextField(wrappingLabelWithString:"可用字段："+BookMetadata.fields.map {"{"+$0+"}"}.joined(separator:" ")+"。预设格式保留；自定义格式可保存多条。")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize:11)
        func button(_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b }
        let actions = NSStackView(views:[button("保存为新格式",#selector(add)),button("更新所选",#selector(update)),button("删除所选",#selector(remove)),NSView(),button("关闭",#selector(close))]); actions.spacing = 8
        let root = NSStackView(views:[scroll,grid,hint,message,actions]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        let host = NSView(); window.contentView = host; host.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:host.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-16),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:140)])
        for v in [scroll,grid,hint,message,actions] { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }; reload()
    }
    func show(on parent: NSWindow) { NativeDialog.present(window,on:parent) }
    func reload() { values = NamingPreferences.library(); table.reloadData() }
    func numberOfRows(in tableView: NSTableView) -> Int { values.count }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? { let f = NSTextField(labelWithString:column?.identifier.rawValue == "name" ? values[row].name : values[row].pattern); f.lineBreakMode = .byTruncatingMiddle; f.toolTip = f.stringValue; return f }
    func tableViewSelectionDidChange(_ notification: Notification) { guard values.indices.contains(table.selectedRow) else { return }; let v = values[table.selectedRow]; name.stringValue = v.name; pattern.stringValue = v.pattern }
    @objc func add() { save(id:nil) }
    @objc func update() { guard values.indices.contains(table.selectedRow) else { message.stringValue = "请先选中要更新的格式。"; return }; save(id:values[table.selectedRow].id) }
    private func save(id: String?) {
        window.makeFirstResponder(nil)
        do { let key = try NamingPreferences.save(id:id,name:name.stringValue,pattern:pattern.stringValue); reload(); if let index = values.firstIndex(where:{$0.id == key}) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }; onChange?(key); message.stringValue = "已保存，单书和批量命名均可选择使用。" }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc func remove() { guard values.indices.contains(table.selectedRow) else { return }; NamingPreferences.delete(values[table.selectedRow].id); reload(); onChange?(nil); message.stringValue = "已删除；原来使用此格式的项目将回到自动格式。" }
    @objc func close() { NativeDialog.dismiss(window); onClose?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}
