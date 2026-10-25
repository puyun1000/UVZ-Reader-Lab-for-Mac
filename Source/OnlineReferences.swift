import AppKit
import ImageIO

struct OnlineReferenceReply {
    let ssid: String
    let text: String?
    let coverURL: URL?
    let remaining: Int?,limit: Int?
    let error: String?
}
enum OnlineReferenceClient {
    static let origin=URL(string:"https://wbfan.site")!
    static func parse(_ data:Data,ssid:String) throws -> OnlineReferenceReply {
        guard data.count<=4*1024*1024,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw ReaderFailure("外部服务返回的数据无法读取。")}
        let quota=root["quota"] as? [String:Any],result=root["result"] as? [String:Any]
        if let result,result["ssid"] as? String != ssid {throw ReaderFailure("返回的SS号与查询不符，未采用结果。")}
        var cover:URL?
        if let value=result?["url"] as? String,let url=URL(string:value,relativeTo:origin)?.absoluteURL {
            guard url.scheme == "https",url.host == origin.host,url.path.hasPrefix("/duxiu/cover/image/") else {throw ReaderFailure("外部封面地址不符合预期。")};cover=url
        }
        return .init(ssid:ssid,text:result?["text"] as? String,coverURL:cover,remaining:quota?["remaining"] as? Int,limit:quota?["limit"] as? Int,error:root["error"] as? String)
    }
    static func request(ssid:String,cover:Bool) throws -> URLRequest {
        guard ssid.range(of:"^[0-9]{8}$",options:.regularExpression) != nil else {throw ReaderFailure("请填写8位数字SS号。")}
        var request=URLRequest(url:origin.appendingPathComponent(cover ? "duxiu/cover/api/cover" : "duxiu/bookmark/api/bookmark"),cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:20)
        request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let payload=cover ? ["ssid":ssid,"size":"lg","channel":"duxiu"] : ["ssid":ssid]
        request.httpBody=try JSONSerialization.data(withJSONObject:payload);return request
    }
    static func directoryText(_ input:String)->String {
        let lines=input.replacingOccurrences(of:"\u{feff}",with:"").components(separatedBy:.newlines)
        let converted=lines.map {line -> String in
            let parts=line.components(separatedBy:"|")
            guard parts.count>=5,let type=Int(parts[4]),(0...8).contains(type),let number=Int(parts[2]) else{return line}
            let path=parts[1],level=max(0,path.count/2-1)
            if type == 0,number == 0 {return String(repeating:"\t",count:min(32,level))+parts[0]}
            guard type>0 else {return line}
            let prefix=["cov","bok","leg","fow","!","","att","bac"][type-1]
            return String(repeating:"\t",count:min(32,level))+parts[0]+"\t"+prefix+parts[2]
        }.joined(separator:"\n")
        return ContentsOCRText.prepare(converted)
    }
}
/// Queries occur only on a button press. Results remain reference material until explicitly imported/saved.
final class OnlineReferences: NSObject,NSWindowDelegate {
    let window=ChineseWindow(contentRect:NSRect(x:0,y:0,width:820,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    let ssid=NSTextField(),text=ChineseTextView(),image=NSImageView(),status=NSTextField(wrappingLabelWithString:""),quota=NSTextField(labelWithString:"")
    let bookmarkButton=NSButton(title:"查询目录",target:nil,action:nil),coverButton=NSButton(title:"查询封面",target:nil,action:nil),adopt=NSButton(title:"追加到目录草稿",target:nil,action:nil)
    private var task:Task<Void,Never>?,coverData:Data?,coverSSID:String?,directorySSID:String?,closed=false
    private let referenceSplit=NSSplitView()
    private let session=URLSession(configuration:.ephemeral),sourceSSID:String
    var onDirectory:((String)->Bool)?,onClosed:(()->Void)?
    init(ssid initial:String) {
        sourceSSID=initial;super.init();ssid.stringValue=initial;ssid.placeholderString="8位SS号";ssid.widthAnchor.constraint(equalToConstant:140).isActive=true
        window.title="在线目录与封面";window.identifier = .init("UVZDocumentDialog");window.minSize=NSSize(width:680,height:480);window.isReleasedWhenClosed=false;window.delegate=self
        for (button,action) in [(bookmarkButton,#selector(fetchDirectory)),(coverButton,#selector(fetchCover)),(adopt,#selector(adoptDirectory))] {button.target=self;button.action=action;button.bezelStyle = .rounded}
        let controls=NSStackView(views:[NSTextField(labelWithString:"SS号"),ssid,bookmarkButton,coverButton,NSView(),button("打开来源网站",#selector(openWebsite))]);controls.spacing=8;controls.heightAnchor.constraint(equalToConstant:28).isActive=true
        let explanation=NSTextField(wrappingLabelWithString:"来源：Wenbin Fan 的读秀工具。仅在点击查询时发送SS号，不上传图书。第三方服务有每日IP配额，可能没有对应目录；封面通常是小图，只作参考，不自动替换原书页面。")
        explanation.font = .systemFont(ofSize:12);explanation.textColor = .secondaryLabelColor
        let split=referenceSplit;split.isVertical=true;split.dividerStyle = .thin;split.heightAnchor.constraint(greaterThanOrEqualToConstant:160).isActive=true;split.setContentHuggingPriority(.init(1),for:.vertical)
        let scroll=ocrTextScroll(text,editable:true,font:.monospacedSystemFont(ofSize:13,weight:.regular));scroll.borderType = .bezelBorder;split.addArrangedSubview(scroll)
        image.imageScaling = .scaleProportionallyUpOrDown;image.setAccessibilityLabel("查询返回的封面参考图");split.addArrangedSubview(image)
        status.font = .systemFont(ofSize:12);quota.font = .systemFont(ofSize:11);quota.textColor = .secondaryLabelColor
        let bottom=NSStackView(views:[adopt,button("复制目录",#selector(copyDirectory)),NSView(),button("另存封面…",#selector(saveCover)),button("关闭",#selector(close))]);bottom.spacing=8;bottom.heightAnchor.constraint(equalToConstant:28).isActive=true
        let credit=NSTextField(labelWithAttributedString:NSAttributedString(string:"wbfan.site/duxiu",attributes:[.link:URL(string:"https://wbfan.site/duxiu/")!]));credit.allowsEditingTextAttributes=true;credit.isSelectable=true;credit.font = .systemFont(ofSize:11)
        let root=NSStackView(views:[controls,explanation,split,status,quota,credit,bottom]);root.orientation = .vertical;root.distribution = .fill;root.alignment = .leading;root.spacing=12;root.translatesAutoresizingMaskIntoConstraints=false;let host=NSView();window.contentView=host;host.addSubview(root)
        for v in [controls,explanation,split,status,quota,bottom] {v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true;if v !== split {v.setContentHuggingPriority(.required,for:.vertical)}}
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:host.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:host.bottomAnchor,constant:-16)])
        status.stringValue="查询结果可核对后导入目录草稿；只有在目录编辑器保存后才改动图书。";adopt.isEnabled=false
    }
    private func button(_ title:String,_ action:Selector)->NSButton {let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;return b}
    func show() {adopt.isHidden=onDirectory == nil;window.center();window.makeKeyAndOrderFront(nil);window.contentView?.layoutSubtreeIfNeeded();referenceSplit.adjustSubviews();referenceSplit.setPosition(max(300,window.contentView!.bounds.width*0.63),ofDividerAt:0)}
    @objc func openWebsite() {NSWorkspace.shared.open(URL(string:"https://wbfan.site/duxiu/")!)}
    @objc func fetchDirectory() {fetch(cover:false)}
    @objc func fetchCover() {fetch(cover:true)}
    private func fetch(cover:Bool) {
        let value=ssid.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        do {
            let request=try OnlineReferenceClient.request(ssid:value,cover:cover);task?.cancel();bookmarkButton.isEnabled=false;coverButton.isEnabled=false;adopt.isEnabled=false;ssid.isEnabled=false;if cover {coverData=nil;coverSSID=nil;image.image=nil} else {text.string="";directorySSID=nil};status.stringValue=cover ? "正在查询封面…" : "正在查询目录…"
            task=Task { [weak self] in
                guard let self else{return}
                do {
                    let (data,response)=try await session.data(for:request);try Task.checkCancellation()
                    guard let http=response as? HTTPURLResponse else {throw ReaderFailure("网络响应无法读取。")}
                    let reply=try OnlineReferenceClient.parse(data,ssid:value)
                    await MainActor.run {if let remaining=reply.remaining,let limit=reply.limit {self.quota.stringValue="今日剩余\(remaining)/\(limit)次 · 网站说明北京时间06:00重置"}}
                    if let error=reply.error {throw ReaderFailure(error)}
                    guard (200...299).contains(http.statusCode) else {throw ReaderFailure("外部服务返回HTTP \(http.statusCode)。")}
                    if cover,let url=reply.coverURL {
                        let (bytes,imageResponse)=try await session.data(from:url);try Task.checkCancellation()
                        guard (imageResponse as? HTTPURLResponse)?.statusCode == 200,bytes.count<=8*1024*1024,let source=CGImageSourceCreateWithData(bytes as CFData,nil),let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=p[kCGImagePropertyPixelWidth] as? Int,let h=p[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=10000,h<=10000,w*h<=10_000_000 else {throw ReaderFailure("封面图像无效或超过大小限制。")}
                        await MainActor.run {guard !self.closed else{return};self.coverData=bytes;self.coverSSID=value;self.image.image=NSImage(data:bytes);self.status.stringValue="封面参考图：\(w)×\(h)像素。可另存，不会替换图书中的原始封面。"}
                    } else if let text=reply.text {
                        await MainActor.run {guard !self.closed else{return};self.text.string=OnlineReferenceClient.directoryText(text);self.directorySSID=value;self.adopt.isEnabled=self.onDirectory != nil && (self.sourceSSID.isEmpty || self.sourceSSID == value);self.status.stringValue="目录已获取。请核对标题、层级与正文页号，再导入草稿。"}
                    } else {throw ReaderFailure("未返回可用的目录或封面。")}
                } catch {
                    await MainActor.run {guard !self.closed else{return};self.status.stringValue=error is CancellationError ? "查询已取消" : error.localizedDescription}
                }
                await MainActor.run {self.bookmarkButton.isEnabled=true;self.coverButton.isEnabled=true;self.ssid.isEnabled=true}
            }
        } catch {status.stringValue=error.localizedDescription}
    }
    @objc func adoptDirectory() {guard let directorySSID,(sourceSSID.isEmpty || directorySSID == sourceSSID),!text.string.isEmpty else{return};let imported=onDirectory?(text.string) ?? false;status.stringValue=imported ? "已追加到全部类型的目录草稿，可撤销；请核对后保存。" : "暂时无法追加，请先处理目录编辑器中的提示或重新打开查询窗口。"}
    @objc func copyDirectory() {NSPasteboard.general.clearContents();NSPasteboard.general.setString(text.string,forType:.string)}
    @objc func saveCover() {guard let coverData,let coverSSID else {status.stringValue="请先查询封面。";return};let p=NSSavePanel();p.nameFieldStringValue=coverSSID+"_cover.png";p.begin {[weak self] response in guard let self,response == .OK,let url=p.url else{return};do {try coverData.write(to:url,options:.atomic);self.status.stringValue="参考封面已另存。"}catch {self.status.stringValue=error.localizedDescription}}}
    @objc func close() {closed=true;task?.cancel();session.invalidateAndCancel();window.orderOut(nil);onClosed?()}
    func windowShouldClose(_ sender:NSWindow)->Bool {close();return false}
}
