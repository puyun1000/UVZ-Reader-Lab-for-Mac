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
            guard batch.items.count == 2, !batch.isAnalysing, batch.bookPreview.canvas.hasPage else { return }
            try check(batch.bookPreview.url == pdf && batch.bookPreview.pageCount == 32, "固定预览打开完整 PDF")
            try check(batch.bookPreview.canvas.documentView is VectorPageView, "固定预览采用矢量页")
            batch.window.contentView?.layoutSubtreeIfNeeded()
            let viewport = batch.table.enclosingScrollView!.frame
            try check(viewport.width > batch.window.contentView!.bounds.width * 0.55 && viewport.height > 420,
                      "书单优先分配宽度和高度")
            try check(batch.items.allSatisfy { !$0.included }, "选书与自动分析均不勾选未操作的图书")
            let normalSize = batch.window.contentView!.bounds.size
            batch.window.setContentSize(NSSize(width: 1040, height: 650))
            batch.window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
            let narrowList = batch.table.enclosingScrollView!.frame.width
            let narrowPreview = batch.bookPreview.frame.width
            guard narrowList > narrowPreview && narrowPreview >= 360 else {
                throw ReaderFailure("窄窗口尺寸未通过，书单 \(narrowList)，预览 \(narrowPreview)")
            }
            try check(true, "窄窗口仍优先保留书单且可预览")
            batch.window.setContentSize(normalSize)
            batch.window.contentView?.layoutSubtreeIfNeeded()
            batch.finalName.stringValue = "手工文件名"
            batch.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: batch.finalName))
            try check(batch.items[0].customName == "手工文件名" && !batch.items[0].reviewed && !batch.items[0].included,
                      "只编辑文件名时仍需核对书目")
            let field = batch.fields[1]
            field.stringValue = "人工核对书名"
            batch.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
            try check(batch.items[0].reviewed && batch.items[0].included && !batch.items[1].included,
                      "改书目信息只自动勾选当前图书")

            try check(batch.items[0].stem == "手工文件名", "修改书目字段后保留手工文件名")
            let firstRow = batch.table.rect(ofRow: 0), secondRow = batch.table.rect(ofRow: 1)
            let start = batch.table.convert(NSPoint(x: 80, y: firstRow.midY), to: nil)
            let end = batch.table.convert(NSPoint(x: 135, y: secondRow.midY), to: nil)
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: batch.window.windowNumber, context: nil, eventNumber: 1,
                                   clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false)
            NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
            batch.table.mouseDown(with: mouse(.leftMouseDown, start))
            try check(batch.items.allSatisfy(\.included) && !batch.items[1].reviewed,
                      "在文件名单元格内拖框可同时勾选多本并保留核对状态")
            batch.toggleAll()
            try check(batch.items.allSatisfy { !$0.included }, "表头可取消框选后的全部勾选")
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
            batch.reviewed.state = .on
            batch.reviewChanged()
            try check(batch.items[1].included && !batch.items[0].included, "手动确认核对后自动勾选选中图书")
            batch.supplementBookmarks()
            stage = 7
        case 7:
            guard let query = batch.referenceWindow else { return }
            try check(query.mode == .bookmarks && query.coverButton.superview == nil, "批量补书签窗口仅显示书签查询")
            try check(query.ssid.stringValue == "22222222", "补书签自动带入选中书目的 SS 号")
            let book = batch.items[1].url
            original = try Data(contentsOf: book)
            query.receiveDirectory("测试书签\t1", ssid: "22222222")
            query.adoptDirectory()
            guard let editor = batch.bookmarkEditor else { throw ReaderFailure("未打开目录草稿") }
            let unchanged = try Data(contentsOf: book) == original
            try check(editor.textView.string.contains("测试书签") && unchanged, "采用书签后先进入目录草稿")
            editor.saveDraft()
            stage = 8
        case 8:
            guard batch.bookmarkEditor == nil, batch.bookPreview.canvas.hasPage,
                  batch.items[1].proposal?.fingerprint == (try BatchNaming.fingerprint(batch.items[1].url)) else { return }
            let saved = try BookArchive(url: batch.items[1].url)
            try check(saved.chapters.contains { $0.title == "测试书签" } && batch.items[1].included,
                      "保存书签后更新批量草稿文件指纹并保留勾选")
            batch.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            stage = 9
        case 9:
            guard batch.bookPreview.canvas.hasPage else { return }
            try check(batch.bookPreview.page == 15, "切回图书恢复上次预览页码")
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
            guard let query = button("补书签…", in: view), let bar = query.superview as? NSStackView,
                  let i = bar.arrangedSubviews.firstIndex(where: { $0 === query }), i + 1 < bar.arrangedSubviews.count else {
                throw ReaderFailure("找不到在线查询工具栏按钮")
            }
            try check((bar.arrangedSubviews[i+1] as? NSButton)?.title == "图书信息…", "在线查询入口紧邻图书信息")
            query.performClick(nil)
            try check(reader.onlineReferences?.mode == .bookmarks && reader.onlineReferences?.coverButton.superview == nil, "阅读按钮打开仅查询书签的窗口")
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
