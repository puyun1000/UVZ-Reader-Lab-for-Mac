import AppKit

final class ConversionJob {
    let source: URL
    var metadata: [String:String] = [:]
    var pages = 0,chapterCount = 0,stem = "",manualName = false
    var state = "检查来源",phase = "",completed = 0
    var error: String?,result: ConversionResult?
    init(_ source: URL) {self.source=source}
    var ready: Bool { pages>0 && result == nil && error == nil }
}
final class ConversionWindow: NSObject,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
    let window = ConversionHostWindow(contentRect:NSRect(x:0,y:0,width:960,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    let table = NSTableView(),nameField = CenteredTextField(),sourceLabel = CenteredTextField(wrappingLabelWithString:"选择任务查看完整来源与目标名称")
    let targetLabel = CenteredTextField(wrappingLabelWithString:""),summary = CenteredTextField(labelWithString:"添加图书，转换为 PDF")
    let pageProgress = NSProgressIndicator(),totalProgress = NSProgressIndicator()
    let startButton = NSButton(title:"开始转换",target:nil,action:nil),stopButton = NSButton(title:"停止",target:nil,action:nil)
    let naming = NSPopUpButton(),style = NSPopUpButton(),outputChoice = NSPopUpButton()
    let bookmarks = NSButton(checkboxWithTitle:"写入 PDF 书签",target:nil,action:nil),metadata = NSButton(checkboxWithTitle:"内嵌图书信息",target:nil,action:nil),skipBad = NSButton(checkboxWithTitle:"跳过坏页（生成部分 PDF）",target:nil,action:nil)
    let folderLabel = CenteredTextField(wrappingLabelWithString:"与来源图书位于同一文件夹")
    let dpi = CenteredTextField(string:"300"),logView = ChineseTextView(),logScroll = NSScrollView()
    private let integrity=CenteredTextField(wrappingLabelWithString:"选择图书后显示页数与目录信息"),queueHeading=CenteredTextField(labelWithString:"尚未添加图书")
    private let form=ConversionFormScroll(),queueColumn=NSStackView(),settingsColumn=NSStackView()
    private let queue = OperationQueue(),logToggle = NSButton(checkboxWithTitle:"显示任务日志",target:nil,action:nil)
    private let lock = NSLock()
    private var shouldStop = false,closed = false,closeWhenStopped = false
    private var outputFolder: URL?,completedJobs = 0
    private(set) var jobs: [ConversionJob] = []
    private(set) var isRunning = false
    private var importing = 0,reloading = false
    var onOpen: ((URL)->Void)?,onClosed: (()->Void)?
    private var selected: ConversionJob? {jobs.indices.contains(table.selectedRow) ? jobs[table.selectedRow] : nil}
    var options: ConversionOptions {
        var o = ConversionOptions();o.naming = ["source","template","title"][max(0,naming.indexOfSelectedItem)];o.style = NamingPreferences.styles()[max(0,min(style.indexOfSelectedItem,NamingPreferences.styles().count-1))].id
        o.writeBookmarks = bookmarks.state == .on;o.writeMetadata = metadata.state == .on;o.skipBadPages = skipBad.state == .on;o.outputDirectory = outputChoice.indexOfSelectedItem == 1 ? outputFolder?.path : nil;o.fallbackDPI = Double(dpi.stringValue) ?? 0
        return o
    }
    override init() {
        super.init();queue.maxConcurrentOperationCount=1;queue.qualityOfService = .userInitiated
        window.title="UVZ Reader Lab · 转换";window.identifier = .init("UVZConversion");window.minSize=NSSize(width:760,height:640);window.delegate=self;window.isReleasedWhenClosed=false
        window.onPasteFiles={[weak self] in self?.pasteFiles()}
        let root=DropRootView(frame:.zero);root.onFiles={[weak self] in self?.add($0)};window.contentView=root
        let title=CenteredTextField(labelWithString:"转换工作台");title.font = .systemFont(ofSize:22,weight:.semibold)
        queueHeading.font = .systemFont(ofSize:12);queueHeading.textColor = .secondaryLabelColor
        let heading=NSStackView(views:[title,queueHeading]);heading.orientation = .vertical;heading.alignment = .leading;heading.spacing=3
        let addFile=button("添加文件",#selector(chooseFiles)),addFolder=button("添加文件夹",#selector(chooseFolders));addFile.image=NSImage(systemSymbolName:"doc.badge.plus",accessibilityDescription:nil);addFile.imagePosition = .imageLeading;addFolder.image=NSImage(systemSymbolName:"folder.badge.plus",accessibilityDescription:nil);addFolder.imagePosition = .imageLeading
        let header=NSStackView(views:[heading,NSView(),addFile,addFolder]);header.spacing=10;header.heightAnchor.constraint(equalToConstant:50).isActive=true
        for (id,title,width) in [("source","书籍 / 来源",570.0),("pages","页数",65.0),("state","状态",105.0)] {let column=NSTableColumn(identifier:.init(id));column.title=title;column.width=width;column.minWidth=id == "source" ? 300 : 55;table.addTableColumn(column)}
        table.delegate=self;table.dataSource=self;table.rowHeight=72;table.usesAlternatingRowBackgroundColors=false;table.allowsMultipleSelection=true;table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle;table.setAccessibilityLabel("转换任务队列")
        let list=NSScrollView();list.documentView=table;list.hasVerticalScroller=true;list.borderType = .noBorder;list.heightAnchor.constraint(equalToConstant:168).isActive=true
        integrity.font = .systemFont(ofSize:12);integrity.textColor = .secondaryLabelColor
        let actions=NSStackView(views:[button("打开结果",#selector(openResult)),button("在访达显示",#selector(revealResult)),NSView(),button("移除所选",#selector(removeSelected)),button("清除已完成",#selector(clearCompleted))]);actions.spacing=8;actions.heightAnchor.constraint(equalToConstant:28).isActive=true
        queueColumn.orientation = .vertical;queueColumn.alignment = .leading;queueColumn.spacing=12
        let drop=ConversionDropHint();drop.heightAnchor.constraint(equalToConstant:46).isActive=true
        for view in [drop,list,integrity,actions] {queueColumn.addArrangedSubview(view);view.widthAnchor.constraint(equalTo:queueColumn.widthAnchor).isActive=true}
        buildOutputSettings()
        for column in [queueColumn,settingsColumn] {let card=ConversionCard(column);form.column.addArrangedSubview(card);card.widthAnchor.constraint(equalTo:form.column.widthAnchor).isActive=true}
        logView.isEditable=false;logView.isRichText=false;logView.font = .monospacedSystemFont(ofSize:11,weight:.regular);logView.isVerticallyResizable=true;logView.autoresizingMask=[.width];logView.textContainer?.widthTracksTextView=true
        logScroll.documentView=logView;logScroll.hasVerticalScroller=true;logScroll.isHidden=true;logScroll.heightAnchor.constraint(equalToConstant:100).isActive=true
        logToggle.title="运行详情";logToggle.target=self;logToggle.action = #selector(toggleLog)
        startButton.target=self;startButton.action = #selector(start);startButton.bezelStyle = .rounded;startButton.bezelColor = .controlAccentColor;startButton.keyEquivalent="\r"
        stopButton.target=self;stopButton.action = #selector(stop);stopButton.bezelStyle = .rounded
        summary.font = .systemFont(ofSize:12);summary.lineBreakMode = .byTruncatingMiddle
        for progress in [pageProgress,totalProgress] {progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=1;progress.style = .bar;progress.controlSize = .small;progress.heightAnchor.constraint(equalToConstant:7).isActive=true}
        let footer=NSStackView(views:[logToggle,button("导出记录…",#selector(exportLog)),NSView(),stopButton,startButton]);footer.spacing=10;footer.heightAnchor.constraint(equalToConstant:32).isActive=true
        let stack=NSStackView(views:[header,form,summary,pageProgress,totalProgress,logScroll,footer]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(stack)
        for view in stack.arrangedSubviews {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        form.setContentHuggingPriority(.init(1),for:.vertical)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:16),stack.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-16)])
        updateControls();window.center()
    }
    private func button(_ text:String,_ action:Selector)->NSButton {let button=NSButton(title:text,target:self,action:action);button.bezelStyle = .rounded;return button}
    private func buildOutputSettings() {
        let title=CenteredTextField(labelWithString:"输出设置");title.font = .systemFont(ofSize:16,weight:.semibold)
        outputChoice.addItems(withTitles:["与原文件同级","自选文件夹"]);outputChoice.target=self;outputChoice.action = #selector(optionsChanged)
        naming.addItems(withTitles:["保留源文件名","按规范模板","仅用书名"]);naming.target=self;naming.action = #selector(optionsChanged);naming.selectItem(at:["source","template","title"].firstIndex(of:UserDefaults.standard.string(forKey:"conversion.naming") ?? "source") ?? 0)
        style.addItems(withTitles:NamingPreferences.styles().map(\.title));style.selectItem(at:NamingPreferences.styles().firstIndex(where:{$0.id == UserDefaults.standard.string(forKey:"conversion.style")}) ?? 0);style.target=self;style.action = #selector(optionsChanged)
        bookmarks.state = .on;metadata.state = .on;skipBad.state = .off
        for control in [bookmarks,metadata,skipBad] {control.target=self;control.action = #selector(optionsChanged)}
        dpi.delegate=self;dpi.widthAnchor.constraint(equalToConstant:66).isActive=true
        folderLabel.font = .systemFont(ofSize:11);folderLabel.textColor = .secondaryLabelColor
        sourceLabel.font = .systemFont(ofSize:11);sourceLabel.textColor = .secondaryLabelColor;sourceLabel.isSelectable=true;sourceLabel.maximumNumberOfLines=2
        targetLabel.font = .systemFont(ofSize:11);targetLabel.textColor = .secondaryLabelColor;targetLabel.isSelectable=true;targetLabel.maximumNumberOfLines=2
        nameField.maximumNumberOfLines=3;nameField.delegate=self;nameField.setAccessibilityLabel("目标文件名，不含扩展名");nameField.cell?.usesSingleLineMode=false;nameField.cell?.isScrollable=false;nameField.cell?.wraps=true;nameField.lineBreakMode = .byWordWrapping;nameField.font = .systemFont(ofSize:13);nameField.heightAnchor.constraint(equalToConstant:56).isActive=true
        func row(_ label:String,_ views:[NSView])->NSStackView {let heading=CenteredTextField(labelWithString:label);heading.widthAnchor.constraint(equalToConstant:70).isActive=true;let row=NSStackView(views:[heading]+views);row.spacing=10;row.heightAnchor.constraint(equalToConstant:28).isActive=true;return row}
        let destination=row("保存到",[outputChoice,button("选择文件夹…",#selector(chooseOutput))])
        let format=row("文件命名",[naming,style]);let nameRow=NSStackView(views:[nameField,CenteredTextField(labelWithString:".pdf"),button("重新生成",#selector(regenerate))]);nameRow.alignment = .centerY;nameRow.spacing=8
        let flags=NSStackView(views:[bookmarks,metadata,NSView()]);flags.spacing=20;flags.heightAnchor.constraint(equalToConstant:25).isActive=true
        let bottom=NSStackView(views:[skipBad,NSView(),CenteredTextField(labelWithString:"缺少纸张信息时使用 DPI"),dpi]);bottom.spacing=10;bottom.heightAnchor.constraint(equalToConstant:27).isActive=true
        let note=CenteredTextField(wrappingLabelWithString:"保留原图尺寸；目标已存在时不会覆盖。遇到坏页默认停止，勾选继续后生成标有 .partial 的部分结果。")
        note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor
        settingsColumn.orientation = .vertical;settingsColumn.alignment = .leading;settingsColumn.spacing=12
        for view in [title,destination,folderLabel,format,CenteredTextField(labelWithString:"目标文件名"),nameRow,targetLabel,NSBox.separator(),flags,bottom,note] {settingsColumn.addArrangedSubview(view);view.widthAnchor.constraint(equalTo:settingsColumn.widthAnchor).isActive=true}
    }
    var usesVerticalLayout:Bool {true}
    var outputSettingsFrame:NSRect {settingsColumn.convert(settingsColumn.bounds,to:form.column)}
    var queueFrame:NSRect {queueColumn.convert(queueColumn.bounds,to:form.column)}
    func show() {window.makeKeyAndOrderFront(nil);refreshDetails()}
    @objc func chooseFiles() {let p=NSOpenPanel();p.allowsMultipleSelection=true;p.canChooseDirectories=false;p.title="添加待转换图书";p.begin {[weak self] in if $0 == .OK {self?.add(p.urls)}}}
    @objc func chooseFolders() {let p=NSOpenPanel();p.allowsMultipleSelection=true;p.canChooseDirectories=true;p.canChooseFiles=false;p.title="选择PDG图书或包含图书的文件夹";p.begin {[weak self] in if $0 == .OK {self?.add(p.urls)}}}
    @objc func pasteFiles() {
        let urls=(NSPasteboard.general.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        if !urls.isEmpty {add(urls);return}
        if let text=NSPasteboard.general.string(forType:.string) {add(text.components(separatedBy:.newlines).map {$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {!$0.isEmpty}.map {URL(fileURLWithPath:$0)})}
    }
    @objc func chooseOutput() {guard !isRunning else{return};let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;p.title="选择PDF输出文件夹";p.begin {[weak self] response in guard let self,response == .OK,let url=p.url else{return};self.outputFolder=url;self.outputChoice.selectItem(at:1);self.optionsChanged()}}
    @objc func optionsChanged() {
        folderLabel.stringValue=outputChoice.indexOfSelectedItem == 1 ? outputFolder?.path ?? "请先选择输出文件夹" : "与来源图书位于同一文件夹"
        for job in jobs where job.result == nil && job.pages>0 && !job.manualName {job.stem=(try? ExportNaming.stem(job.source,metadata:job.metadata,options:options)) ?? ""}
        for job in jobs where job.result == nil && job.pages>0 {validate(job)}
        UserDefaults.standard.set(options.naming,forKey:"conversion.naming");UserDefaults.standard.set(options.style,forKey:"conversion.style");refreshDetails();reloadQueue();updateControls()
    }
    private func validate(_ job:ConversionJob) {
        do {
            if outputChoice.indexOfSelectedItem == 1,outputFolder == nil {throw ReaderFailure("请先选择输出文件夹。")}
            _ = try ConversionService.preflight(job.source,stem:job.stem,options:options)
            let dest = try ExportNaming.destination(job.source,stem:job.stem,options:options)
            if jobs.contains(where:{$0 !== job && $0.result == nil && (try? ExportNaming.destination($0.source,stem:$0.stem,options:options)).map {BatchNaming.pathKey($0) == BatchNaming.pathKey(dest)} == true}) {throw ReaderFailure("队列内目标名称重复。")}
            job.error=nil;job.state="就绪"
        } catch {job.error=error.localizedDescription;job.state="待处理"}
    }
    func add(_ urls:[URL]) {
        guard !isRunning else{summary.stringValue="请先停止转换再添加图书。";return}
        importing += 1;updateControls()
        queue.addOperation {[weak self] in
            var found:[URL]=[],issues:[String]=[]
            for url in urls {
                do {
                    let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard values.isSymbolicLink != true else{throw ReaderFailure("跳过符号链接。")}
                    if values.isDirectory == true {
                        if try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil).contains(where:{$0.pathExtension.lowercased() == "pdg"}) {found.append(url)}
                        else {found += try BatchNaming.discover(url,recursive:true)}
                    } else if supportedBookExtensions.contains(url.pathExtension.lowercased()) {found.append(url)}
                    else {issues.append(url.lastPathComponent+"：本版转换尚不支持该格式。")}
                } catch {issues.append(url.lastPathComponent+"："+error.localizedDescription)}
            }
            let loaded=found.map {url in (url,Result {try autoreleasepool { let book=try BookArchive(url:url);return (FilenameDraft(book:book).values,book.title,book.pages.count,book.contentsNotice,book.chapters.count) }})}
            DispatchQueue.main.async {guard let self,!self.closed else{return};self.importing -= 1
                for (url,result) in loaded {
                    if self.jobs.contains(where:{BatchNaming.pathKey($0.source) == BatchNaming.pathKey(url)}) {self.log("重复来源已跳过："+url.lastPathComponent);continue}
                    let job=ConversionJob(url);self.jobs.append(job)
                    switch result {case .success(let book):job.metadata=BookMetadata.canonical(book.0);if job.metadata["书名",default:""].isEmpty {job.metadata["书名"]=book.1};job.pages=book.2;job.chapterCount=book.4;job.stem=(try? ExportNaming.stem(url,metadata:job.metadata,options:self.options)) ?? "";if let note=book.3 {self.log(note)}
                    case .failure(let e):job.state="来源失败";job.error=e.localizedDescription;job.stem=url.deletingPathExtension().lastPathComponent}
                }
                for job in self.jobs where job.pages>0 && job.result == nil {self.validate(job)}
                issues.forEach {self.log($0)};self.reloadQueue();if self.table.selectedRow<0,!self.jobs.isEmpty {self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)}
                self.summary.stringValue="\(self.jobs.count) 个任务 · \(self.jobs.filter(\.ready).count) 个可转换";self.refreshDetails();self.updateControls()
            }
        }
    }
    func numberOfRows(in tableView:NSTableView)->Int {jobs.count}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
        let job=jobs[row],label=CenteredTextField(labelWithString:"");label.font = .systemFont(ofSize:12);label.lineBreakMode = .byTruncatingMiddle
        if column?.identifier.rawValue == "source" {
            let title=CenteredTextField(labelWithString:job.metadata["书名"] ?? job.source.deletingPathExtension().lastPathComponent);title.font = .systemFont(ofSize:13,weight:.medium);title.lineBreakMode = .byTruncatingMiddle
            let info=[job.metadata["丛书名"],job.metadata["出版社"],job.metadata["出版日期"]].compactMap {$0}.filter {!$0.isEmpty}.joined(separator:" · ")
            let subtitle=CenteredTextField(labelWithString:info);subtitle.font = .systemFont(ofSize:11);subtitle.textColor = .secondaryLabelColor;subtitle.lineBreakMode = .byTruncatingMiddle
            let file=CenteredTextField(labelWithString:job.source.lastPathComponent);file.font = .systemFont(ofSize:10);file.textColor = .tertiaryLabelColor;file.lineBreakMode = .byTruncatingMiddle
            let stack=NSStackView(views:[title,subtitle,file]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=3
            for view in [title,subtitle,file] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true};stack.toolTip=job.source.path;return stack
        }
        switch column?.identifier.rawValue {case "pages":label.stringValue=job.pages>0 ? String(job.pages) : "—";default:label.stringValue=job.state;if job.error != nil {label.textColor = .systemOrange};if job.result != nil {label.textColor=job.result!.partial ? .systemOrange : .systemGreen}}
        label.toolTip=job.error ?? label.stringValue;return label
    }
    private func reloadQueue() {
        let selected=IndexSet(table.selectedRowIndexes.filter {jobs.indices.contains($0)})
        reloading=true;table.reloadData();table.selectRowIndexes(selected,byExtendingSelection:false);reloading=false
    }
    func tableViewSelectionDidChange(_ notification:Notification) {if !reloading {refreshDetails()}}
    private func refreshDetails() {
        guard let job=selected else {nameField.stringValue="";nameField.isEnabled=false;sourceLabel.stringValue="选择任务查看完整来源与目标名称";targetLabel.stringValue="";return}
        integrity.stringValue="完整性预览：\(job.pages) 个物理页面"+(job.metadata["页数"].flatMap {$0.isEmpty ? nil : " · 书目页数 "+$0} ?? "")+"\n\(job.chapterCount) 条电子目录 · 转换与阅读各自保留窗口";sourceLabel.stringValue="来源："+job.source.path;sourceLabel.toolTip=job.source.path;nameField.stringValue=job.stem;nameField.isEnabled = !isRunning && job.result == nil && job.pages>0
        targetLabel.stringValue = job.error ?? job.result.map {"输出："+$0.output+"\n\($0.outputPages)/\($0.sourcePages)页 · JPEG直通\($0.jpegPassThrough)页 · "+String(format:"%.2f秒",$0.elapsedSeconds)} ?? (options.naming == "source" ? "只替换扩展名，完整保留已经整理的文件名。" : "规范名称可手动修订；重新生成后恢复自动跟随。")
    }
    func controlTextDidChange(_ notification:Notification) {
        guard !isRunning else{return}
        if notification.object as? NSTextField === nameField,let job=selected {job.stem=nameField.stringValue;job.manualName=true;for item in jobs where item.pages>0 && item.result == nil {validate(item)};reloadQueue();targetLabel.stringValue=job.error ?? "已使用手工目标名；点击重新生成可恢复自动命名。";updateControls()}
        else if notification.object as? NSTextField === dpi {optionsChanged()}
    }
    @objc func regenerate() {guard !isRunning,let job=selected,job.result == nil else{return};job.manualName=false;optionsChanged()}
    @objc func removeSelected() {guard !isRunning else{return};for index in table.selectedRowIndexes.reversed() {jobs.remove(at:index)};optionsChanged()}
    @objc func clearCompleted() {guard !isRunning else{return};jobs.removeAll {$0.result != nil};optionsChanged()}
    @objc func openResult() {if let result=selected?.result {onOpen?(URL(fileURLWithPath:result.output))}}
    @objc func revealResult() {if let result=selected?.result {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:result.output)])}}
    @objc func toggleLog() {logScroll.isHidden=logToggle.state != .on}
    private func log(_ value:String) {logView.string += value+"\n";logView.scrollRangeToVisible(NSRange(location:(logView.string as NSString).length,length:0))}
    @objc func exportLog() {let p=NSSavePanel();p.nameFieldStringValue="转换记录.txt";p.begin {[weak self] response in guard let self,response == .OK,let url=p.url else{return};do {try self.logView.string.write(to:url,atomically:true,encoding:.utf8)}catch {self.summary.stringValue=error.localizedDescription}}}
    private func updateControls() {
        startButton.isEnabled = !isRunning && importing == 0 && jobs.contains(where:\.ready);stopButton.isEnabled=isRunning
        for v in [naming,style,outputChoice,dpi,bookmarks,metadata,skipBad] as [NSControl] {v.isEnabled = !isRunning}
        style.isEnabled = !isRunning && naming.indexOfSelectedItem == 1
        queueHeading.stringValue="\(jobs.count) 本图书 · \(jobs.filter(\.ready).count) 本可转换";window.subtitle="\(jobs.count) 本图书"+(isRunning ? " · 转换中" : "")
    }
    func close() {if isRunning {closeWhenStopped=true;stop()} else {finishClose()}}
    @objc func stop() {lock.lock();shouldStop=true;lock.unlock();summary.stringValue="正在停止；当前处理结束后清理未完成输出。"}
    private func stopped()->Bool {lock.lock();defer{lock.unlock()};return shouldStop}
    @objc func start() {
        guard !isRunning,importing==0 else{return};window.makeFirstResponder(nil);optionsChanged()
        let pending=jobs.filter(\.ready);guard !pending.isEmpty else{return};let settings=options
        isRunning=true;lock.lock();shouldStop=false;lock.unlock();completedJobs=0;totalProgress.doubleValue=0;pageProgress.doubleValue=0;updateControls()
        queue.addOperation {[weak self] in
            guard let self else{return}
            for (offset,job) in pending.enumerated() {
                if self.stopped() {break}
                DispatchQueue.main.async {job.state="转换中";self.reloadQueue()}
                let result=Result {try ConversionService.convert(job.source,stem:job.stem,options:settings,cancelled:{self.stopped()},progress:{p in DispatchQueue.main.async {
                    job.completed=p.completed;job.phase=p.phase;self.pageProgress.doubleValue=p.total>0 ? Double(p.completed)/Double(p.total) : 0;self.totalProgress.doubleValue=(Double(offset)+(p.total>0 ? Double(p.completed)/Double(p.total) : 0))/Double(pending.count)
                    self.summary.stringValue="\(offset+1)/\(pending.count) · \(p.phase) · \(p.completed)/\(p.total)页";job.state=p.phase;self.reloadQueue()
                }})}
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r):job.result=r;job.state=r.partial ? "⚠ 部分完成" : "✓ 完成";self.log(job.source.lastPathComponent+" → "+r.output+"\n\(r.outputPages)/\(r.sourcePages)页，JPEG直通\(r.jpegPassThrough)页；"+String(format:"%.2f秒",r.elapsedSeconds));r.notes.forEach {self.log($0)}
                    case .failure(is ConversionCancelled):job.state="已取消";job.error=nil;self.log("已取消："+job.source.lastPathComponent)
                    case .failure(let e):job.state="失败";job.error=e.localizedDescription;self.log("失败："+job.source.lastPathComponent+" · "+e.localizedDescription)
                    }
                    self.completedJobs += 1;self.totalProgress.doubleValue=Double(offset+1)/Double(pending.count);self.reloadQueue();self.refreshDetails()
                }
            }
            DispatchQueue.main.async {
                self.isRunning=false
                let success=pending.filter {$0.result != nil}.count,failed=pending.filter {$0.error != nil}.count
                self.summary.stringValue="\(self.stopped() ? "已停止" : "处理结束") · 完成\(success)本，失败\(failed)本";if !self.stopped() {self.totalProgress.doubleValue=1;self.pageProgress.doubleValue=1}
                self.updateControls();self.refreshDetails();if self.closeWhenStopped {self.finishClose()}
            }
        }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {if isRunning {closeWhenStopped=true;stop();return false};finishClose();return false}
    private func finishClose() {closed=true;queue.cancelAllOperations();window.orderOut(nil);onClosed?()}
}
extension NSBox {static func separator()->NSBox {let b=NSBox();b.boxType = .separator;return b}}

final class ConversionHostWindow:ChineseWindow {
    var onPasteFiles:(()->Void)?
    @objc func paste(_ sender:Any?) {onPasteFiles?()}
}
private final class ConversionFlippedView:NSView {override var isFlipped:Bool {true}}
private final class ConversionFormScroll:NSScrollView {
    let column=NSStackView()
    private let formDocument=ConversionFlippedView(frame:NSRect(x:0,y:0,width:900,height:900))
    override init(frame:NSRect) {
        super.init(frame:frame);documentView=formDocument;hasVerticalScroller=true;autohidesScrollers=true;drawsBackground=false
        column.orientation = .vertical;column.alignment = .leading;column.spacing=16;column.translatesAutoresizingMaskIntoConstraints=false;formDocument.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo:formDocument.leadingAnchor,constant:1),column.trailingAnchor.constraint(equalTo:formDocument.trailingAnchor,constant:-1),column.topAnchor.constraint(equalTo:formDocument.topAnchor,constant:2)])
    }
    convenience init() {self.init(frame:.zero)}
    required init?(coder:NSCoder) {fatalError("init(coder:)")}
    override func layout() {
        super.layout();let width=max(620,contentSize.width);formDocument.setFrameSize(NSSize(width:width,height:formDocument.frame.height));column.layoutSubtreeIfNeeded()
        let height=column.fittingSize.height+6;if abs(formDocument.frame.height-height)>1 {formDocument.setFrameSize(NSSize(width:width,height:height))}
    }
}
private final class ConversionCard:NSView {
    init(_ column:NSStackView) {super.init(frame:.zero);column.translatesAutoresizingMaskIntoConstraints=false;addSubview(column);NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo:leadingAnchor,constant:18),column.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-18),column.topAnchor.constraint(equalTo:topAnchor,constant:16),column.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-16)])}
    required init?(coder:NSCoder) {fatalError("init(coder:)")}
    override func draw(_ rect:NSRect) {let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:12,yRadius:12);NSColor.controlBackgroundColor.setFill();path.fill();NSColor.separatorColor.withAlphaComponent(0.5).setStroke();path.lineWidth=0.5;path.stroke()}
}
private final class ConversionDropHint:NSView {
    override func draw(_ rect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:8,yRadius:8);path.setLineDash([5,4],count:2,phase:0);NSColor.separatorColor.setStroke();path.stroke()
        let text=NSAttributedString(string:"拖入更多图书，或按 ⌘V 添加",attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.secondaryLabelColor]);let size=text.size();text.draw(at:NSPoint(x:max(8,(bounds.width-size.width)/2),y:(bounds.height-size.height)/2))
    }
}
