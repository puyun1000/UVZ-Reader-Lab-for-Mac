import AppKit
import WebKit
import CryptoKit
import UniformTypeIdentifiers

struct EPUBChapter {
    let title: String
    let path: String
    let level: Int
}

/// Reads OPF, EPUB 3 navigation and EPUB 2 NCX from the existing bounded ZIP reader.
final class EPUBArchive {
    let url: URL, title: String
    let spine: [String], chapters: [EPUBChapter]
    let metadata: [String:String]
    private let bytes: Data
    private let entries: [String:ArchiveEntry]
    private let fontKeys: [String:([UInt8],Int)]
    static let origin=URL(string:"readerlab-epub://book/")!

    static func path(_ reference:String,relativeTo base:String = "") throws -> String {
        guard let url=URL(string:reference,relativeTo:origin.appendingPathComponent(base).deletingLastPathComponent())?.absoluteURL,
              url.scheme==origin.scheme,url.host==origin.host,!url.path.contains("\0") else {
            throw ReaderFailure("EPUB 资源地址无效。")
        }
        return String(url.path.dropFirst())
    }
    private static func xml(_ data:Data) throws -> XMLDocument {
        guard data.count<=8*1024*1024 else{throw ReaderFailure("EPUB 结构文件过大。")}
        return try XMLDocument(data:data,options:[.nodeLoadExternalEntitiesNever])
    }
    private static func nodes(_ root:XMLNode,_ name:String)->[XMLElement] {
        (try? root.nodes(forXPath:".//*[local-name()='\(name)']").compactMap {$0 as? XMLElement}) ?? []
    }
    init(url:URL) throws {
        self.url=url
        let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
        let directory=try BookArchive.readDirectory(bytes)
        var entries:[String:ArchiveEntry]=[:]
        for entry in directory {
            guard entries[entry.name]==nil else{throw ReaderFailure("EPUB 存在重复资源。")}
            entries[entry.name]=entry
        }
        func read(_ path:String) throws -> Data {
            guard let entry=entries[path] else{throw ReaderFailure("EPUB 缺少资源："+path)}
            return try BookArchive.read(entry,from:bytes)
        }
        let container=try Self.xml(read("META-INF/container.xml"))
        guard let packageName=Self.nodes(container,"rootfile").first?.attribute(forName:"full-path")?.stringValue else{throw ReaderFailure("EPUB 缺少 OPF 入口。")}
        let packagePath=try Self.path(packageName),package=try Self.xml(read(packagePath))
        var metadata:[String:String]=[:]
        for (tag,field) in [("title","书名"),("creator","作者"),("publisher","出版社"),("date","出版日期"),("description","摘要"),("language","语言")] {
            let values=Self.nodes(package,tag).compactMap {$0.stringValue?.trimmingCharacters(in:.whitespacesAndNewlines)}.filter {!$0.isEmpty}
            if !values.isEmpty {metadata[field]=values.joined(separator:"；")}
        }
        let identifiers=Self.nodes(package,"identifier")
        let uniqueID=package.rootElement()?.attribute(forName:"unique-identifier")?.stringValue
        let identifier=(identifiers.first {$0.attribute(forName:"id")?.stringValue==uniqueID} ?? identifiers.first)?.stringValue ?? ""
        var manifest:[String:(path:String,mime:String,properties:String)]=[:]
        for item in Self.nodes(package,"item") {
            guard let id=item.attribute(forName:"id")?.stringValue,let href=item.attribute(forName:"href")?.stringValue else{continue}
            manifest[id]=(try Self.path(href,relativeTo:packagePath),item.attribute(forName:"media-type")?.stringValue ?? "",item.attribute(forName:"properties")?.stringValue ?? "")
        }
        let spine=Self.nodes(package,"itemref").compactMap {item -> String? in
            guard item.attribute(forName:"linear")?.stringValue != "no",let id=item.attribute(forName:"idref")?.stringValue,
                  let value=manifest[id],["application/xhtml+xml","text/html","image/svg+xml"].contains(value.mime),entries[value.path] != nil else{return nil}
            return value.path
        }
        guard !spine.isEmpty,spine.count<=50000 else{throw ReaderFailure("EPUB 没有可阅读的章节。")}
        var chapters:[EPUBChapter]=[]
        func target(_ href:String,from base:String) throws -> String {
            let path=try Self.path(href,relativeTo:base)
            return path+(URL(string:href)?.fragment.map {"#"+$0} ?? "")
        }
        if let nav=manifest.values.first(where:{$0.properties.split(separator:" ").contains("nav")}),
           let document=try? Self.xml(read(nav.path)) {
            let navigation=Self.nodes(document,"nav")
            let toc=navigation.first {($0.attribute(forName:"epub:type")?.stringValue ?? "").split(separator:" ").contains("toc")} ?? navigation.first
            if let toc {
                for item in Self.nodes(toc,"li") {
                    guard let anchor=item.children?.compactMap({$0 as? XMLElement}).first(where:{$0.localName=="a" || $0.name=="a"}),
                          let href=anchor.attribute(forName:"href")?.stringValue,let title=anchor.stringValue,!title.isEmpty else{continue}
                    var level=0,parent=item.parent
                    while let node=parent,node !== toc {if node.localName=="li" || node.name=="li" {level+=1};parent=node.parent}
                    if let path=try? target(href,from:nav.path) {chapters.append(.init(title:title,path:path,level:min(32,level)))}
                }
            }
        }
        if chapters.isEmpty,let ncx=manifest.values.first(where:{$0.mime=="application/x-dtbncx+xml"}),
           let document=try? Self.xml(read(ncx.path)) {
            for point in Self.nodes(document,"navPoint") {
                guard let content=point.children?.compactMap({$0 as? XMLElement}).first(where:{$0.localName=="content" || $0.name=="content"}),
                      let href=content.attribute(forName:"src")?.stringValue,
                      let label=point.children?.compactMap({$0 as? XMLElement}).first(where:{$0.localName=="navLabel" || $0.name=="navLabel"})?.stringValue else{continue}
                var level=0,parent=point.parent
                while let node=parent {if node.localName=="navPoint" || node.name=="navPoint" {level+=1};parent=node.parent}
                if let path=try? target(href,from:ncx.path) {chapters.append(.init(title:label.trimmingCharacters(in:.whitespacesAndNewlines),path:path,level:min(32,level)))}
            }
        }
        if chapters.isEmpty {chapters=spine.enumerated().map {.init(title:"第 \($0.offset+1) 节",path:$0.element,level:0)}}
        var fontKeys:[String:([UInt8],Int)]=[:]
        if entries["META-INF/encryption.xml"] != nil {
            let document=try Self.xml(read("META-INF/encryption.xml"))
            for encrypted in Self.nodes(document,"EncryptedData") {
                let algorithm=Self.nodes(encrypted,"EncryptionMethod").first?.attribute(forName:"Algorithm")?.stringValue
                guard let uri=Self.nodes(encrypted,"CipherReference").first?.attribute(forName:"URI")?.stringValue else{throw ReaderFailure("EPUB 加密资源说明不完整。")}
                let path=try Self.path(uri)
                if algorithm=="http://www.idpf.org/2008/embedding" {
                    let clean=identifier.filter {!$0.isWhitespace}
                    fontKeys[path]=(Array(Insecure.SHA1.hash(data:Data(clean.utf8))),1040)
                } else if algorithm=="http://ns.adobe.com/pdf/enc#RC" {
                    let hex=identifier.replacingOccurrences(of:"urn:uuid:",with:"").replacingOccurrences(of:"-",with:"")
                    guard hex.count==32 else{throw ReaderFailure("EPUB 字体标识无效。")}
                    var key:[UInt8]=[]
                    for i in stride(from:0,to:32,by:2) {
                        let start=hex.index(hex.startIndex,offsetBy:i),end=hex.index(start,offsetBy:2)
                        guard let byte=UInt8(hex[start..<end],radix:16) else{throw ReaderFailure("EPUB 字体标识无效。")}
                        key.append(byte)
                    }
                    fontKeys[path]=(key,1024)
                } else {throw ReaderFailure("此 EPUB 使用了尚不支持的加密资源。")}
            }
        }
        self.bytes=bytes;self.entries=entries;self.fontKeys=fontKeys
        self.spine=spine;self.chapters=chapters;self.metadata=metadata
        title=metadata["书名"] ?? url.deletingPathExtension().lastPathComponent
    }
    func resource(_ path:String) throws -> Data {
        guard let entry=entries[path] else{throw ReaderFailure("EPUB 资源不存在。")}
        var data=try BookArchive.read(entry,from:bytes)
        if let (key,count)=fontKeys[path],!key.isEmpty {
            for i in 0..<min(count,data.count) {data[i] ^= key[i%key.count]}
        }
        return data
    }
}

