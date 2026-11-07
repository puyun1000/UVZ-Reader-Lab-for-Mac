import AppKit
import WebKit

final class FeatureUITest:NSObject,NSApplicationDelegate {
    let input:URL,output:URL,epubMode:Bool
    var reader:ReaderController?,epub:EPUBReader?,source:NamingSourceWindow?
    var stage=0,checks:[String]=[],deadline=Date().addingTimeInterval(90),waiting=false
    init(input:URL,output:URL,epub:Bool) {self.input=input;self.output=output;epubMode=epub}
    func applicationDidFinishLaunching(_ notification:Notification) {
        if epubMode {epub=EPUBReader(url:input);epub?.smokeMode=true}
        else {let reader=ReaderController();reader.smokeMode=true;self.reader=reader;reader.window.makeKeyAndOrderFront(nil);reader.open(input.appendingPathComponent("first.uvz"))}
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
                if epubMode {try testEPUB()} else {try testReader()}
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
            source.fitWidth();try check(abs(source.pdfView.scaleFactor*(source.pdfView.currentPage?.bounds(for:.cropBox).width ?? 0)-source.pdfView.bounds.width)<3,"原图按成书宽度适配")
            if let view=source.window.contentView,let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:rep)
                try rep.representation(using:.png,properties:[:])?.write(to:output.deletingPathExtension().appendingPathExtension("png"))
            }
            source.closeWindow();try finish()
        }
    }
}
