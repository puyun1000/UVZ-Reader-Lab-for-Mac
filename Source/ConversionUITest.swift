import AppKit

final class ConversionUITest {
    private static var retained:ConversionUITest?
    let app:AppDelegate,controller=ConversionWindow(),folder:URL,output:URL,reader:ReaderController
    var stage=0,checks:[String]=[],deadline=Date().addingTimeInterval(90)
    let defaults=UserDefaults.standard,oldNaming:Any?,oldStyle:Any?,oldColor:Any?
    static func run(app:AppDelegate,folder:URL,output:URL) {let test=ConversionUITest(app:app,folder:folder,output:output);retained=test;test.begin()}
    init(app:AppDelegate,folder:URL,output:URL) {self.app=app;self.folder=folder;self.output=output;reader=app.createWindow();oldColor=UserDefaults.standard.object(forKey:"settings.color");oldNaming=UserDefaults.standard.object(forKey:"conversion.naming");oldStyle=UserDefaults.standard.object(forKey:"conversion.style")}
    func begin() {controller.naming.selectItem(at:0);controller.style.selectItem(at:0);reader.window.makeKeyAndOrderFront(nil);tick()}
    func check(_ value:Bool,_ title:String) throws {if !value {throw ReaderFailure(title)};checks.append(title)}
    func capture(_ window:NSWindow,_ suffix:String) throws {
        let path=output.deletingPathExtension().appendingPathExtension(suffix+".png")
        window.contentView?.layoutSubtreeIfNeeded();window.display()
        let view=window.contentView!,rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let source=rep.cgImage,let ctx=CGContext(data:nil,width:rep.pixelsWide,height:rep.pixelsHigh,bitsPerComponent:8,bytesPerRow:rep.pixelsWide*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw ReaderFailure("窗口截图失败")}
        let rect=CGRect(x:0,y:0,width:rep.pixelsWide,height:rep.pixelsHigh)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {ctx.setFillColor(NSColor.windowBackgroundColor.cgColor);ctx.fill(rect)}
        ctx.draw(source,in:rect)
        guard let cg=ctx.makeImage(),let png=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else {throw ReaderFailure("窗口图像写入失败")}
        try png.write(to:path)
    }
    func restorePreferences() {
        if let oldColor {defaults.set(oldColor,forKey:"settings.color")} else {defaults.removeObject(forKey:"settings.color")}
        if let oldNaming {defaults.set(oldNaming,forKey:"conversion.naming")} else {defaults.removeObject(forKey:"conversion.naming")}
        if let oldStyle {defaults.set(oldStyle,forKey:"conversion.style")} else {defaults.removeObject(forKey:"conversion.style")}
    }
    func tick() {DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [self] in
        do {
            guard Date()<deadline else {throw ReaderFailure("转换界面检查超时，阶段\(stage)")}
            switch stage {
            case 0:
                try check(reader.book == nil,"阅读空状态保留独立打开与转换入口")
                try capture(reader.window,"empty");controller.show();controller.add([folder]);stage=1
            case 1:
                guard controller.startButton.isEnabled,controller.jobs.count==2 else {tick();return}
                try check(controller.jobs.allSatisfy {$0.stem == $0.source.deletingPathExtension().lastPathComponent},"默认完整保留来源名称")
                controller.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
                controller.nameField.stringValue="手工目标名称";controller.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:controller.nameField))
                controller.naming.selectItem(at:1);controller.optionsChanged()
                try check(controller.jobs[0].stem == "手工目标名称" && controller.jobs[0].manualName,"切换规范模板保留手工目标名")
                controller.regenerate();try check(!controller.jobs[0].manualName && controller.jobs[0].stem.hasPrefix("【") && controller.jobs[0].stem.hasSuffix("_12345670"),"重新生成恢复共享模板与丛书策略")
                controller.naming.selectItem(at:0);controller.optionsChanged()
                controller.window.appearance=NSAppearance(named:.aqua);try capture(controller.window,"light")
                controller.window.appearance=NSAppearance(named:.darkAqua);try capture(controller.window,"dark")
                controller.window.setContentSize(NSSize(width:880,height:640));stage=2
            case 2:
                controller.window.contentView?.layoutSubtreeIfNeeded()
                try check(controller.usesVerticalLayout && controller.queueFrame.minY >= controller.outputSettingsFrame.maxY,"任务列表在上，输出设置在下且不重叠")
                try check(controller.window.toolbar == nil && controller.nameField.cell?.wraps == true,"移除重复输出选项按钮，长目标名可换行核对")
                try capture(controller.window,"narrow");controller.window.setContentSize(NSSize(width:960,height:900));stage=3
            case 3:
                try check(controller.usesVerticalLayout,"放大后保持上下布局")
                controller.start();controller.stop();stage=4
            case 4:
                guard !controller.isRunning else {tick();return}
                try check(controller.jobs.allSatisfy {$0.result == nil},"立即停止不提交未完成文件")
                controller.start();stage=5
            case 5:
                guard !controller.isRunning else {tick();return}
                try check(controller.jobs.allSatisfy {$0.result?.outputPages == 3},"独立队列逐本完成PDF输出")
                try check(controller.pageProgress.doubleValue == 1 && controller.totalProgress.doubleValue == 1,"任务结束单书与总体进度一致")
                try check(controller.jobs.allSatisfy {$0.result.map {FileManager.default.fileExists(atPath:$0.output)} ?? false},"结果路径指向实际PDF")
                controller.logScroll.isHidden=false;try capture(controller.window,"complete")
                let online=OnlineReferences(ssid:"12345678");online.show();try check((online.text.enclosingScrollView?.frame.height ?? 0)>250 && online.image.frame.width>120,"在线查询窗口保留可核对的目录文本区与封面区");try capture(online.window,"online");app.closeContext(online.window);try check(!online.window.isVisible,"关闭在线参考窗口按当前窗口处理")
                try check(OnlineReferenceClient.directoryText("父项|01|1|0|6\n子项|0101|2|0|6")=="父项\t1\n\t子项\t2","在线DAT目录转为可编辑层级与页号")
                let book=try BookArchive(url:controller.jobs[0].source),before=try BatchNaming.fingerprint(controller.jobs[0].source),editor=BookEditor(book:book)
                editor.categoryPopup.selectItem(at:3);editor.categoryChanged()
                try check(editor.insertReferenceContents("在线章一\t1\n\t在线子章\t2") && editor.categoryPopup.indexOfSelectedItem == 0 && editor.textView.string.contains("在线子章"),"在线目录追加前切换全部类型，避免误用当前分区页号")
                editor.cancel();try check((try BatchNaming.fingerprint(controller.jobs[0].source)) == before,"在线目录草稿取消不改来源")
                reader.open(controller.jobs[0].source);stage=6
            default:
                guard reader.hasRenderedImage else {tick();return}
                try check(reader.state.color == 1,"未设置配色时默认使用页面原色")
                reader.fitHeightButton.performClick(nil);try check(reader.state.fit == 2,"适合高度可以直接点击")
                reader.fitWholeButton.performClick(nil);try check(reader.state.fit == 1,"适合整页可以直接点击")
                reader.fitWidthButton.performClick(nil);try check(reader.state.fit == 0,"适合宽度可以直接点击")
                reader.invertedColor();reader.defaultColorButton.performClick(nil);try check(AppSettings().pageColor == 2,"当前配色可设为默认并记住")
                reader.originalColor();try capture(reader.window,"reader")
                let field=CenteredTextField(string:"繁體 ABC");reader.window.contentView?.addSubview(field)
                try check(reader.window.fieldEditor(true,for:field) is ChineseTextView,"图书信息及命名输入框使用中文文字菜单")
                field.frame=NSRect(x:20,y:20,width:300,height:40);field.font = .systemFont(ofSize:13)
                let cell=field.cell as! CenteredTextFieldCell
                let rect=cell.drawingRect(forBounds:field.bounds)
                try check(abs(rect.midY-field.bounds.midY)<2,"单行栏框文字上下居中")
                reader.window.makeFirstResponder(field);field.selectText(nil)
                let editor=reader.window.fieldEditor(true,for:field) as! NSTextView
                let editorRect=editor.convert(editor.bounds,to:field)
                try check(abs(editorRect.midY-field.bounds.midY)<4,"输入和选择文字时仍上下居中")
                reader.window.makeFirstResponder(nil)
                let wrap=CenteredTextField(wrappingLabelWithString:"分行说明\n第二行");wrap.frame=NSRect(x:0,y:0,width:300,height:80)
                try check(wrap.cell?.wraps == true && wrap.cell?.isScrollable == false,"多行说明保留换行布局")
                field.removeFromSuperview()
                let text=ChineseTextView(frame:NSRect(x:0,y:0,width:400,height:150));text.isEditable=true;text.allowsUndo=true;reader.window.contentView?.addSubview(text)
                text.string="😀 繁體ABC 後段";text.setSelectedRange(NSRange(location:3,length:5));let action=NSMenuItem();action.tag=0;text.convertSelection(action)
                try check(text.string == "😀 繁体ABC 後段","转换仅作用于所选文字，正确处理Unicode范围")
                try check(text.undoManager?.canUndo == true,"文字转换产生可撤销编辑")
                text.undoManager?.undo();try check(text.string == "😀 繁體ABC 後段","撤销恢复转换前文字")
                let menu=text.chineseMenu();try check(menu.item(withTitle:"文字转换")?.submenu?.items.filter {!$0.isSeparatorItem}.count == 9,"文字菜单包含繁简、全半角、大小写和中英文标点")
                let native=NSMenu();native.addItem(withTitle:"Copy",action:nil,keyEquivalent:"");native.addItem(withTitle:"Look Up “text”",action:nil,keyEquivalent:"");ChineseMenus.localize(native)
                try check(native.items.map(\.title) == ["复制","查询 “text”"],"系统文字与识别菜单统一中文")
                text.removeFromSuperview()
                try check(reader.pageContextMenu().item(withTitle:"框选识别目录…") != nil && reader.pageContextMenu().item(withTitle:"复制页面图像") != nil,"页面右键提供常用阅读及编辑操作")
                restorePreferences()
                let data=try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"version":"0.16.0"],options:[.prettyPrinted,.sortedKeys]);try data.write(to:output.deletingPathExtension().appendingPathExtension("json"));print("CONVERSION_UI_OK");exit(0)
            }
            tick()
        } catch {restorePreferences();fputs("CONVERSION_UI_FAILED \(error.localizedDescription) stage=\(stage)\n",stderr);exit(1)}
    }}
}