final class EPUBSchemeHandler:NSObject,WKURLSchemeHandler {
    let book:EPUBArchive
    var warm=false
    init(book:EPUBArchive) {self.book=book}
    func webView(_ webView:WKWebView,start task:WKURLSchemeTask) {
        do {
            guard let url=task.request.url,url.host=="book" else{throw ReaderFailure("EPUB 资源地址无效。")}
            let path=String(url.path.dropFirst())
            var bytes=try book.resource(path)
            let ext=(path as NSString).pathExtension.lowercased()
            var mime=UTType(filenameExtension:ext)?.preferredMIMEType ?? "application/octet-stream"
            if ["xhtml","html","htm"].contains(ext) {
                mime="text/html"
                guard var html=String(data:bytes,encoding:.utf8) else{throw ReaderFailure("EPUB 章节文字编码无法读取。")}
                let colors=warm ? "background:#f5e8cc!important;color:#493728!important;" : ""
                let style="<meta http-equiv=\"Content-Security-Policy\" content=\"default-src readerlab-epub: data:; script-src 'none'; connect-src 'none'; form-action 'none'; frame-src 'none'\"><style>html,body{\(colors)}body{margin:2em auto;padding:0 2em;max-width:52em;line-height:1.7}img,svg{max-width:100%;height:auto}</style>"
                if let range=html.range(of:"<head[^>]*>",options:[.regularExpression,.caseInsensitive]) {html.insert(contentsOf:style,at:range.upperBound)}
                else {html=style+html}
                bytes=Data(html.utf8)
            }
            task.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:bytes.count,textEncodingName:"utf-8"))
            task.didReceive(bytes);task.didFinish()
        } catch {task.didFailWithError(error)}
    }
    func webView(_ webView:WKWebView,stop task:WKURLSchemeTask) {}
}

