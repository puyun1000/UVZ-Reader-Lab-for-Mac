import AppKit
import WebKit

final class FeatureUITest:NSObject,NSApplicationDelegate {
    let input:URL,output:URL,epubMode:Bool
    let adjustmentMode: Bool
    var batch: BatchNamingWindow?
    var original: Data?
    var reader:ReaderController?,epub:EPUBReader?,source:NamingSourceWindow?
    var stage=0,checks:[String]=[],deadline=Date().addingTimeInterval(90),waiting=false
    init(input:URL,output:URL,epub:Bool,adjustment:Bool = false) {self.input=input;self.output=output;epubMode=epub;adjustmentMode=adjustment}
    func applicationDidFinishLaunching(_ notification:Notification) {
        if epubMode {epub=EPUBReader(url:input);epub?.smokeMode=true}
        else if adjustmentMode {
            let batch = BatchNamingWindow()
            self.batch = batch
            batch.useOCR.state = .off
            batch.show()
            batch.loadFolder(input)
        } else {let reader=ReaderController();reader.smokeMode=true;self.reader=reader;reader.window.makeKeyAndOrderFront(nil);reader.open(input.appendingPathComponent("first.uvz"))}
        tick()
    }
    func check(_ condition:Bool,_ text:String) throws {
        guard condition else{throw ReaderFailure(text)}
        checks.append(text)
    }
    func finish() throws {
        let result:[String:Any]=["passed":checks.count,"checks":checks]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("FEATURE_UI_OK");exit(0)
    }
    func fail(_ error:Error)->Never {fputs("FEATURE_UI_FAILED \(error.localizedDescription) stage=\(stage)\n",stderr);exit(1)}
    func tick() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [self] in
            do {
                guard Date()<deadline else{throw ReaderFailure("界面验证超时。")}
                if adjustmentMode {try testAdjustment()} else if epubMode {try testEPUB()} else {try testReader()}
                tick()
            } catch {fail(error)}
        }
    }
    func testEPUB() throws {
        guard let epub,let web=epub.web,!web.isLoading,web.url != nil,!waiting else{return}
        waiting=true
        web.evaluateJavaScript("document.body.innerText") { [self] value,error in
            waiting=false
            do {
                if let error {throw error}
                let text=value as? String ?? ""
                if stage==0 {
                    try check(text.contains("第一章内容"),"EPUB正文实际渲染")
                    try check(epub.book?.chapters.count==2,"EPUB目录可用")
                    epub.nextChapter();stage=1
                } else {
                    try check(text.contains("第二章内容"),"EPUB下一节实际加载新内容")
                    epub.closeBook()
                    try check(epub.book==nil && epub.window.isVisible,"EPUB关闭书籍后保留窗口")
                    try finish()
                }
            } catch {fail(error)}
        }
    }
    func testAdjustment() throws {
        guard let batch else { return }
        let pdf = input.appendingPathComponent("a.pdf").standardizedFileURL
        let outputBook = output.deletingPathExtension().appendingPathExtension("pdf")
        switch stage {
        case 0:
            guard batch.items.count == 2, batch.bookPreview.canvas.hasPage else { return }
            try check(batch.bookPreview.url == pdf && batch.bookPreview.pageCount == 32, "固定预览打开完整 PDF")
            try check(batch.bookPreview.canvas.documentView is VectorPageView, "固定预览采用矢量页")
            batch.bookPreview.pageField.stringValue = "16"
            _ = NSApplication.shared.sendAction(batch.bookPreview.pageField.action!, to: batch.bookPreview.pageField.target, from: batch.bookPreview.pageField)
            stage = 1
        case 1:
            guard batch.bookPreview.canvas.hasPage else { return }
            try check(batch.bookPreview.page == 15, "可跳到不在首尾候选范围内的正文页")
            try screenshot(batch.window, "batch-preview")
            batch.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            stage = 2
        case 2:
            guard batch.bookPreview.canvas.hasPage, batch.bookPreview.url?.lastPathComponent == "b.uvz" else { return }
            try check(batch.bookPreview.page == 0 && batch.bookPreview.pageCount == 6, "点击另一行时同一窗格实时换书")
            try check(batch.bookPreview.canvas.documentView is PageProofImageView, "UVZ 显示原始图像")
            batch.closeWindow()
            let reader = ReaderController()
            reader.smokeMode = true
            self.reader = reader
            reader.window.makeKeyAndOrderFront(nil)
            reader.open(pdf)
            stage = 3
        case 3:
            guard let reader, reader.hasRenderedImage else { return }
            func button(_ title: String, in view: NSView) -> NSButton? {
                if let view = view as? NSButton, view.title == title { return view }
                return view.subviews.lazy.compactMap { button(title, in: $0) }.first
            }
            let view = reader.window.contentView!
            guard let query = button("目录与封面…", in: view), let bar = query.superview as? NSStackView,
                  let i = bar.arrangedSubviews.firstIndex(where: { $0 === query }), i > 0 else {
                throw ReaderFailure("找不到在线查询工具栏按钮")
            }
            try check((bar.arrangedSubviews[i-1] as? NSButton)?.title == "图书信息…", "在线查询入口紧邻图书信息")
            query.performClick(nil)
            try check(reader.onlineReferences != nil, "按钮打开目录与封面查询")
            reader.onlineReferences?.close()
            button("调整页面…", in: view)?.performClick(nil)
            try check(reader.adjustmentWindow != nil, "工具栏打开页面调整")
            stage = 4
        case 4:
            guard let editor = reader?.adjustmentWindow, editor.before.hasPage, editor.after.hasPage else { return }
            editor.scope.selectItem(at: 1)
            editor.range.stringValue = "1,3-4"
            editor.rotation.selectItem(at: 1)
            editor.cropFields[0].stringValue = "10"
            editor.refresh()
            stage = 5
        case 5:
            guard let editor = reader?.adjustmentWindow, editor.before.hasPage, editor.after.hasPage,
                  editor.after.size.width == editor.before.size.height else { return }
            try check(editor.after.size.height < editor.before.size.width, "同屏显示裁边和旋转效果")
            try screenshot(editor.window, "page-adjustment")
            original = try Data(contentsOf: pdf)
            try editor.saveCopy(to: outputBook)
            stage = 6
        default:
            guard reader?.adjustmentWindow == nil, FileManager.default.fileExists(atPath: outputBook.path) else { return }
            let copy = try BookArchive(url: outputBook)
            let unchanged = try Data(contentsOf: pdf) == original
            try check(copy.pages.count == 32 && unchanged, "范围另存通过原生界面并保留原书")
            try finish()
        }
    }
    private func screenshot(_ window: NSWindow, _ name: String) throws {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.deletingLastPathComponent().appendingPathComponent(name + ".png"))
    }
    func testReader() throws {
        guard let reader else{return}
        switch stage {
        case 0:
            guard reader.hasRenderedImage else{return}
            reader.showOnlineReferences()
            guard let online=reader.onlineReferences else{throw ReaderFailure("在线查询未打开")}
            try check(online.ssid.stringValue=="11111111","自动读取当前图书SS号")
            online.receiveDirectory("第一节\t1",ssid:"11111111")
            try check(online.adopt.isEnabled,"结果提供直接添加按钮")
            online.adoptDirectory()
            try check(reader.onlineReferences==nil && reader.editor?.textView.string.contains("第一节")==true,"添加结果打开目录编辑并写入草稿")
            reader.editor?.cancel()
            reader.open(input.appendingPathComponent("second.uvz"));stage=1
        case 1:
            guard reader.hasRenderedImage else{return}
            reader.showOnlineReferences()
            guard let online=reader.onlineReferences else{throw ReaderFailure("第二本查询未打开")}
            try check(online.ssid.stringValue=="22222222","切换书籍更新SS号")
            online.receiveDirectory("错误书目\t1",ssid:"11111111")
            try check(!online.adopt.isEnabled,"来源SS号不匹配时禁止导入")
            online.close()
            reader.setTestOptions(color:3,automaticContrast:true,contrast:1.4,gamma:0.9)
            stage=2
        case 2:
            guard reader.hasRenderedImage else{return}
            try check(reader.state.color==3 && reader.state.automaticContrast && reader.state.contrast==1.4,"护眼色与对比度组合可渲染")
            let pdf=input.appendingPathComponent("crop.pdf")
            let p=NamingPage(physical:1,file:"crop.pdf",role:"版权页",text:"核对文字",textLayer:true)
            let proposal=BatchNaming.merge(original:[:],evidence:[],pages:[p],fingerprint:try BatchNaming.fingerprint(pdf))
            source=NamingSourceWindow(url:pdf,proposal:proposal);source?.show(on:reader.window);stage=3
        default:
            guard let source,source.pdfView.document != nil,!source.pdfView.isHidden else{return}
            try check(source.pdfView.displayBox == .cropBox,"原图核对采用PDF成书裁切框")
            source.fitPage();let fit=source.pdfView.scaleFactor
            source.zoomIn();try check(source.pdfView.scaleFactor>fit,"原图可矢量放大")
            source.fitWidth();try check(abs(source.pdfView.scaleFactor*(source.pdfView.currentPage?.orientedCropSize.width ?? 0)-source.pdfView.bounds.width)<3,"原图按成书宽度适配")
            if let view=source.window.contentView,let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:rep)
                try rep.representation(using:.png,properties:[:])?.write(to:output.deletingPathExtension().appendingPathExtension("png"))
            }
            source.closeWindow();try finish()
        }
    }
}
