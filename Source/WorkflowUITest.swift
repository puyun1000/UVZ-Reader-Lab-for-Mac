import AppKit

/// Runs only against generated, disposable fixtures supplied by Tests/test_workflow_ui.py.
final class WorkflowUITest:NSObject,NSApplicationDelegate {
    let folder:URL,output:URL
    var reader:ReaderController!,editor:BookEditor?,batch:BatchNamingWindow?
    var stage=0,checks:[String]=[],deadline=Date().addingTimeInterval(45)
    let defaults=UserDefaults.standard
    var savedSidebar:Any?
    var pdfOutlineSaved = false
    init(folder:URL,output:URL){self.folder=folder;self.output=output;super.init();savedSidebar=defaults.object(forKey:"reading.sidebarWidth")}
    func applicationDidFinishLaunching(_ notification:Notification) {
        guard folder.lastPathComponent.hasPrefix("uvz-workflow017-") else {finish("需要临时测试书籍目录。");return}
        defaults.set(260.0, forKey: "reading.sidebarWidth")
        reader=ReaderController();reader.smokeMode=true;reader.includePageNumbers=false
        do {let book=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).first {$0.pathExtension=="uvz"}!;reader.open(book)}catch {finish(error.localizedDescription);return}
        tick()
    }
    func check(_ value:Bool,_ message:String)throws{if !value{throw ReaderFailure(message)};checks.append(message)}
    func finish(_ error:String? = nil){
        if let savedSidebar {defaults.set(savedSidebar,forKey:"reading.sidebarWidth")}else{defaults.removeObject(forKey:"reading.sidebarWidth")}
        do {try JSONSerialization.data(withJSONObject:["passed":error == nil,"checks":checks,"error":error ?? ""],options:.prettyPrinted).write(to:output)}catch{}
        if let error {fputs("WORKFLOW_UI_FAILED: \(error) stage=\(stage)\n",stderr)}
        exit(error == nil ? 0:1)
    }
    func tick(){DispatchQueue.main.asyncAfter(deadline:.now()+0.15){[self] in
        do {
            if Date()>deadline {throw ReaderFailure("测试超时。")}
            switch stage {
            case 0:
                guard reader.hasRenderedImage,let book=reader.book else {tick();return}
                reader.window.contentView?.layoutSubtreeIfNeeded();let original=reader.scroll.frame.width
                reader.readingSplit.setPosition(430,ofDividerAt:0);reader.window.contentView?.layoutSubtreeIfNeeded()
                try check(abs(reader.readingSplit.arrangedSubviews[0].frame.width-430)<3,"目录分隔线改变实际显示宽度")
                try check(reader.scroll.frame.width<original,"加宽目录后阅读区同步缩小")
                reader.toggleSidebar();try check(reader.readingSplit.arrangedSubviews[0].isHidden,"可以隐藏目录栏")
                reader.toggleSidebar();reader.window.contentView?.layoutSubtreeIfNeeded()
                try check(abs(reader.readingSplit.arrangedSubviews[0].frame.width-430)<3,"重新显示目录保留调整后的宽度")
                let visible = (0..<reader.outline.numberOfRows).compactMap { reader.outline.item(atRow: $0) as? NavigationNode }
                try check(visible.map(\.title) == ["封面", "自定前言", "原目录", "封底"],
                          "阅读侧栏显示实际前言书签和独立封底，默认前言不重复")
                guard let backCover = visible.last else { throw ReaderFailure("封底入口缺失") }
                reader.outline.selectRowIndexes(IndexSet(integer: reader.outline.row(forItem: backCover)), byExtendingSelection: false)
                try check(reader.state.page == book.pages.count - 1, "点选封底跳到实际封底页")
                reader.jump(1)
                try check(reader.outline.selectedRow == -1, "阅读书签尚未覆盖的同类型起始页时不误选封面")
                reader.jump(0)
                let controller=BookEditor(book:book);editor=controller;controller.show(on:reader.window)
                controller.textView.string=String(repeating:"长目录文字",count:80)+"\t3\n无页码分组";controller.textView.refreshExtent();stage=1
            case 1:
                guard let editor, editor.pagePreview.canvas.hasPage else { tick(); return }
                let text = editor.textView, manager = text.layoutManager!, container = text.textContainer!
                try check(editor.window.toolbar?.items.count == 4, "目录编辑使用原生工具栏")
                try check(editor.pagePreview.frame.width >= 278, "同窗保留足够宽度的原页预览")
                try check(editor.pagePreview.page == 0, "目录预览从阅读位置打开")
                editor.window.makeFirstResponder(text)
                text.setSelectedRange(NSRange(location: 2, length: 0))
                let previewTarget = reader.book?.pages.firstIndex { $0.key.group == 5 && $0.number == 3 }
                try check(previewTarget != nil && editor.pagePreview.page == previewTarget, "文本光标所在条目联动目标物理页")
                editor.showStructureTab()
                editor.contentsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                try check(editor.pagePreview.page == previewTarget, "树形模式选中条目保留同页预览")
                editor.togglePagePreview()
                try check(editor.pagePreview.isHidden, "可折叠预览并为目录释放空间")
                editor.togglePagePreview()
                try check(!editor.pagePreview.isHidden && editor.pagePreview.page == previewTarget, "重新显示预览保留目标页")
                editor.showContentsTab()
                manager.ensureLayout(for:container)
                let position=(text.string as NSString).range(of:"\t3").location+1
                let first=manager.lineFragmentRect(forGlyphAt:0,effectiveRange:nil)
                let lastGlyph=manager.glyphIndexForCharacter(at:position)
                let last=manager.lineFragmentRect(forGlyphAt:lastGlyph,effectiveRange:nil)
                try check(abs(first.minY-last.minY)<1,"长目录标题与末尾页码保持同一行")
                try check(text.frame.width>text.enclosingScrollView!.contentSize.width,"长行扩展文档宽度并可横向滚动")
                text.scrollRangeToVisible(NSRange(location:position,length:1))
                try check(text.enclosingScrollView!.contentView.bounds.minX>0,"可横向滚动到末尾页码")
                text.string="甲 甲 甲";text.setSelectedRange(NSRange(location:0,length:0))
                let find=ContentsFindWindow(text:text);find.find.stringValue="甲";find.replacement.stringValue="乙";find.nextMatch();find.replaceAll()
                try check(text.string=="乙 乙 乙","查找选中一处后，全部替换仍修改全文三处")
                text.string="甲 甲 甲";text.setSelectedRange(NSRange(location:0,length:1));find.show(on:editor.window);find.selectionOnly.state = .on;find.replaceAll()
                try check(text.string=="乙 甲 甲","明确选择仅选区时，范围不扩展")
                find.window.close()
                let cg=try reader.book!.pageImage(at:0),imageWindow=PageImageWindow(image:cg,title:"测试页面")
                imageWindow.show();imageWindow.larger();imageWindow.fit()
                try check(imageWindow.canvas.imageRect.width>0,"单页图像窗口能显示、缩放并恢复整页")
                imageWindow.window.close()
                editor.window.close();self.editor=nil
                batch=BatchNamingWindow();batch!.useOCR.state = .off;batch!.loadFolder(folder);stage=2
            case 2:
                guard let batch,!batch.isAnalysing,!batch.items.isEmpty,batch.items.allSatisfy({$0.proposal != nil}) else {tick();return}
                let item=batch.items[0];item.proposal!.metadata["书名"]="批量核对后书名";item.proposal!.metadata["作者"]="修订作者";item.proposal!.metadata["出版日期"]="2024.08";item.proposal!.metadata["自定义"]="核对值保留"
                item.customName="批量保存与改名";item.included=true;item.reviewed=true
                batch.preserveDates.state = .on;batch.applySelected();stage=3
            case 3:
                guard let batch,!batch.isApplying,let item=batch.items.first else {tick();return}
                try check(item.outcome == "已完成","批量界面完成保存与重命名")
                let reopened=try BookArchive(url:item.url)
                try check(item.url.deletingPathExtension().lastPathComponent=="批量保存与改名","批量界面写回规范名称")
                try check(reopened.metadata == item.proposal!.metadata,"批量界面将全部核对信息写回书籍")
                try check(reopened.chapters.map(\.title)==["自定前言","原目录"],"批量信息修改保留原目录")
                batch.window.close()
                let pdf = try BookArchive(url: folder.appendingPathComponent("pdf/same-page.pdf"))
                let controller = BookEditor(book: pdf)
                editor = controller; controller.show(on: reader.window)
                let find = ContentsFindWindow(text: controller.textView)
                find.find.stringValue = "Original "; find.replacement.stringValue = "Edited "; find.replaceAll()
                try check(controller.textView.string.contains("Edited first") && controller.textView.string.contains("Edited second"),
                          "全部替换修改指向同一 PDF 物理页的两个标题")
                controller.showStructureTab()
                try check(!controller.isTextMode && controller.draft.chapters.map(\.pdfOutlineIndex) == [0, 1],
                          "两条标题一起修改后可切换树形，仍对应各自原书签")
                controller.showContentsTab()
                controller.onSaved = { [weak self] _ in self?.pdfOutlineSaved = true }
                controller.saveDraft()
                stage = 4
            case 4:
                guard pdfOutlineSaved else {tick();return}
                let url = folder.appendingPathComponent("pdf/same-page.pdf")
                let pdf = try BookArchive(url: url)
                try check(pdf.chapters.map(\.title) == ["Edited first", "Edited second"],
                          "从文本模式保存后，两条改名均写入 PDF")
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("pdf/text-saved.pdf"))
                let controller = BookEditor(book: pdf)
                editor = controller; controller.show(on: reader.window); controller.showStructureTab()
                controller.contentsTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                controller.removeChapter()
                controller.contentsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                controller.addChapter()
                pdfOutlineSaved = false
                controller.onSaved = { [weak self] _ in self?.pdfOutlineSaved = true }
                controller.saveDraft()
                stage = 5
            case 5:
                guard pdfOutlineSaved else {tick();return}
                let pdf = try BookArchive(url: folder.appendingPathComponent("pdf/same-page.pdf"))
                try check(pdf.chapters.map(\.title) == ["Edited first","新目录"],
                          "树形模式可删除并在同页新建书签")
                let book = try BookArchive(url: folder.appendingPathComponent("pdf/parent-child.pdf"))
                let controller = BookEditor(book: book)
                editor = controller; controller.show(on: reader.window)
                controller.textView.string = "新父项\t1\n\t新子项\t1"
                pdfOutlineSaved = false
                controller.onSaved = { [weak self] _ in self?.pdfOutlineSaved = true }
                controller.saveDraft()
                stage = 6
            default:
                guard pdfOutlineSaved else {tick();return}
                let book = try BookArchive(url: folder.appendingPathComponent("pdf/parent-child.pdf"))
                try check(book.chapters.map(\.title) == ["新父项","新子项"] &&
                          book.chapters.map(\.level) == [0,1] && book.chapters.map(\.pageIndex) == [0,0],
                          "文本模式将一个旧书签换为同页父子项，可直接保存且层级不变")
                finish();return
            }
            tick()
        }catch{finish(error.localizedDescription)}
    }}
}