final class EPUBReader:NSResponder,NSWindowDelegate,WKNavigationDelegate,NSMenuItemValidation {
    let window=ChineseWindow(contentRect:NSRect(x:0,y:0,width:1050,height:820),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
    private(set) var book:EPUBArchive?
    private(set) var web:WKWebView?
    private var handler:EPUBSchemeHandler?
    private let chapter=NSPopUpButton(),status=CenteredTextField(labelWithString:"正在读取 EPUB…")
    private let warm=NSButton(checkboxWithTitle:"护眼色",target:nil,action:nil)
    private let previous=NSButton(title:"上一节",target:nil,action:nil),next=NSButton(title:"下一节",target:nil,action:nil)
    private var index=0,closed=false,locationKey="",loadedTarget:String?
    private var zoom=1.0
    private let webHost=NSView()
    private var bookClosed=false
    var onClose:(()->Void)?,onChanged:(()->Void)?
    let url:URL
    var smokeMode=false
    init(url:URL) {
        self.url=url;super.init()
        window.title="EPUB — "+url.lastPathComponent;window.identifier = .init("UVZEPUB")
        window.isReleasedWhenClosed=false;window.delegate=self;nextResponder=window.nextResponder;window.nextResponder=self;window.minSize=NSSize(width:700,height:500)
        for (button,action) in [(previous,#selector(previousChapter)),(next,#selector(nextChapter)),(warm,#selector(changeWarm))] {button.target=self;button.action=action;button.bezelStyle = .rounded}
        chapter.target=self;chapter.action = #selector(selectChapter);chapter.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let smaller=NSButton(title:"缩小文字",target:self,action:#selector(smallerText)),larger=NSButton(title:"放大文字",target:self,action:#selector(largerText))
        smaller.bezelStyle = .rounded;larger.bezelStyle = .rounded
        let bar=NSStackView(views:[previous,chapter,next,smaller,larger,warm]);bar.spacing=8
        let root=NSStackView(views:[bar,webHost,status]);root.orientation = .vertical;root.alignment = .leading;root.spacing=10
        let host=NSView();window.contentView=host;root.translatesAutoresizingMaskIntoConstraints=false;host.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:12),root.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-12),root.topAnchor.constraint(equalTo:host.topAnchor,constant:12),root.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-10)])
        for view in [bar,webHost,status] {view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true}
        status.font = .systemFont(ofSize:12);webHost.setContentHuggingPriority(.defaultLow,for:.vertical)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result {try EPUBArchive(url:url)}
            DispatchQueue.main.async {guard let self,!self.closed,!self.bookClosed else{return};self.loaded(result)}
        }
    }
    required init?(coder:NSCoder) {fatalError("init(coder:)")}
    private func loaded(_ result:Result<EPUBArchive,Error>) {
        switch result {
        case .failure(let error):status.stringValue=error.localizedDescription
        case .success(let book):
            self.book=book;window.title=book.title+" — UVZ Reader Lab";window.representedURL=url
            locationKey="epub:"+url.standardizedFileURL.path
            let state=smokeMode ? [:] : UserDefaults.standard.dictionary(forKey:locationKey) ?? [:]
            index=min(book.spine.count-1,max(0,state["index"] as? Int ?? 0))
            zoom=min(2.5,max(0.6,state["zoom"] as? Double ?? 1))
            warm.state=(state["warm"] as? Bool ?? false) ? .on:.off
            let handler=EPUBSchemeHandler(book:book);self.handler=handler;handler.warm=warm.state == .on
            let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript=false
            config.setURLSchemeHandler(handler,forURLScheme:"readerlab-epub")
            let web=WKWebView(frame:.zero,configuration:config);self.web=web;web.navigationDelegate=self;web.pageZoom=zoom
            web.translatesAutoresizingMaskIntoConstraints=false;webHost.addSubview(web)
            NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo:webHost.leadingAnchor),web.trailingAnchor.constraint(equalTo:webHost.trailingAnchor),web.topAnchor.constraint(equalTo:webHost.topAnchor),web.bottomAnchor.constraint(equalTo:webHost.bottomAnchor)])
            chapter.addItems(withTitles:book.chapters.map {String(repeating:"　",count:min(8,$0.level))+$0.title})
            show(book.spine[index])
            if !smokeMode {NSDocumentController.shared.noteNewRecentDocumentURL(url)}
            onChanged?()
        }
    }
    private func show(_ path:String) {
        guard let book,let url=URL(string:path,relativeTo:EPUBArchive.origin) else{return}
        if let resolved=try? EPUBArchive.path(path),let i=book.spine.firstIndex(of:resolved) {index=i}
        if let selected=book.chapters.firstIndex(where:{$0.path==path || ($0.path.components(separatedBy:"#").first==path)}) {chapter.selectItem(at:selected)}
        loadedTarget=path;web?.load(URLRequest(url:url));previous.isEnabled=index>0;next.isEnabled=index+1<book.spine.count
        status.stringValue="第 \(index+1)／\(book.spine.count) 节"
        save()
    }
    private func save() {
        guard !smokeMode,!locationKey.isEmpty else{return}
        UserDefaults.standard.set(["index":index,"zoom":zoom,"warm":warm.state == .on],forKey:locationKey)
    }
    @objc private func selectChapter() {guard let book,book.chapters.indices.contains(chapter.indexOfSelectedItem) else{return};show(book.chapters[chapter.indexOfSelectedItem].path)}
    @objc func previousChapter() {guard let book,index>0 else{return};show(book.spine[index-1])}
    @objc func nextChapter() {guard let book,index+1<book.spine.count else{return};show(book.spine[index+1])}
    @objc private func largerText() {zoom=min(2.5,zoom+0.1);web?.pageZoom=zoom;save()}
    @objc private func smallerText() {zoom=max(0.6,zoom-0.1);web?.pageZoom=zoom;save()}
    @objc private func changeWarm() {handler?.warm=warm.state == .on;if let loadedTarget {show(loadedTarget)}}
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard let target=action.request.url else{decisionHandler(.cancel);return}
        if target.scheme=="readerlab-epub",target.host=="book" {
            if let book,let i=book.spine.firstIndex(of:String(target.path.dropFirst())) {
                index=i;loadedTarget=String(target.path.dropFirst())+(target.fragment.map {"#"+$0} ?? "")
                previous.isEnabled=index>0;next.isEnabled=index+1<book.spine.count
                if let selected=book.chapters.firstIndex(where:{$0.path==loadedTarget}) {chapter.selectItem(at:selected)}
                save();status.stringValue="第 \(index+1)／\(book.spine.count) 节"
            }
            decisionHandler(.allow)
        } else {
            if action.navigationType == .linkActivated,["https","http"].contains(target.scheme ?? "") {NSWorkspace.shared.open(target)}
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {status.stringValue=error.localizedDescription}
    func closeBook() {
        bookClosed=true;save();book=nil;web?.stopLoading();web?.removeFromSuperview();web=nil;handler=nil
        window.title="UVZ Reader Lab";window.representedURL=nil;chapter.removeAllItems();previous.isEnabled=false;next.isEnabled=false
        status.stringValue="书籍已关闭，可从「文件」菜单打开下一本。";onChanged?()
    }
    @objc func nextPage() {nextChapter()}
    @objc func previousPage() {previousChapter()}
    @objc func zoomIn() {largerText()}
    @objc func zoomOut() {smallerText()}
    @objc func warmColor() {warm.state = .on;changeWarm()}
    @objc func originalColor() {warm.state = .off;changeWarm()}
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        guard book != nil else{return false}
        switch item.action {
        case #selector(nextPage):return index+1<(book?.spine.count ?? 0)
        case #selector(previousPage):return index>0
        case #selector(zoomIn),#selector(zoomOut),#selector(warmColor),#selector(originalColor):return true
        default:return false
        }
    }
    func windowWillClose(_ notification:Notification) {closed=true;save();web?.stopLoading();onClose?()}
}
