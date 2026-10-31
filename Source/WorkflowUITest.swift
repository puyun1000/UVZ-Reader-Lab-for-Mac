import AppKit

/// Runs only against generated, disposable fixtures supplied by Tests/test_workflow_ui.py.
final class WorkflowUITest:NSObject,NSApplicationDelegate {
    let folder:URL,output:URL
    var reader:ReaderController!,editor:BookEditor?,batch:BatchNamingWindow?
    var stage=0,checks:[String]=[],deadline=Date().addingTimeInterval(45)
    let defaults=UserDefaults.standard
    var savedSidebar:Any?
    init(folder:URL,output:URL){self.folder=folder;self.output=output;super.init();savedSidebar=defaults.object(forKey:"reading.sidebarWidth")}
    func applicationDidFinishLaunching(_ notification:Notification) {
        guard folder.lastPathComponent.hasPrefix("uvz-workflow017-") else {finish("需要临时测试书籍目录。");return}
        reader=ReaderController();reader.smokeMode=true
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
                let controller=BookEditor(book:book);editor=controller;NativeDialog.present(controller.window,on:reader.window)
                controller.textView.string=String(repeating:"长目录文字",count:80)+"\t3\n无页码分组";controller.textView.refreshExtent();stage=1
            case 1:
                let text=editor!.textView,manager=text.layoutManager!,container=text.textContainer!
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
                text.string="甲 甲 甲";text.setSelectedRange(NSRange(location:0,length:1));find.show(on:editor!.window);find.selectionOnly.state = .on;find.replaceAll()
                try check(text.string=="乙 甲 甲","明确选择仅选区时，范围不扩展")
                find.window.close()
                let cg=try reader.book!.pageImage(at:0),imageWindow=PageImageWindow(image:cg,title:"测试页面")
                imageWindow.show();imageWindow.larger();imageWindow.fit()
                try check(imageWindow.canvas.imageRect.width>0,"单页图像窗口能显示、缩放并恢复整页")
                imageWindow.window.close()
                editor!.window.close();editor=nil
                batch=BatchNamingWindow();batch!.useOCR.state = .off;batch!.loadFolder(folder);stage=2
            case 2:
                guard let batch,!batch.isAnalysing,!batch.items.isEmpty,batch.items.allSatisfy({$0.proposal != nil}) else {tick();return}
                let item=batch.items[0];item.proposal!.metadata["书名"]="批量核对后书名";item.proposal!.metadata["作者"]="修订作者";item.proposal!.metadata["出版日期"]="2024.08";item.proposal!.metadata["自定义"]="核对值保留"
                item.customName="批量保存与改名";item.included=true;item.reviewed=true
                batch.preserveDates.state = .on;batch.applySelected();stage=3
            default:
                guard let batch,!batch.isApplying,let item=batch.items.first else {tick();return}
                try check(item.outcome == "已完成","批量界面完成保存与重命名")
                let reopened=try BookArchive(url:item.url)
                try check(item.url.deletingPathExtension().lastPathComponent=="批量保存与改名","批量界面写回规范名称")
                try check(reopened.metadata == item.proposal!.metadata,"批量界面将全部核对信息写回书籍")
                try check(reopened.chapters.map(\.title)==["原目录"],"批量信息修改保留原目录")
                batch.window.close();finish();return
            }
            tick()
        }catch{finish(error.localizedDescription)}
    }}
}
