import AppKit
import VisionKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private lazy var guide = AppGuide()
    @objc func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options:[.applicationName:"UVZ Reader Lab", .applicationVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "", .credits:NSAttributedString(string:"独立开发的扫描电子书阅读与整理应用。\n第三方组件许可随应用提供。\n当前为尚未公证的实验版。")])
    }
    @objc func showGuide() { guide.show(tab: 1) }
    @objc func showReleaseNotes() { guide.show(tab: 2) }
    var initialURL: URL?
    var smokeOutput: URL?
    var conversionTest = false
    var policyTest = false
    var batchTest = false
    var batchFolderURL: URL?
    private(set) var conversion: ConversionWindow?
    @objc func conversionCommand() {presentConversion([])}
    func presentConversion(_ urls:[URL]) {
        if conversion == nil {let controller=ConversionWindow();conversion=controller;controller.onClosed={[weak self] in self?.conversion=nil};controller.onOpen={[weak self] in self?.openURL($0)}}
        conversion?.show();if !urls.isEmpty {conversion?.add(urls)}
    }
    private(set) var batchNaming: BatchNamingWindow?
    var repairTest = false
    var identityTest = false
    var pagingTest = false
    var editorTest = false
    var metadataTest = false
    var regionTest = false
    private var regionText = ""
    private var batchFingerprints: [String:String] = [:]
    private var metadataSourceBytes: Data?
    @objc func toggleBackups() { let settings = AppSettings(); settings.set(!settings.backups, "backups") }
    private var editedBytes: Data?
    private(set) var readers: [ReaderController] = []
    private var recentMenu = NSMenu(title: "最近打开")
    private var pendingURLs: [URL] = []
    private var launched = false
    private var terminating = false
    private var smokeStage = 0
    private var smokeDeadline = Date()
    private var smokeChecks: [String] = []
    private var smokeOCR = "not-tested"
    private var smokePrimary: ReaderController?
    private var smokeSecond: ReaderController?
    private func ownsFocus(_ window: NSWindow) -> Bool { window.isKeyWindow || window.attachedSheet.map(ownsFocus) == true || window.childWindows?.contains(where: ownsFocus) == true }
    private var active: ReaderController? { readers.first { ownsFocus($0.window) } ?? readers.last }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ChineseMenus.install();AppIdentity.installIcon(); buildMenus(); launched = true
        let inputs = initialURL.map { [$0] } ?? pendingURLs
        if !inputs.isEmpty { inputs.forEach { openURL($0) } }
        else if smokeOutput == nil {
            let saved = UserDefaults.standard.array(forKey: "lastBooks") as? [String]
                ?? UserDefaults.standard.string(forKey: "lastBook").map { [$0] } ?? []
            let urls = (AppSettings().restoreSession ? saved : []).filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            if urls.isEmpty { _ = createWindow() } else { urls.forEach { openURL($0) } }
        }
        if smokeOutput != nil {
            smokePrimary = readers.first; smokeDeadline = Date().addingTimeInterval(repairTest || batchTest ? 240 : 60); if conversionTest {ConversionUITest.run(app:self,folder:batchFolderURL!,output:smokeOutput!)} else if policyTest { policyTick() } else if batchTest { batchTick() } else if identityTest { identityTick() } else if repairTest { repairTick() } else if pagingTest { pagingTick() } else if regionTest { regionTick() } else if metadataTest { metadataTick() } else if editorTest { editorTick() } else { smokeTick() }
        } else { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
    @discardableResult func createWindow() -> ReaderController {
        let reader = ReaderController(); reader.smokeMode = smokeOutput != nil
        reader.onOpenFiles = { [weak self] files in
            if files.isEmpty { self?.chooseBooks() } else { files.forEach { self?.openURL($0) } }
        }
        reader.onConvert = {[weak self] in self?.presentConversion($0)}
        reader.onBookChanged = { [weak self] in self?.saveSession() }
        reader.onCloseWindow = { [weak self] closed in self?.readers.removeAll { $0 === closed }; self?.saveSession() }
        readers.append(reader); reader.window.makeKeyAndOrderFront(nil)
        return reader
    }
    func openURL(_ url: URL, forceNew: Bool = false) {
        guard acceptsBookURL(url) else { return }
        let canonical = url.standardizedFileURL
        if !forceNew, let existing = readers.first(where: { $0.requestedURL == canonical || $0.book?.url == canonical }) {
            existing.window.makeKeyAndOrderFront(nil); return
        }
        let reader = !forceNew ? readers.first(where: { $0.book == nil && $0.requestedURL == nil }) ?? createWindow() : createWindow()
        reader.open(canonical); reader.window.makeKeyAndOrderFront(nil)
    }
    @objc func batchNamingCommand() { presentBatchNaming(choose:true) }
    func presentBatchNaming(choose: Bool) {
        if let batchNaming { batchNaming.show(); return }
        let controller = BatchNamingWindow(); batchNaming = controller
        controller.blockedReason = { [weak self] url in
            guard let self else { return nil }
            return self.readers.contains { reader in
                let path = reader.book?.url.path ?? reader.requestedURL?.path ?? ""
                return (path == url.path || path.hasPrefix(url.path+"/")) && reader.window.hasDocumentDialog
            } ? "图书正在编辑，请先关闭对应编辑窗口。" : nil
        }
        controller.onRenamed = { [weak self] old,new in
            guard let self else { return }
            for reader in self.readers {
                guard let url = reader.book?.url ?? reader.requestedURL else { continue }
                if url.path == old.path || url.path.hasPrefix(old.path+"/") {
                    let path = new.path + String(url.path.dropFirst(old.path.count))
                    reader.open(URL(fileURLWithPath:path),preserving:reader.state)
                }
            }
        }
        controller.onClosed = { [weak self] in self?.batchNaming = nil }
        controller.show(choose:choose)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if conversion?.isRunning == true {conversion?.show();return .terminateCancel}
        if batchNaming?.isApplying == true { batchNaming?.show(); return .terminateCancel }
        return .terminateNow
    }
    @objc func closeCurrentContext() {closeContext(NSApplication.shared.keyWindow)}
    func closeContext(_ key:NSWindow?) {
        if let key,["UVZDocumentDialog","UVZBatchNaming","UVZConversion"].contains(key.identifier?.rawValue ?? "") {key.performClose(nil)}
        else {active?.closeBook()}
    }
    @objc func newWindow() { _ = createWindow() }
    @objc func chooseBooks() {
        let panel = NSOpenPanel(); panel.title = "打开电子书或 PDG 文件夹"; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .pdf, .tiff] + ["local.uvzreader.uvz", "org.djvu.djvu", "local.uvzreaderlab.pdg"].map { UTType(importedAs: $0) }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK { panel.urls.forEach { self?.openURL($0) } }
        }
        panel.isMovable = true; panel.begin(completionHandler: completion)
    }
    private func saveSession() {
        guard smokeOutput == nil, !terminating else { return }
        UserDefaults.standard.set(readers.compactMap { $0.book?.url.path }, forKey: "lastBooks")
    }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if smokeOutput != nil { return true }
        let url = URL(fileURLWithPath: filename)
        guard acceptsBookURL(url) else { return false }
        if launched { openURL(url) } else { pendingURLs.append(url) }
        return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for file in filenames { _ = application(sender, openFile: file) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { _ = createWindow() }; return true
    }
    func applicationWillTerminate(_ notification: Notification) { saveSession(); terminating = true; readers.forEach { $0.save() } }
    private var focusedUndoManager: UndoManager? {
        if let region = active?.regionOCR ?? active?.editor?.regionOCR { return (region.window.firstResponder as? NSTextView)?.undoManager ?? region.resultText.undoManager }
        if let review = active?.renameSheet?.reviewWindow, review.window.isKeyWindow { return review.window.firstResponder?.undoManager }
        if let sheet = active?.editor { return sheet.editingUndoManager }
        if let sheet = active?.renameSheet { return sheet.window.firstResponder?.undoManager }
        return NSApplication.shared.keyWindow?.firstResponder?.undoManager
    }
    @objc private func undoEdit() { focusedUndoManager?.undo() }
    @objc private func redoEdit() { focusedUndoManager?.redo() }
    @objc private func findContents() { active?.editor?.showContentsTab(); active?.editor?.findReplace() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closeCurrentContext),["UVZBatchNaming","UVZConversion"].contains(NSApplication.shared.keyWindow?.identifier?.rawValue ?? "") { item.title = "关闭当前窗口"; return true }
        if item.action == #selector(closeCurrentContext) { item.title = NSApplication.shared.keyWindow?.identifier?.rawValue == "UVZDocumentDialog" ? "关闭当前窗口" : "关闭当前书籍"; return active?.book != nil || NSApplication.shared.keyWindow?.identifier?.rawValue == "UVZDocumentDialog" }
        if item.action == #selector(toggleBackups) { item.state = AppSettings().backups ? .on : .off; return true }
        if item.action == #selector(findContents) { return active?.editor != nil }
        if item.action == #selector(undoEdit) { return focusedUndoManager?.canUndo == true }
        if item.action == #selector(redoEdit) { return focusedUndoManager?.canRedo == true }
        return true
    }
    private func item(_ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = target; item.keyEquivalentModifierMask = modifiers; return item
    }
    private func addMenu(_ title: String, _ items: [NSMenuItem], to menu: NSMenu) -> NSMenu {
        let entry = NSMenuItem(); entry.title = title; let sub = NSMenu(title: title); entry.submenu = sub; menu.addItem(entry)
        items.forEach { sub.addItem($0) }; return sub
    }
    private func buildMenus() {
        let main = NSMenu()
        _ = addMenu("UVZ Reader Lab", [
            item("关于 UVZ Reader Lab", #selector(showAbout), target: self),
            .separator(),
            item("隐藏 UVZ Reader Lab", #selector(NSApplication.hide(_:)), "h"), .separator(),
            item("退出 UVZ Reader Lab", #selector(NSApplication.terminate(_:)), "q")
        ], to: main)
        let recent = NSMenuItem(title: "最近打开", action: nil, keyEquivalent: ""); recent.submenu = recentMenu; recentMenu.delegate = self
        _ = addMenu("文件", [item("新建阅读窗口", #selector(newWindow), "n", target: self), item("打开电子书…", #selector(chooseBooks), "o", target: self), recent, item("转换工作台…",#selector(conversionCommand),"k",target:self,modifiers:[.command,.shift]),item("批量规范命名…",#selector(batchNamingCommand),"b",target:self,modifiers:[.command,.shift]),
            .separator(), item("书籍信息与重命名…", #selector(ReaderController.renameZip), "r", modifiers: [.command, .shift]), 
            item("编辑目录…", #selector(ReaderController.editBook), "e", modifiers: [.command, .shift]),item("在线目录与封面…",#selector(ReaderController.showOnlineReferences)), .separator(), item("保存前备份原文件", #selector(toggleBackups), target: self), .separator(), item("关闭当前书籍", #selector(closeCurrentContext), "w", target: self),
            item("关闭窗口", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift])], to: main)
        let editingMenu = addMenu("编辑", [item("撤销", #selector(undoEdit), "z", target: self), item("重做", #selector(redoEdit), "z", target: self, modifiers: [.command, .shift]), .separator(), item("剪切", #selector(NSText.cut(_:)), "x"), item("复制", #selector(NSText.copy(_:)), "c"), item("全选", #selector(NSText.selectAll(_:)), "a"), item("粘贴", #selector(NSText.paste(_:)), "v"), .separator(), item("查找目录…", #selector(findContents), "f", target: self)], to: main)
        let conversions=NSMenuItem(title:"文字转换",action:nil,keyEquivalent:"");conversions.submenu=TextConversion.menu(target:nil,action:#selector(ChineseTextView.convertSelection));editingMenu.addItem(conversions)
        _ = addMenu("阅读", [item("上一页", #selector(ReaderController.previousPage), "["), item("下一页", #selector(ReaderController.nextPage), "]"),
            item("首页", #selector(ReaderController.firstPage)), item("末页", #selector(ReaderController.lastPage)), .separator(),
            item("单页视图", #selector(ReaderController.singlePageMode)), item("单页连续", #selector(ReaderController.singleContinuousMode)),
            item("双页视图", #selector(ReaderController.twoPageMode)), item("双页连续", #selector(ReaderController.twoContinuousMode)),
            item("双页时首页单独显示", #selector(ReaderController.toggleCoverAlone)), item("滚轮直接翻页", #selector(ReaderController.toggleWheelPaging)),
            item("从右至左", #selector(ReaderController.toggleDirection)), .separator(), item("框选识别目录…", #selector(ReaderController.recognizeRegion), "r", modifiers: [.command,.option]), item("自动文字选取", #selector(ReaderController.toggleOCR))], to: main)
        _ = addMenu("显示", [item("显示目录栏", #selector(ReaderController.toggleSidebar), "d", modifiers: [.command, .shift]),
            item("显示页码作为目录项", #selector(ReaderController.togglePageNumbers)), item("全部展开目录", #selector(ReaderController.expandContents)), item("全部折叠目录", #selector(ReaderController.collapseContents)), .separator(),
            item("适合宽度", #selector(ReaderController.fitWidth)), item("适合整页", #selector(ReaderController.fitWhole)), item("适合高度", #selector(ReaderController.fitHeight)), item("原始大小", #selector(ReaderController.actualSize)),
            item("放大", #selector(ReaderController.zoomIn), "+"), item("缩小", #selector(ReaderController.zoomOut), "-"), .separator(),
            item("页面跟随系统", #selector(ReaderController.systemColor)), item("页面原色", #selector(ReaderController.originalColor)), item("页面反色", #selector(ReaderController.invertedColor))], to: main)
        _ = addMenu("页面调整", [item("顺时针旋转", #selector(ReaderController.rotatePage)), item("四边裁边…", #selector(ReaderController.setCrop)), item("重置旋转与裁边", #selector(ReaderController.resetAppearance)), .separator(), item("页面编码校对…",#selector(ReaderController.repairPages))], to: main)
        let windows = addMenu("窗口", [item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"), item("缩放窗口", #selector(NSWindow.performZoom(_:))), item("全部前置", #selector(NSApplication.arrangeInFront(_:)))], to: main)
        let help = addMenu("帮助", [item("UVZ Reader Lab 功能说明", #selector(showGuide), target: self), item("更新说明", #selector(showReleaseNotes), target: self)], to: main)
        NSApplication.shared.helpMenu = help
        NSApplication.shared.windowsMenu = windows; NSApplication.shared.mainMenu = main
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }; menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let entry = item(url.deletingPathExtension().lastPathComponent, #selector(openRecent(_:)), target: self); entry.representedObject = url; menu.addItem(entry)
        }
        if menu.items.isEmpty { let none = NSMenuItem(title: "暂无最近书籍", action: nil, keyEquivalent: ""); none.isEnabled = false; menu.addItem(none) }
        else { menu.addItem(.separator()); menu.addItem(item("清除最近打开记录", #selector(clearRecent), target: self)) }
    }
    @objc private func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { openURL(url) } }
    @objc private func clearRecent() { NSDocumentController.shared.clearRecentDocuments(nil) }

    private func policyTick() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [self] in
            guard let folder = batchFolderURL,let output = smokeOutput else { failSmoke("Policy input missing");return }
            do {
                let previous = UserDefaults.standard.object(forKey:"settings.namingStyle")
                defer { if let previous {UserDefaults.standard.set(previous,forKey:"settings.namingStyle")} else {UserDefaults.standard.removeObject(forKey:"settings.namingStyle")} }
                for file in ["policy.pdf","policy.djvu"] {
                    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("uvz-policy-"+UUID().uuidString,isDirectory:true)
                    try FileManager.default.createDirectory(at:testDirectory,withIntermediateDirectories:true)
                    defer { try? FileManager.default.removeItem(at:testDirectory) }
                    let testSource = testDirectory.appendingPathComponent(file)
                    try FileManager.default.copyItem(at:folder.appendingPathComponent(file),to:testSource)
                    let book = try BookArchive(url:testSource),sheet = RenameSheet(book:book)
                    guard sheet.saveMetadata.isHidden else {throw ReaderFailure("PDF/DjVu should use mandatory native information saving")}
                    let host = createWindow(); NativeDialog.present(sheet.window,on:host.window)
                    let originalName = sheet.fields[1].stringValue
                    let evidence: [NamingEvidence] = [.init(field:"书名",value:originalName,source:"文档信息",page:nil,inferred:false),.init(field:"书名",value:"推荐书名",source:"CIP著录",page:1,inferred:false),.init(field:"书名",value:"推荐书名",source:"出版信息",page:1,inferred:false),.init(field:"丛书名",value:"研究丛书",source:"CIP著录",page:1,inferred:false)]
                    sheet.applyRecognition([:],evidence:evidence)
                    guard sheet.fields[1].stringValue == "推荐书名",sheet.nameField.stringValue.hasPrefix("【研究丛书】") else {throw ReaderFailure("Single-book automatic comparison or series naming failed")}
                    sheet.undoAutomatic();guard sheet.fields[1].stringValue == originalName else {throw ReaderFailure("Undo automatic adjustment failed")}
                    sheet.fields[1].stringValue = "手工标题";sheet.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:sheet.fields[1]));sheet.applyRecognition([:],evidence:evidence)
                    guard sheet.fields[1].stringValue == "手工标题" else {throw ReaderFailure("Manual change overwritten")}
                    let sourceIndex = sheet.recognitionSources.firstIndex(where:{$0.field == "书名" && $0.value == "推荐书名"})!
                    sheet.sourceTable.selectRowIndexes(IndexSet(integer:sourceIndex),byExtendingSelection:false)
                    guard NSApplication.shared.sendAction(sheet.sourceTable.doubleAction!,to:sheet.sourceTable.target,from:sheet.sourceTable),sheet.fields[1].stringValue == "推荐书名" else {throw ReaderFailure("Double-click source adoption failed")}
                    if file == "policy.pdf" {
                        sheet.manageTemplates();guard let manager = sheet.templateWindow else {throw ReaderFailure("Template manager missing")}
                        manager.name.stringValue = "界面测试格式"+UUID().uuidString;manager.pattern.stringValue = "{书名}_{ISBN}";manager.add()
                        guard let saved = NamingPreferences.library().last else {throw ReaderFailure("Template not saved")}
                        guard sheet.selectedStyleID == saved.id else {throw ReaderFailure("Saved format not selected")}
                        manager.pattern.stringValue = "{作者}_{书名}";manager.update();guard NamingPreferences.library().last?.pattern == "{作者}_{书名}" else {throw ReaderFailure("Template update failed")}
                        try captureView(manager.window.contentView!,to:output.deletingPathExtension().appendingPathExtension("templates.png"))
                        manager.remove();guard !NamingPreferences.library().contains(where:{$0.id == saved.id}) && sheet.selectedStyleID == NamingPreferences.automatic else {throw ReaderFailure("Template delete did not fall back")};manager.close()
                        try captureView(sheet.window.contentView!,to:output)
                    }
                    var savedURL: URL?
                    sheet.onRename = { stem,values,preserve in
                        guard let values else { throw ReaderFailure("Save and rename lost metadata") }
                        savedURL = try book.updateInformation(stem:stem,metadata:values,preserveDates:preserve)
                    }
                    sheet.rename()
                    guard let savedURL,try BookArchive(url:savedURL).metadata["书名"] == "推荐书名",!FileManager.default.fileExists(atPath:savedURL.path+".uvzmeta") else { throw ReaderFailure("Native save and rename UI failed") }
                    host.window.orderOut(nil)
                }
                let checks = ["PDF和DjVu保存并重命名同步内嵌信息，不产生旁存文件","单书自动比较已有值并采用CIP与出版信息印证的书名","自动包含丛书，缺失时自动省略","可撤回自动调整，后续手工修改受保护","来源表双击采用对应字段","命名格式管理窗口可新增、更新、删除并持久生效"]
                try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"version":"0.15.1"],options:[.prettyPrinted,.sortedKeys]).write(to:output.deletingPathExtension().appendingPathExtension("json"));print("POLICY_UI_OK");exit(0)
            } catch {failSmoke(error.localizedDescription)}
        }
    }

    private func batchTick() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [self] in
            guard let output = smokeOutput,let folder = batchFolderURL else { failSmoke("Batch fixture missing"); return }
            if Date()>smokeDeadline { failSmoke("Batch stage \(smokeStage)"); return }
            do {
                switch smokeStage {
                case 0:
                    let urls = try BatchNaming.discover(folder)
                    batchFingerprints = try Dictionary(uniqueKeysWithValues:urls.map { ($0.path,try BatchNaming.fingerprint($0)) })
                    presentBatchNaming(choose:false); batchNaming!.loadFolder(folder); advance()
                case 1:
                    guard let batch = batchNaming,!batch.isAnalysing,batch.items.count == 2,batch.items.allSatisfy({$0.proposal != nil}) else { batchTick(); return }
                    guard batch.items.allSatisfy({!$0.included && !$0.proposal!.suggestedName.isEmpty && $0.proposal!.evidence.contains(where:{$0.source == "CIP著录" || $0.source == "出版信息"}) && $0.proposal!.pages.contains(where:{$0.role == "封面"})}) else { throw ReaderFailure("Missing evidence or unexpected auto inclusion") }
                    for item in batch.items { guard try BatchNaming.fingerprint(item.url) == batchFingerprints[item.url.path] else { throw ReaderFailure("Analysis changed source") }; item.included = true; item.reviewed = true; item.customName = "同名候选测试" }
                    guard !batch.checkNames() else { throw ReaderFailure("Batch duplicate target accepted") }
                    for item in batch.items { item.included = false; item.customName = nil; item.reviewed = false }
                    batch.toggleAll(); guard batch.items.allSatisfy(\.included),batch.selectionHeader.check.state == .on else { throw ReaderFailure("Header select all failed") }
                    let check = NSButton(); check.tag = 0; check.state = .off; batch.includeChanged(check); guard batch.selectionHeader.check.state == .mixed else { throw ReaderFailure("Header mixed state missing") }
                    batch.toggleAll(); batch.toggleAll(); guard batch.items.allSatisfy({!$0.included}),batch.selectionHeader.check.state == .off else { throw ReaderFailure("Header deselect all failed") }
                    smokeChecks.append("表头复选框全选、部分选择和取消全选三态正确")
                    smokeChecks.append("选择文件夹自动分析，每书自动选择格式并展示版权页和封面依据；分析不改原件")
                    smokeChecks.append("多本图书同名目标在应用前阻止")
                    let reader = createWindow(); smokePrimary = reader; reader.open(batch.items[0].url); advance()
                case 2:
                    guard let batch = batchNaming,let reader = smokePrimary,reader.hasRenderedImage else { batchTick(); return }
                    reader.jump(1); batch.window.makeKeyAndOrderFront(nil); batch.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
                    batch.fields[1].stringValue = "界面核对书名"; batch.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:batch.fields[1]))
                    batch.uniformStyle.selectItem(at:0); batch.uniformStyleChanged()
                    batch.fields[4].stringValue = "待替换出版社"; batch.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:batch.fields[4]))
                    let sourceRow = batch.currentEvidence.firstIndex(where:{$0.field == "出版社" && $0.source == "CIP著录"})!
                    batch.evidenceTable.selectRowIndexes(IndexSet(integer:sourceRow),byExtendingSelection:false)
                    guard NSApplication.shared.sendAction(batch.evidenceTable.doubleAction!,to:batch.evidenceTable.target,from:batch.evidenceTable),batch.fields[4].stringValue == "江苏人民出版社" else {throw ReaderFailure("Batch double-click source failed")}
                    smokeChecks.append("批量来源表双击采用对应字段并刷新名称")
                    batch.reviewed.state = .on; batch.reviewChanged(); let include = NSButton(); include.tag = 0; include.state = .on; batch.includeChanged(include); batch.saveMetadata.state = .off; batch.preserveDates.state = .on
                    guard batch.checkNames(),batch.items[0].stem.hasPrefix("【"),batch.items[0].stem.contains("界面核对书名") else { throw ReaderFailure("Review or format choice failed") }
                    guard batch.window.contentView!.bounds.width<=1500,batch.window.contentView!.bounds.height<=1100 else { throw ReaderFailure("Batch layout exceeds usable size") }
                    batch.window.contentView?.layoutSubtreeIfNeeded(); batch.fitTableColumns()
                    guard batch.table.rect(ofColumn:3).maxX<=batch.table.enclosingScrollView!.contentView.frame.width+1,batch.evidenceTable.rect(ofColumn:3).maxX<=batch.evidenceTable.enclosingScrollView!.contentView.frame.width+1 else {throw ReaderFailure("Table status or physical-page column clipped")}
                    try captureView(batch.window.contentView!,to:output)
                    batch.showSources(); guard let source = batch.sourceWindow else { throw ReaderFailure("Batch source window missing") }
                    let page = batch.items[0].proposal!.pages.firstIndex(where:{$0.role == "版权页"})!
                    source.chooser.selectItem(at:page); source.pageChanged(); advance()
                case 3:
                    guard let batch = batchNaming,let source = batch.sourceWindow,source.image.image != nil else { batchTick(); return }
                    guard source.imageScroll.frame.width>250,source.text.enclosingScrollView!.frame.width>250 else { throw ReaderFailure("Source preview collapsed a pane") }
                    let scale = source.imageScroll.magnification; source.zoomIn(); guard source.imageScroll.magnification>scale else { throw ReaderFailure("Source image zoom failed") }; source.fitPage()
                    try captureView(source.window.contentView!,to:output.deletingPathExtension().appendingPathExtension("source.png")); source.closeWindow()
                    smokeChecks.append("可修订字段、自动包含丛书、人工确认差异，并查看对应原图和识别原文")
                    editedBytes = try Data(contentsOf:batch.items[0].url)
                    try BatchNaming.csv(batch.items).write(to:output.deletingPathExtension().appendingPathExtension("csv"),atomically:true,encoding:.utf8)
                    batch.applySelected(); advance()
                default:
                    guard let batch = batchNaming,!batch.isApplying,let reader = smokePrimary,reader.book?.url == batch.items[0].url,reader.hasRenderedImage else { batchTick(); return }
                    guard batch.items[0].outcome == "已完成",batch.items[1].outcome == nil,reader.state.page == 1,try Data(contentsOf:batch.items[0].url) == editedBytes else { throw ReaderFailure("Batch rename, selection or reading position failed") }
                    guard try BatchNaming.fingerprint(batch.items[1].url) == batchFingerprints[batch.items[1].url.path] else { throw ReaderFailure("Unchecked book changed") }
                    smokeChecks.append("仅改名勾选项；默认不写BookInfo，整书字节不变")
                    smokeChecks.append("已打开图书更新路径并保留阅读位置，未勾选项目不变")
                    try captureView(batch.window.contentView!,to:output.deletingPathExtension().appendingPathExtension("done.png")); batch.closeWindow(); guard batchNaming == nil else { throw ReaderFailure("Batch close failed") }
                    try JSONSerialization.data(withJSONObject:["passed":true,"checks":smokeChecks,"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? ""],options:[.prettyPrinted,.sortedKeys]).write(to:output.deletingPathExtension().appendingPathExtension("json"))
                    print("BATCH_UI_OK"); exit(0)
                }
            } catch { failSmoke(error.localizedDescription); return }
            batchTick()
        }
    }
    private func identityTick() {
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [self] in
            do {
                guard let output = smokeOutput, NSApplication.shared.activationPolicy() == .regular,
                      let icon = NSApplication.shared.applicationIconImage,icon.isValid,
                      let view = NSApplication.shared.dockTile.contentView as? NSImageView,view.image?.isValid == true,
                      NSRunningApplication.current.icon?.isValid == true else { throw ReaderFailure("Runtime Dock image missing") }
                try captureView(view,to:output)
                let main = NSApplication.shared.mainMenu!, app = main.items.first!.submenu!, help = NSApplication.shared.helpMenu!
                guard !app.items.contains(where:{ $0.action == #selector(showGuide) || $0.action == #selector(showReleaseNotes) }),help.items.filter({$0.action == #selector(showGuide)}).count == 1,help.items.filter({$0.action == #selector(showReleaseNotes)}).count == 1 else { throw ReaderFailure("Duplicate help entries") }
                for name in ["UserGuide","ReleaseNotes"] {
                    let text = try String(contentsOf:Bundle.main.url(forResource:name,withExtension:"md")!,encoding:.utf8)
                    guard !text.contains("張純一"),!text.contains("张纯一"),!text.contains("fow007"),!text.contains("改造基督") else { throw ReaderFailure("Concrete book example in help") }
                }
                try JSONSerialization.data(withJSONObject:["passed":true,"checks":["regular app launch has a valid application image, Dock view and running application icon","Dock view renders the bundled icon","Help has single guide and release entries; About has neither","Bundled guide and release notes contain no specific book examples"],"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? ""],options:[.prettyPrinted,.sortedKeys]).write(to:output.deletingPathExtension().appendingPathExtension("json"))
                print("IDENTITY_UI_OK"); exit(0)
            } catch { failSmoke(error.localizedDescription) }
        }
    }
    private func repairTick() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [self] in
            guard let reader = smokePrimary,let output = smokeOutput else { failSmoke("Repair fixture missing"); return }
            if Date()>smokeDeadline { failSmoke("Repair stage \(smokeStage): \(reader.diagnosticStatus)"); return }
            do {
                switch smokeStage {
                case 0:
                    guard reader.hasRenderedImage else { repairTick(); return }
                    editedBytes = try Data(contentsOf:reader.book!.url)
                    guard reader.pageFindings.contains(where:{$0.id.hasPrefix("gap:5:441")}) else { throw ReaderFailure("Automatic gap hint missing") }
                    reader.jump(13); reader.editBook()
                    guard let editor = reader.editor else { throw ReaderFailure("Repair editor missing") }
                    editor.textView.string = "改造基督教之讨论\t441\n原目标\tfow7\n已有正文\t473"; editor.repairPages()
                    guard editor.pageRepair != nil else { throw ReaderFailure("Nested page correction missing") }
                    smokeChecks.append("阅读自动提示类型断号，目录草稿可进入页面校对")
                    advance()
                case 1:
                    guard let repair = reader.editor?.pageRepair else { throw ReaderFailure("Repair dialog missing") }
                    guard repair.didScan else { repairTick(); return }
                    guard let row = repair.findings.firstIndex(where:{$0.page == 14 && $0.suggestedGroup == 5 && $0.suggestedNumber == 441}) else { throw ReaderFailure("Automatic cross-type title finding missing: \(repair.findings.map(\.text))") }
                    guard try Data(contentsOf:reader.book!.url) == editedBytes else { throw ReaderFailure("Inspection modified book") }
                    repair.pageTable.selectRowIndexes(IndexSet([13,14]),byExtendingSelection:false); repair.typePopup.selectItem(at:5); repair.numberField.stringValue = "441"; repair.queueSelection()
                    guard repair.pending[13]?.number == 441,repair.pending[14]?.number == 442 else { throw ReaderFailure("Batch continuous numbering") }
                    repair.clearChanges()
                    repair.findingTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); repair.useFinding()
                    guard repair.pending[13]?.number == 441 else { throw ReaderFailure("Suggestion not queued") }
                    smokeChecks.append("OCR结合未匹配目录标题找出疑似错编，只读检查不写书；批量连续编号可预览撤回")
                    advance()
                case 2:
                    guard let repair = reader.editor?.pageRepair,repair.preview.image != nil else { repairTick(); return }
                    guard repair.window.contentView!.bounds.width <= 1300,repair.window.contentView!.bounds.height <= 950 else { throw ReaderFailure("Page image expanded correction window beyond usable size") }
                    try captureView(repair.window.contentView!,to:output)
                    repair.applyChanges(); advance()
                case 3:
                    guard let editor = reader.editor else { throw ReaderFailure("Directory draft lost") }
                    guard editor.pageRepair == nil,reader.book?.pages[reader.state.page].name == "000441.pdg",reader.hasRenderedImage else { repairTick(); return }
                    guard editor.draft.chapters.map(\.page) == [466,466,493],editor.draft.chapters.allSatisfy({$0.unresolvedTarget == nil}),reader.state.page == 465 else { throw ReaderFailure("Draft targets or current image not remapped") }
                    smokeChecks.append("页面实际改编码并重排，目录草稿、已有目标与阅读位置跟随同一图像")
                    try captureView(editor.window.contentView!,to:output.deletingPathExtension().appendingPathExtension("draft.png"))
                    editor.saveDraft(); advance()
                default:
                    guard reader.editor == nil,reader.hasRenderedImage else { repairTick(); return }
                    guard reader.book!.chapters.map({$0.pageIndex+1}) == [466,466,493],reader.state.page == 465 else { throw ReaderFailure("Corrected directory save roundtrip") }
                    let before = try Data(contentsOf:reader.book!.url)
                    reader.repairPages(); guard let repair = reader.pageRepair else { throw ReaderFailure("Reader correction entry missing") }
                    repair.closeWindow(); guard reader.pageRepair == nil,try Data(contentsOf:reader.book!.url) == before else { throw ReaderFailure("Cancel changed file") }
                    smokeChecks.append("纠正后目录保存重读正确；阅读窗口可单独校对，取消保持文件不变")
                    try capture(reader,to:output.deletingPathExtension().appendingPathExtension("reader.png"))
                    try JSONSerialization.data(withJSONObject:["passed":true,"checks":smokeChecks,"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? ""],options:[.prettyPrinted,.sortedKeys]).write(to:output.deletingPathExtension().appendingPathExtension("json"))
                    print("REPAIR_UI_OK"); exit(0)
                }
            } catch { failSmoke(error.localizedDescription); return }
            repairTick()
        }
    }
    private func checkMovableDialog(_ child: NSWindow, parent: NSWindow) throws {
        guard child.isMovable, child.styleMask.contains(.titled), child.sheetParent == nil, child.parent === parent else { throw ReaderFailure("Dialog is not an independent native window") }
        let old = child.frame, base = parent.frame
        child.setFrameOrigin(NSPoint(x: old.minX+24,y: old.minY-24))
        guard child.frame.origin != old.origin, parent.frame == base else { throw ReaderFailure("Dialog movement changed parent window") }
        child.setFrame(old,display:true)
    }
    private func editCell(_ table: NSTableView, column: Int, row: Int, text: String, editor: BookEditor) throws {
        table.layoutSubtreeIfNeeded()
        guard let field = table.view(atColumn: column, row: row, makeIfNecessary: true) as? EditorField else { throw ReaderFailure("Editor cell missing") }
        field.stringValue = text
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }
    private func editorTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard let reader = smokePrimary, let output = smokeOutput else { failSmoke("missing editor fixture"); return }
            if Date() > smokeDeadline { failSmoke("editor stage \(smokeStage): \(reader.diagnosticStatus)"); return }
            do {
                switch smokeStage {
                case 0:
                    guard reader.hasRenderedImage else { editorTick(); return }
                    guard reader.checkDisplayControls() else { throw ReaderFailure("Display controls or cover pairing") }
                    smokeChecks += ["四种显示方式的列表与按钮双向同步", "首页单独、双页配对与从右至左", "双页连续显示", "文件名旁直接重命名及书籍信息入口"]
                    smokeStage = 1
                case 1:
                    guard reader.checkDoubleClickInput() else { throw ReaderFailure("Double-click page direction") }
                    smokeChecks.append("双击左右半区翻页并随阅读方向切换"); smokeStage = 2
                case 2:
                    guard reader.sendTestWheel(1) else { throw ReaderFailure("Wheel forward") }; smokeStage = 3
                case 3:
                    guard reader.sendTestWheel(-1) else { throw ReaderFailure("Wheel backward") }
                    smokeChecks.append("鼠标滚轮上下直接翻页")
                    try capture(reader, to: output.deletingPathExtension().appendingPathExtension("reader.png"))
                    reader.renameZip(); smokeStage = 4
                case 4:
                    guard let rename = reader.renameSheet else { throw ReaderFailure("Rename panel not opened") }
                    try checkMovableDialog(rename.window, parent:reader.window)
                    reader.closeBook(); guard reader.book != nil, !reader.windowShouldClose(reader.window) else { throw ReaderFailure("Parent closed with information draft") }
                    smokeChecks.append("信息窗口原生标题栏可独立移动，编辑期间保护原书窗口")
                    for (key, value) in ["书名":"编辑测试书", "作者":"测试作者", "出版社":"测试出版社", "出版日期":"2026.03", "SS号":"12345678", "丛书名":"研究丛书"] { rename.fields[rename.keys.firstIndex(of:key)!].stringValue = value }
                    guard rename.keys == ["ISBN", "书名", "作者", "丛书名", "出版社", "出版日期", "页数", "SS号", "DX号"], rename.style.numberOfItems >= 4 else { throw ReaderFailure("Field order or presets") }
                    rename.style.selectItem(at:1); rename.generateName()
                    guard rename.nameField.stringValue == "编辑测试书_测试作者_测试出版社_2026.03_12345678" else { throw ReaderFailure("Filename assembly") }
                    rename.style.selectItem(at: 0); rename.generateName()
                    guard rename.nameField.stringValue == "【研究丛书】编辑测试书_测试作者_测试出版社_2026.03_12345678" else { throw ReaderFailure("Series filename template") }
                    let previous = UserDefaults.standard.object(forKey: "settings.customTemplate")
                    rename.style.selectItem(at:rename.style.numberOfItems-1); rename.templateField.stringValue = "{出版日期}·{书名}_{SS号}"; rename.generateName()
                    guard rename.nameField.stringValue == "2026.03·编辑测试书_12345678" else { throw ReaderFailure("Custom filename template") }
                    if let previous { UserDefaults.standard.set(previous, forKey: "settings.customTemplate") } else { UserDefaults.standard.removeObject(forKey: "settings.customTemplate") }
                    smokeChecks.append("自定义命名格式与出版年月生成")
                    rename.style.selectItem(at: 0); rename.generateName()
                    try captureView(rename.window.contentView!, to: output.deletingPathExtension().appendingPathExtension("rename.png"))
                    rename.close(); smokeChecks.append("重命名按书名作者出版社出版年月SS号生成，取消不改名")
                    reader.editBook(); smokeStage = 5
                case 5:
                    guard let sheet = reader.editor else { throw ReaderFailure("Text editor not shown") }
                    try checkMovableDialog(sheet.window,parent:reader.window); smokeChecks.append("目录编辑窗口可独立移动")
                    sheet.window.makeFirstResponder(sheet.textView)
                    let source = "界面测试目录\t2\n\t第二级目录\t3"
                    sheet.textView.insertText(source, replacementRange: NSRange(location: 0, length: (sheet.textView.string as NSString).length))
                    sheet.textView.breakUndoCoalescing()
                    guard sheet.textView.undoManager?.canUndo == true else { throw ReaderFailure("Text undo missing") }
                    guard NSApplication.shared.sendAction(#selector(undoEdit), to: self, from: nil) else { throw ReaderFailure("Undo responder action") }; guard sheet.textView.string.isEmpty else { throw ReaderFailure("Text undo incorrect") }
                    guard NSApplication.shared.sendAction(#selector(redoEdit), to: self, from: nil) else { throw ReaderFailure("Redo responder action") }; guard sheet.textView.string == source else { throw ReaderFailure("Text redo incorrect") }
                    sheet.textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0)); sheet.textView.insertNewline(nil)
                    guard sheet.textView.string.hasSuffix("\n\t") else { throw ReaderFailure("Newline indentation") }
                    sheet.textView.insertBacktab(nil); guard sheet.textView.string.hasSuffix("\n") else { throw ReaderFailure("Shift tab outdent") }
                    sheet.textView.string = source
                    smokeChecks.append("目录文本录入、撤销重做、回车自动缩进与Shift TAB")
                    try captureView(sheet.window.contentView!, to: output)
                    sheet.showStructureTab(); smokeStage = 6
                case 6:
                    guard let sheet = reader.editor, sheet.contentsTable.numberOfRows == 2, let root = sheet.contentsTable.item(atRow: 0) else { throw ReaderFailure("Tree contents") }
                    guard sheet.contentsTable.level(forRow: 1) == 1 else { throw ReaderFailure("Tree indentation") }
                    sheet.contentsTable.collapseItem(root); guard sheet.contentsTable.numberOfRows == 1 else { throw ReaderFailure("Tree collapse") }
                    sheet.contentsTable.expandItem(root); sheet.contentsTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                    sheet.outdent(); sheet.indent(); sheet.moveUp(); sheet.moveDown()
                    sheet.showContentsTab(); sheet.textView.string = "A\t1\nB\t2\n\tB1\t3\nC\t3"; sheet.showStructureTab()
                    sheet.contentsTable.selectRowIndexes(IndexSet([1,3]), byExtendingSelection: false); sheet.indent()
                    guard sheet.draft.chapters.map(\.level) == [0,1,2,1], sheet.contentsTable.selectedRowIndexes.count == 2 else { throw ReaderFailure("Multiple selected subtree indent") }
                    try captureView(sheet.window.contentView!, to: output.deletingPathExtension().appendingPathExtension("tree.png"))
                    sheet.outdent(); guard sheet.draft.chapters.map(\.level) == [0,0,1,0] else { throw ReaderFailure("Multiple selected subtree outdent") }
                    sheet.window.makeFirstResponder(sheet.contentsTable); undoEdit(); guard sheet.draft.chapters.map(\.level) == [0,1,2,1] else { throw ReaderFailure("Structure menu undo") }; redoEdit()
                    sheet.removeChapter(); guard sheet.draft.chapters.map(\.title) == ["A"] else { throw ReaderFailure("Multiple deletion") }; undoEdit()
                    smokeChecks.append("树形多选升降级、子目录随动、多项删除及菜单撤销重做")
                    sheet.showContentsTab(); sheet.textView.string = "界面测试目录\t2\n\t第二级目录\t3"
                    sheet.textView.setSelectedRange(NSRange(location: 0, length: (sheet.textView.string as NSString).length)); sheet.indentText(); sheet.outdentText()
                    guard sheet.textView.string == "界面测试目录\t2\n\t第二级目录\t3" else { throw ReaderFailure("Multiline text indent") }
                    smokeChecks.append("目录文本多行统一升降级")
                    sheet.showStructureTab()
                    smokeChecks.append("文本与树形互转、树形折叠展开及整组调级")
                    sheet.showContentsTab(); guard sheet.textView.string == "界面测试目录\t2\n\t第二级目录\t3" else { throw ReaderFailure("Text/tree roundtrip") }
                    smokeStage = 7
                case 7:
                    guard let sheet = reader.editor else { throw ReaderFailure("Contents editor missing") }
                    sheet.saveDraft(); smokeStage = 8
                case 8:
                    guard reader.editor == nil, reader.hasRenderedImage else { editorTick(); return }
                    guard reader.book?.chapters.map(\.title) == ["界面测试目录", "第二级目录"], reader.book?.chapters.map(\.level) == [0, 1],
                          reader.state.page == 1 else { throw ReaderFailure("Saved editor data or position mismatch") }
                    smokeChecks.append("目录编辑独立保存，保留原书籍信息")
                    smokeChecks.append("目录与BookInfo保存后重读并保留位置")
                    editedBytes = try Data(contentsOf: reader.book!.url); reader.editBook(); smokeStage = 9
                case 9:
                    guard let sheet = reader.editor else { throw ReaderFailure("Cancel editor not shown") }
                    sheet.textView.string = "未保存的改动"; sheet.cancel()
                    guard try Data(contentsOf: reader.book!.url) == editedBytes else { throw ReaderFailure("Cancel modified original") }
                    smokeChecks.append("取消编辑不改文件")
                    reader.renameZip(); smokeStage = 10
                case 10:
                    guard let sheet = reader.renameSheet else { throw ReaderFailure("Rename action not available") }
                    sheet.abstractView.string = "第一段摘要\n第二段摘要"
                    sheet.addInfo(); let row = sheet.numberOfRows(in: sheet.infoTable) - 1
                    sheet.infoTable.layoutSubtreeIfNeeded()
                    for (column,value) in [(0,"测试字段"),(1,"新增信息保留")] {
                        guard let field = sheet.infoTable.view(atColumn:column,row:row,makeIfNecessary:true) as? EditorField else { throw ReaderFailure("Custom info field") }
                        field.stringValue = value; sheet.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field))
                    }
                    sheet.applyRecognition(["ISBN":"9780306406157","作者":"识别作者","出版社":"示例出版社"])
                    try captureView(sheet.window.contentView!,to:output.deletingPathExtension().appendingPathExtension("info.png"))
                    sheet.nameField.stringValue = "界面改名"; sheet.rename(); smokeStage = 11
                default:
                    guard reader.hasRenderedImage, let book = reader.book else { editorTick(); return }
                    guard book.url.deletingPathExtension().lastPathComponent == "界面改名", reader.state.page == 1,
                          book.chapters.count == 2, book.metadata["测试字段"] == "新增信息保留", book.metadata["摘要"] == "第一段摘要 第二段摘要" else { throw ReaderFailure("Rename did not retain book or position") }
                    smokeChecks.append("统一信息窗口保存摘要、自定义字段和改名，保留目录与阅读位置")
                    guard NSApplication.shared.mainMenu?.items.first?.submenu?.items.contains(where: { $0.title.hasPrefix("设置") }) == false,
                          let backup = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "文件" })?.submenu?.items.first(where: { $0.action == #selector(toggleBackups) }) else { throw ReaderFailure("Settings removal or File backup command") }
                    let before = AppSettings().backups; _ = validateMenuItem(backup)
                    guard backup.state == (before ? .on : .off) else { throw ReaderFailure("Backup menu checkmark") }
                    toggleBackups(); guard AppSettings().backups != before else { throw ReaderFailure("Backup menu enable") }; toggleBackups()
                    smokeChecks.append("移除设置入口，文件菜单备份开关可切换并记住")
                    guide.show(tab: 1); try captureView(guide.window.contentView!, to: output.deletingPathExtension().appendingPathExtension("guide.png"))
                    guide.show(tab: 2); try captureView(guide.window.contentView!, to: output.deletingPathExtension().appendingPathExtension("releases.png")); guide.window.close()
                    smokeChecks.append("应用内离线功能说明与更新说明可以打开")
                    let report: [String: Any] = ["passed": true, "checks": smokeChecks, "version": "0.15.1"]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.deletingPathExtension().appendingPathExtension("json"))
                    print("EDITOR_UI_OK"); exit(0)
                }
            } catch { failSmoke(error.localizedDescription); return }
            editorTick()
        }
    }
    private func pagingTick() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [self] in
            guard let reader = smokePrimary, let output = smokeOutput else { failSmoke("Paging fixture"); return }
            if Date()>smokeDeadline { failSmoke("Paging stage \(smokeStage): \(reader.diagnosticStatus)"); return }
            do {
                switch smokeStage {
                case 0:
                    guard reader.hasRenderedImage else { pagingTick(); return }
                    reader.pageTypePopup.selectItem(withTag:5); reader.pageTypeChanged()
                    reader.pageField.stringValue = "473"; reader.pageEntered()
                    guard reader.state.page == 492, reader.pageField.stringValue == "473", reader.pageTypePopup.selectedItem?.tag == 5 else { throw ReaderFailure("Body 473 navigation") }
                    smokeChecks.append("真实张纯一集：正文473定位000473.pdg，物理493")
                    advance()
                case 1:
                    guard reader.renderedPageIndices.contains(492) else { pagingTick(); return }
                    try capture(reader,to:output.deletingPathExtension().appendingPathExtension("reader.png"))
                    reader.pageTypePopup.selectItem(withTag:2); reader.pageTypeChanged()
                    guard reader.book!.pages[reader.state.page].key.group == 2, reader.pageField.stringValue == "1" else { throw ReaderFailure("Copyright type navigation") }
                    reader.pageTypePopup.selectItem(withTag:-1); reader.pageTypeChanged(); reader.pageField.stringValue = "493"; reader.pageEntered()
                    guard reader.state.page == 492, reader.pageTypePopup.selectedItem?.tag == -1 else { throw ReaderFailure("Physical navigation") }
                    reader.pageField.stringValue = "99999"; reader.pageEntered(); guard reader.state.page == 492 else { throw ReaderFailure("Invalid page changed position") }
                    smokeChecks.append("页面类型切换、类型页号、物理页与无效输入保持位置")
                    reader.editBook(); advance()
                case 2:
                    guard let sheet = reader.editor else { throw ReaderFailure("Paging editor missing") }
                    sheet.textView.string = "正文目录\t473\n待修页号\t99999"
                    sheet.modeControl.selectedSegment = 1; sheet.editorModeChanged()
                    guard !sheet.isTextMode, sheet.modeControl.selectedSegment == 1, sheet.contentsTable.window === sheet.window, sheet.contentsTable.bounds.height > 150, sheet.contentsTable.numberOfRows == 2, sheet.draft.chapters[0].page == 493, sheet.draft.chapters[1].unresolvedTarget != nil else { throw ReaderFailure("Unresolved tree: text=\(sheet.isTextMode), segment=\(sheet.modeControl.selectedSegment), rows=\(sheet.contentsTable.numberOfRows), height=\(sheet.contentsTable.bounds.height), window=\(sheet.contentsTable.window != nil), pages=\(sheet.draft.chapters.map(\.page)), errors=\(sheet.draft.chapters.map { $0.unresolvedTarget ?? "-" })") }
                    guard (0..<2).filter({sheet.modeControl.isSelected(forSegment:$0)}).count == 1 else { throw ReaderFailure("Both editor modes selected") }
                    sheet.saveDraft(); guard reader.editor === sheet else { throw ReaderFailure("Invalid tree was saved") }
                    smokeChecks.append("模式互斥，错误页号可切入真实树形并阻止错误保存")
                    try captureView(sheet.window.contentView!,to:output.deletingPathExtension().appendingPathExtension("error.png"))
                    guard let field = sheet.contentsTable.view(atColumn:2,row:1,makeIfNecessary:true) as? EditorField else { throw ReaderFailure("Tree page field") }
                    field.stringValue = "474"; sheet.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field))
                    guard sheet.draft.chapters[1].page == 494, sheet.draft.chapters[1].unresolvedTarget == nil else { throw ReaderFailure("Tree page correction") }
                    sheet.contentsTable.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false); sheet.indent()
                    guard sheet.draft.chapters.map(\.level) == [0,1] else { throw ReaderFailure("Real tree indent") }
                    sheet.showContentsTab(); sheet.categoryControl.selectedSegment = 4; sheet.categorySelected()
                    guard sheet.textView.string.isEmpty else { throw ReaderFailure("Foreword scope did not filter body") }
                    sheet.textView.string = "前言目录\t1"; sheet.categoryControl.selectedSegment = 0; sheet.categorySelected()
                    guard sheet.textView.string.contains("fow1"), sheet.textView.string.contains("473"), sheet.textView.string.contains("474") else { throw ReaderFailure("Section draft lost body") }
                    sheet.categoryControl.selectedSegment = 6; sheet.categorySelected(); guard !sheet.textView.string.contains("前言目录"), sheet.textView.string.contains("473") else { throw ReaderFailure("Body scope") }
                    sheet.textView.string += "\n正文新增\t475"; sheet.showStructureTab()
                    guard sheet.draft.chapters.count == 4, sheet.draft.chapters[0].page == 8 else { throw ReaderFailure("Section numeric page mapping or draft merge") }
                    try captureView(sheet.window.contentView!,to:output)
                    smokeChecks.append("树形直接改页号及升降级、文本分区数字页号和跨分区保留")
                    sheet.saveDraft(); advance()
                default:
                    guard reader.editor == nil, reader.hasRenderedImage else { pagingTick(); return }
                    guard reader.book!.chapters.map({$0.pageIndex+1}) == [8,493,494,495], reader.book!.chapters.map(\.level) == [0,0,1,0], reader.state.page == 492 else { throw ReaderFailure("Typed directory save roundtrip") }
                    smokeChecks.append("真实图书副本保存重读，类型页号正确映射并保留阅读位置")
                    try JSONSerialization.data(withJSONObject:["passed":true,"checks":smokeChecks,"version":"0.15.1"],options:[.prettyPrinted,.sortedKeys]).write(to:output.deletingPathExtension().appendingPathExtension("json"))
                    print("PAGING_UI_OK"); exit(0)
                }
            } catch { failSmoke(error.localizedDescription); return }
            pagingTick()
        }
    }
    private func selectRegion(_ controller: RegionOCRController,_ rect: CGRect) throws {
        let canvas = controller.canvas, image = canvas.imageRect
        let start = canvas.convert(CGPoint(x: image.minX+rect.minX*image.width,y: image.minY+rect.minY*image.height),to: nil)
        let end = canvas.convert(CGPoint(x: image.minX+rect.maxX*image.width,y: image.minY+rect.maxY*image.height),to: nil)
        func event(_ type: NSEvent.EventType,_ point: CGPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type,location: point,modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: controller.window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1) else { throw ReaderFailure("Region mouse event") }; return event
        }
        canvas.mouseDown(with: try event(.leftMouseDown,start)); canvas.mouseDragged(with: try event(.leftMouseDragged,end)); canvas.mouseUp(with: try event(.leftMouseUp,end))
    }
    private func regionTick() {
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4) { [self] in
            guard let reader = smokePrimary,let output = smokeOutput else { failSmoke("Region fixture"); return }
            if Date()>smokeDeadline { failSmoke("Region stage \(smokeStage)"); return }
            do {
                switch smokeStage {
                case 0:
                    guard reader.hasRenderedImage,let book = reader.book else { regionTick(); return }
                    editedBytes = try Data(contentsOf: book.url); reader.recognizeRegion(); advance()
                case 1:
                    guard let region=reader.regionOCR,!region.loading,region.canvas.imageRect.width>0 else { regionTick(); return }
                    try checkMovableDialog(region.window,parent:reader.window); smokeChecks.append("框选识别窗口原生标题栏可独立移动")
                    try selectRegion(region,CGRect(x: 0.025,y: 0.12,width: 0.48,height: 0.35)); advance()
                case 2:
                    guard let region=reader.regionOCR,!region.recognizing,!region.resultText.string.isEmpty else { regionTick(); return }
                    let text=region.resultText.string
                    guard text.contains("LEFT"),text.contains("SECTION"),!text.contains("RIGHT"),!text.contains("HEADER"),!text.contains("FOOTER") else { throw ReaderFailure("Region leaked adjacent column/header: "+text) }
                    smokeChecks.append("鼠标框选实际OCR只识别左栏，不混入邻栏、页眉或页脚")
                    try captureView(region.window.contentView!,to: output)
                    try selectRegion(region,CGRect(x: 0.53,y: 0.12,width: 0.46,height: 0.35)); advance()
                case 3:
                    guard let region=reader.regionOCR,!region.recognizing,region.resultText.string.contains("RIGHT") else { regionTick(); return }
                    guard let first=region.resultText.string.range(of: "LEFT"),let second=region.resultText.string.range(of: "RIGHT"),first.lowerBound<second.lowerBound else { throw ReaderFailure("Region append order") }
                    smokeChecks.append("连续框选两栏时按操作顺序追加识别结果")
                    region.splitNumbers(); guard region.resultText.string.contains("\t") else { throw ReaderFailure("OCR page split") }
                    try captureView(region.window.contentView!,to: output.deletingPathExtension().appendingPathExtension("both.png")); region.importResult(); advance()
                case 4:
                    guard let sheet=reader.editor,reader.regionOCR == nil else { regionTick(); return }
                    regionText=sheet.textView.string
                    var draft=BookEditDraft(book: reader.book!); draft.chapters=try ContentsTextCodec.chapters(regionText,book: reader.book!); _=try draft.validated(for: reader.book!)
                    guard draft.chapters.count==4,draft.chapters.map(\.page)==[1,2,3,2],try Data(contentsOf: reader.book!.url)==editedBytes else { throw ReaderFailure("Region imported draft/page mismatch") }
                    smokeChecks.append("点线页码转换后送入目录草稿，添加前后原文件不变")
                    sheet.textView.string="Existing\t1\nTail\t2"; sheet.textView.undoManager?.removeAllActions(); sheet.textView.setSelectedRange(NSRange(location: 0,length: 8)); sheet.openRegionOCR(); advance()
                case 5:
                    guard let sheet=reader.editor,let region=sheet.regionOCR,!region.loading else { regionTick(); return }
                    region.resultText.string="Ignored ...... 1\nInserted ...... 3\nIgnored ...... 2"
                    let selection=(region.resultText.string as NSString).range(of: "Inserted ...... 3"); region.resultText.setSelectedRange(selection); region.importResult(); advance()
                case 6:
                    guard let sheet=reader.editor,sheet.regionOCR == nil else { regionTick(); return }
                    guard sheet.textView.string=="Inserted\t3\nExisting\t1\nTail\t2" else { throw ReaderFailure("Cursor insert overwrote existing text: "+sheet.textView.string) }
                    sheet.window.makeFirstResponder(sheet.textView); undoEdit()
                    guard sheet.textView.string=="Existing\t1\nTail\t2" else { throw ReaderFailure("Undo imported text") }
                    redoEdit(); smokeChecks.append("选中部分识别结果插入光标处，保留旧目录并可撤销重做")
                    sheet.openRegionOCR(); advance()
                case 7:
                    guard let sheet=reader.editor,let region=sheet.regionOCR,!region.loading else { regionTick(); return }
                    let text=sheet.textView.string; try selectRegion(region,CGRect(x: 0.025,y: 0.12,width: 0.48,height: 0.35)); region.close()
                    guard sheet.textView.string==text,try Data(contentsOf: reader.book!.url)==editedBytes else { throw ReaderFailure("Cancel OCR changed draft/file") }
                    smokeChecks.append("识别中取消不添加内容、不改写图书")
                    sheet.textView.string=regionText; sheet.saveDraft(); advance()
                default:
                    guard reader.editor == nil,reader.hasRenderedImage else { regionTick(); return }
                    guard reader.book?.chapters.count==4,reader.book?.chapters.map({$0.pageIndex+1})==[1,2,3,2],reader.book?.metadata["自定义"]=="原字段保留" else { throw ReaderFailure("Region draft saved roundtrip") }
                    smokeChecks.append("保存框选目录后重读，页码与原有BookInfo字段保留")
                    try JSONSerialization.data(withJSONObject: ["passed":true,"checks":smokeChecks,"text":regionText,"version":"0.15.1"],options: [.prettyPrinted,.sortedKeys]).write(to: output.deletingPathExtension().appendingPathExtension("json"))
                    print("REGION_UI_OK"); exit(0)
                }
            } catch { failSmoke(error.localizedDescription); return }
            regionTick()
        }
    }
    private func metadataTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard let reader = smokePrimary, let output = smokeOutput else { failSmoke("metadata fixture"); return }
            if Date() > smokeDeadline { failSmoke("metadata OCR timeout"); return }
            do {
                switch smokeStage {
                case 0:
                    guard reader.hasRenderedImage, let book = reader.book else { metadataTick(); return }
                    metadataSourceBytes = try Data(contentsOf: book.url); reader.editInfo(); smokeDeadline = Date().addingTimeInterval(60); smokeStage = 1
                default:
                    guard let sheet = reader.renameSheet, !sheet.recognitionRunning, !sheet.recognitionText.string.isEmpty else { metadataTick(); return }
                    guard sheet.metadataSnapshot["ISBN"] == "9787214312990", sheet.metadataSnapshot["作者"] == "乔玉钰著", sheet.metadataSnapshot["书名"] == "东亚女性汉文学的位相", sheet.metadataSnapshot["出版日期"] == "2026.03" else { throw ReaderFailure("Real copyright metadata fill") }
                    guard sheet.nameField.stringValue.hasPrefix("【东亚古代汉文学史研究丛书】"),sheet.extractionText.string.contains("ISBN：9787214312990"), sheet.extractionText.enclosingScrollView!.frame.height > 250 else { throw ReaderFailure("Structured extraction pane") }
                    sheet.enlargeRecognition(); guard let review=sheet.reviewWindow,review.window.contentView!.bounds.height>=600 else { throw ReaderFailure("Copyright enlarge window") }
                    try checkMovableDialog(review.window,parent:sheet.window)
                    try captureView(review.window.contentView!,to: output.deletingPathExtension().appendingPathExtension("review.png")); review.window.close()
                    try captureView(sheet.window.contentView!, to: output); let filled = sheet.metadataSnapshot; sheet.close()
                    guard try Data(contentsOf: reader.book!.url) == metadataSourceBytes else { throw ReaderFailure("OCR changed file before save") }
                    try JSONSerialization.data(withJSONObject: ["passed": true, "metadata": filled, "originalUnchanged": true], options: [.prettyPrinted,.sortedKeys]).write(to: output.deletingPathExtension().appendingPathExtension("json"))
                    print("METADATA_UI_OK"); exit(0)
                }
            } catch { failSmoke(error.localizedDescription); return }
            metadataTick()
        }
    }
    private func captureView(_ view: NSView, to output: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReaderFailure("Cannot capture editor") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let source = rep.cgImage, let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: rep.pixelsWide * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReaderFailure("Cannot compose editor") }
        let rect = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor); ctx.fill(rect); ctx.draw(source, in: rect)
        guard let cg = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw ReaderFailure("Cannot export editor") }
        try png.write(to: output)
    }
    private func smokeTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard let reader = smokePrimary, let url = initialURL, let output = smokeOutput else { self.failSmoke("missing test input"); return }
            if Date() > smokeDeadline { failSmoke("stage \(smokeStage): \(reader.diagnosticStatus)"); return }
            switch smokeStage {
            case 0:
                guard reader.hasRenderedImage, let book = reader.book else { smokeTick(); return }
                if book.chapters.isEmpty {
                    guard reader.sidebarTitles.allSatisfy({ ["封面", "书名", "版权", "前言", "目录"].contains($0) }) else { failSmoke("fallback directory contains body pages"); return }
                }
                reader.includePageNumbers = false
                smokeChecks.append("无有效目录时仅显示五类基础信息")
                reader.setTestOptions(doublePages: true); reader.jump(min(14, book.pages.count - 2))
                advance()
            case 1:
                let p = reader.state.page
                guard reader.renderedPageIndices.contains(p), reader.renderedPageIndices.contains(p + 1) else { smokeTick(); return }
                guard reader.currentFrames[p]!.minX < reader.currentFrames[p + 1]!.minX else { failSmoke("left-to-right spread"); return }
                smokeChecks.append("双页显示与从左至右布局")
                reader.setTestOptions(doublePages: true, rtl: true); advance()
            case 2:
                let p = reader.state.page
                guard reader.hasRenderedImage else { smokeTick(); return }
                guard reader.currentFrames[p]!.minX > reader.currentFrames[p + 1]!.minX else { failSmoke("right-to-left spread"); return }
                smokeChecks.append("从右至左双页布局")
                reader.setTestOptions(continuous: true); reader.jump(min(100, reader.book!.pages.count - 1), fraction: 0.2); advance()
            case 3:
                guard reader.renderedPageIndices.contains(reader.state.page) else { smokeTick(); return }
                guard reader.currentFrames.count == reader.book!.pages.count, reader.document.bounds.height > reader.scroll.contentSize.height else { failSmoke("continuous geometry"); return }
                smokeChecks.append("连续滚动、按视口加载与页码定位")
                reader.togglePageNumbers(); guard reader.sidebarTitles.contains("页码") else { failSmoke("page numbers option"); return }; reader.togglePageNumbers()
                smokeChecks.append("页码目录可勾选显示，默认关闭")
                reader.setTestOptions(color: 2, rotation: 1, crop: 0.05); advance()
            case 4:
                guard reader.hasRenderedImage else { smokeTick(); return }
                smokeChecks.append("页面反色、旋转和裁边渲染")
                reader.setTestOptions(); reader.jump(min(14, reader.book!.pages.count - 1)); advance()
            case 5:
                guard reader.renderedPageIndices.contains(reader.state.page) else { smokeTick(); return }
                guard reader.checkReadingInputs() else { failSmoke("keyboard or edge-scroll page navigation"); return }
                smokeChecks.append("方向键翻页与单页滚到边缘后翻页")
                if ImageAnalyzer.isSupported { reader.recognizeVisible(); advance() }
                else { smokeOCR = "device-unsupported"; advance(to: 7) }
            case 6:
                if !reader.recognizedText.isEmpty {
                    guard reader.checkTextSelection() else { failSmoke("recognized text selection overlay"); return }
                    smokeOCR = "text-recognized-and-selectable"; smokeChecks.append("真实扫描页文字识别与文字选取"); advance(to: 7)
                }
                else if Date() > smokeDeadline.addingTimeInterval(-8) { smokeOCR = "no-text-or-model-unavailable"; advance(to: 7) }
            case 7:
                openURL(url, forceNew: true); smokeSecond = readers.last; advance()
            case 8:
                guard let second = smokeSecond, second.hasRenderedImage else { smokeTick(); return }
                guard readers.count == 2, second !== reader, reader.book != nil, second.state.page == 0 else { failSmoke("independent book windows"); return }
                smokeChecks.append("多书独立窗口与独立阅读位置")
                reader.closeBook()
                guard reader.book == nil, reader.window.isVisible, second.book != nil else { failSmoke("close book without closing app"); return }
                smokeChecks.append("关闭当前书籍后保留窗口和 App")
                reader.window.performClose(nil); second.window.performClose(nil); advance()
            case 9:
                guard readers.isEmpty else { failSmoke("closed windows were retained"); return }
                smokeChecks.append("关闭全部窗口后 App 保持运行")
                let fresh = createWindow(); smokePrimary = fresh; fresh.open(url); advance()
            case 10:
                guard reader.hasRenderedImage else { smokeTick(); return }
                reader.setTestOptions(); reader.jump(min(14, reader.book!.pages.count - 1)); advance()
            case 11:
                guard reader.renderedPageIndices.contains(reader.state.page) else { smokeTick(); return }
                do {
                    try capture(reader, to: output)
                    reader.window.setContentSize(CGSize(width: 760, height: 620)); advance()
                } catch { failSmoke(String(describing: error)); return }
            default:
                reader.window.contentView?.layoutSubtreeIfNeeded()
                do {
                    let narrow = output.deletingPathExtension().appendingPathExtension("narrow.png")
                    try capture(reader, to: narrow)
                    let report: [String: Any] = ["passed": true, "checks": smokeChecks, "ocr": smokeOCR, "version": "0.15.1"]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.deletingPathExtension().appendingPathExtension("json"))
                    print("UI_LIFECYCLE_OK UI_RENDER_OK OCR=\(smokeOCR)"); exit(0)
                } catch { failSmoke(String(describing: error)); return }
            }
            smokeTick()
        }
    }
    private func advance(to stage: Int? = nil) { smokeStage = stage ?? smokeStage + 1; smokeDeadline = Date().addingTimeInterval(smokeStage == 6 ? 35 : 40) }
    private func failSmoke(_ message: String) { fputs("UI_TEST_FAILED \(message)\n", stderr); exit(1) }
    private func capture(_ reader: ReaderController, to output: URL) throws {
        guard let view = reader.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReaderFailure("截图失败。") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let source = rep.cgImage, let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: rep.pixelsWide * 4,
                                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReaderFailure("截图失败。") }
        let rect = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor); ctx.fill(rect); ctx.draw(source, in: rect)
        guard let cg = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw ReaderFailure("截图失败。") }
        try png.write(to: output)
    }
}
