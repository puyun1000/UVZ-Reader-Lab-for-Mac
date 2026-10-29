import AppKit
import PDFKit
import CryptoKit
import Darwin

struct ConversionOptions: Codable {
    var naming = "source"
    var style = NamingPreferences.automatic
    var outputDirectory: String? = nil
    var writeMetadata = true
    var writeBookmarks = true
    var skipBadPages = false
    var fallbackDPI: Double = 300
}
struct ConversionProgress { let phase: String,completed: Int,total: Int }
struct ConversionResult: Codable {
    let output: String
    let sourcePages: Int,outputPages: Int,jpegPassThrough: Int,losslessPages: Int,fallbackDPIPages: Int
    let skipped: [Int]
    let notes: [String]
    let elapsedSeconds: Double
    var partial: Bool { !skipped.isEmpty }
}
struct ConversionCancelled: Error {}

enum ExportNaming {
    static func stem(_ source: URL,metadata: [String:String],options: ConversionOptions) throws -> String {
        let folder = (try? source.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true
        let sourceName = folder ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        switch options.naming {
        case "source":return sourceName
        case "template":return try FilenameTemplate.render(NamingPreferences.pattern(options.style,metadata:metadata),metadata:metadata)
        case "title":return FilenameDraft.clean(metadata["书名",default:sourceName])
        default:throw ReaderFailure("未知输出命名方式。")
        }
    }
    static func destination(_ source: URL,stem: String,options: ConversionOptions,partial: Bool = false) throws -> URL {
        let stem = stem.trimmingCharacters(in:.whitespacesAndNewlines),name = stem+(partial ? ".partial" : "")+".pdf"
        guard !stem.isEmpty,stem != ".",stem != "..",!stem.contains("/"),!stem.contains(":"),stem.rangeOfCharacter(from:.controlCharacters) == nil,name.lengthOfBytes(using:.utf8)<=255 else {throw ReaderFailure("目标名称为空、过长或包含非法字符。")}
        let folder = options.outputDirectory.map {URL(fileURLWithPath:$0,isDirectory:true)} ?? source.deletingLastPathComponent()
        let target = folder.appendingPathComponent(name)
        guard BatchNaming.pathKey(target) != BatchNaming.pathKey(source) else {throw ReaderFailure("PDF来源与目标相同；请选其他输出目录或修改目标名。")}
        return target
    }
}
enum ConversionService {
    static func preflight(_ source: URL,stem: String,options: ConversionOptions) throws -> URL {
        guard options.fallbackDPI.isFinite,(36...1200).contains(options.fallbackDPI) else {throw ReaderFailure("回退DPI应在36—1200之间。")}
        let target = try ExportNaming.destination(source,stem:stem,options:options),folder = target.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath:folder.path),FileManager.default.isWritableFile(atPath:folder.path) else {throw ReaderFailure("输出文件夹不存在或不可写。")}
        let files = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
        for partial in options.skipBadPages ? [false,true] : [false] {
            let candidate = try ExportNaming.destination(source,stem:stem,options:options,partial:partial)
            guard !files.contains(where:{BatchNaming.pathKey($0) == BatchNaming.pathKey(candidate)}) else {throw ReaderFailure("目标已存在，未覆盖："+candidate.lastPathComponent)}
        }
        return target
    }
    static func convert(_ source: URL,stem: String,options: ConversionOptions,cancelled: () -> Bool = {false},progress: (ConversionProgress) -> Void = {_ in}) throws -> ConversionResult {
        let began = Date(),target = try preflight(source,stem:stem,options:options),fm = FileManager.default
        func check() throws { if cancelled() {throw ConversionCancelled()} }
        try check();progress(.init(phase:"检查来源",completed:0,total:0))
        let fingerprint = try BatchNaming.fingerprint(source),book = try BookArchive(url:source)
        let metadata = FilenameDraft(book:book).values
        let stage = target.deletingLastPathComponent().appendingPathComponent(".uvz-convert-"+UUID().uuidString+".pdf")
        defer {try? fm.removeItem(at:stage)}
        var map: [Int:Int] = [:],skipped: [Int] = [],notes: [String] = [],jpeg = 0,lossless = 0,fallback = 0
        if let notice = book.contentsNotice {notes.append(notice)}
        if source.pathExtension.lowercased() == "pdf" {
            try check();progress(.init(phase:"保留PDF原文",completed:0,total:book.pages.count))
            if options.writeMetadata || options.writeBookmarks,PDFDocument(url:source)?.isEncrypted == true {throw ReaderFailure("加密PDF暂不支持改写信息或书签。来源不会修改。")}
            try fm.copyItem(at:source,to:stage)
            map = Dictionary(uniqueKeysWithValues:book.pages.indices.map {($0,$0)})
            let chapters=options.writeBookmarks && book.hasExportContentsOverride ? book.chapters : nil
            if options.writeMetadata || chapters != nil {try finishNative(stage,metadata:options.writeMetadata ? metadata : nil,chapters:chapters,map:map)}
        } else if book.exportNeedsPDFContext {
            var bounds = CGRect(x:0,y:0,width:612,height:792)
            guard let context = CGContext(stage as CFURL,mediaBox:&bounds,nil) else {throw ReaderFailure("无法创建PDF文档上下文。")}
            var didClose = false;defer {if !didClose {context.closePDF()}}
            for index in book.pages.indices {
                try check()
                do {
                    try autoreleasepool {
                        if let data = try book.exportData(at:index),data.starts(with:Data("%PDF-".utf8)),let provider = CGDataProvider(data:data as CFData),let pdf = CGPDFDocument(provider),let page = pdf.page(at:(book.pages[index].pdfPage ?? 0)+1) {
                            let sourceRect = page.getBoxRect(.mediaBox),rotated = abs(page.rotationAngle)%180 == 90
                            var rect = CGRect(origin:.zero,size:rotated ? CGSize(width:sourceRect.height,height:sourceRect.width) : sourceRect.size)
                            guard rect.width>0,rect.height>0,rect.width<30000,rect.height<30000 else {throw ReaderFailure("文本页尺寸异常。")}
                            context.beginPDFPage([kCGPDFContextMediaBox as String:NSData(bytes:&rect,length:MemoryLayout<CGRect>.size)] as CFDictionary)
                            context.saveGState();context.concatenate(page.getDrawingTransform(.mediaBox,rect:rect,rotate:0,preserveAspectRatio:true));context.drawPDFPage(page);context.restoreGState();context.endPDFPage()
                        } else {
                            let cg = try book.exportImage(at:index),image = try ExportImage.make(data:try book.exportData(at:index),image:cg,fallbackDPI:options.fallbackDPI,imageIndex:book.exportImageIndex(index),sourceDPI:book.exportDPI(at:index))
                            var rect = CGRect(origin:.zero,size:image.pageSize)
                            context.beginPDFPage([kCGPDFContextMediaBox as String:NSData(bytes:&rect,length:MemoryLayout<CGRect>.size)] as CFDictionary)
                            let m=image.drawingMatrix;context.saveGState();context.concatenate(CGAffineTransform(a:m[0],b:m[1],c:m[2],d:m[3],tx:m[4],ty:m[5]));context.draw(cg,in:CGRect(x:0,y:0,width:1,height:1));context.restoreGState();context.endPDFPage();lossless += 1;if image.usedFallbackDPI {fallback += 1}
                        }
                    }
                    map[index] = map.count
                } catch {if !options.skipBadPages {throw ReaderFailure("物理第\(index+1)页（\(book.pages[index].name)）："+error.localizedDescription)};skipped.append(index+1);notes.append("跳过物理第\(index+1)页："+error.localizedDescription)}
                progress(.init(phase:"保留文字与页面",completed:index+1,total:book.pages.count))
            }
            context.closePDF();didClose = true
            guard !map.isEmpty else {throw ReaderFailure("没有可输出的页面。")}
            try finishNative(stage,metadata:options.writeMetadata ? metadata : nil,chapters:options.writeBookmarks ? book.chapters : nil,map:map)
            notes.append("含文本PDG时采用PDF绘制路径，保留文字与矢量；此路径不承诺JPEG原始字节直通。")
        } else {
            let writer = try PDFExportWriter(stage)
            for index in book.pages.indices {
                try check()
                let decoded = Result {try autoreleasepool {try ExportImage.make(data:book.exportData(at:index),image:book.exportImage(at:index),fallbackDPI:options.fallbackDPI,imageIndex:book.exportImageIndex(index),sourceDPI:book.exportDPI(at:index))}}
                switch decoded {
                case .success(let image):
                    // Disk/write failures must abort, even when bad source pages may be skipped.
                    try writer.append(image);map[index]=map.count
                    if image.jpeg {jpeg += 1} else {lossless += 1};if image.usedFallbackDPI {fallback += 1}
                case .failure(let error):
                    if !options.skipBadPages {throw ReaderFailure("物理第\(index+1)页（\(book.pages[index].name)）："+error.localizedDescription)}
                    skipped.append(index+1);notes.append("跳过物理第\(index+1)页（\(book.pages[index].name)）："+error.localizedDescription)
                }
                progress(.init(phase:"处理页面",completed:index+1,total:book.pages.count))
            }
            try check();progress(.init(phase:"写入目录与信息",completed:book.pages.count,total:book.pages.count))
            try writer.finish(metadata:options.writeMetadata ? metadata : [:],chapters:options.writeBookmarks ? book.chapters : [],map:map)
        }
        try check();progress(.init(phase:"校验PDF",completed:book.pages.count,total:book.pages.count))
        try autoreleasepool {
            guard let pdf = PDFDocument(url:stage),!pdf.isLocked,pdf.pageCount == map.count else {throw ReaderFailure("PDF页数回读校验失败，未提交输出。")}
            if options.writeMetadata {let values = NativeDocumentMetadata.pdfValues(pdf);guard metadata.allSatisfy({values[$0.key] == $0.value}) else {throw ReaderFailure("PDF书目信息回读校验失败。")}}
        }
        if options.writeBookmarks {
            let missing = book.chapters.filter {$0.pageIndex>=0 && map[$0.pageIndex] == nil}
            if !missing.isEmpty {notes.append("\(missing.count)条目录的页面被跳过，保留标题但不写入错误跳转。")}
        }
        if fallback>0 {notes.append("\(fallback)页没有可用DPI，按\(Int(options.fallbackDPI))DPI确定纸张尺寸；图像像素不缩放。")}
        try check();guard try BatchNaming.fingerprint(source) == fingerprint else {throw ReaderFailure("来源在转换期间发生变化，未提交输出。")}
        let destination = try ExportNaming.destination(source,stem:stem,options:options,partial:!skipped.isEmpty)
        guard Darwin.renamex_np(stage.path,destination.path,UInt32(RENAME_EXCL)) == 0 else {throw ReaderFailure("无法提交PDF（不会覆盖已有文件）："+String(cString:strerror(errno)))}
        progress(.init(phase:skipped.isEmpty ? "完成" : "部分完成",completed:book.pages.count,total:book.pages.count))
        return .init(output:destination.path,sourcePages:book.pages.count,outputPages:map.count,jpegPassThrough:jpeg,losslessPages:lossless,fallbackDPIPages:fallback,skipped:skipped,notes:notes,elapsedSeconds:Date().timeIntervalSince(began))
    }
    private static func finishNative(_ url: URL,metadata: [String:String]?,chapters: [BookChapter]?,map: [Int:Int]) throws {
        guard var pdf = PDFDocument(url:url) else {throw ReaderFailure("PDF无法回读。")}
        var attributes = pdf.documentAttributes ?? [:]
        if let metadata {
            for (key,name) in NativeDocumentMetadata.mapping {if let value=metadata[key] {attributes[PDFDocumentAttribute(rawValue:name)]=value}}
            attributes[PDFDocumentAttribute(rawValue:NativeDocumentMetadata.key)] = String(decoding:try JSONEncoder().encode(metadata),as:UTF8.self)
        }
        let outlined=url.deletingLastPathComponent().appendingPathComponent(".uvz-outline-"+UUID().uuidString+".pdf")
        defer {try? FileManager.default.removeItem(at:outlined)}
        if let chapters {
            // PDFKit on macOS 27 otherwise writes the old catalog and silently drops a new outline.
            // Reinsert the same page to make the document mutable; page content and annotations remain intact.
            if let first=pdf.page(at:0) {pdf.removePage(at:0);pdf.insert(first,at:0)}
            let root = PDFOutline();var stack: [PDFOutline] = []
            for chapter in chapters {
                let node = PDFOutline();node.label = chapter.title
                if let index = map[chapter.pageIndex],let page = pdf.page(at:index) {node.destination = PDFDestination(page:page,at:CGPoint(x:0,y:page.bounds(for:.mediaBox).height))}
                while stack.count>max(0,chapter.level) {stack.removeLast()};let parent = stack.last ?? root;parent.insertChild(node,at:parent.numberOfChildren);stack.append(node)
            }
            pdf.outlineRoot = root
            guard pdf.write(to:outlined),let reopened=PDFDocument(url:outlined) else {throw ReaderFailure("PDF目录写入失败。")}
            pdf=reopened
        }
        // A mutable-page write drops custom Info keys. Reopen before assigning attributes,
        // so the second write preserves both the serialized outline and the complete metadata.
        let staged = url.deletingLastPathComponent().appendingPathComponent(".uvz-native-"+UUID().uuidString+".pdf");defer {try? FileManager.default.removeItem(at:staged)}
        try NativeDocumentMetadata.savePDF(pdf,attributes:attributes,from:chapters == nil ? url : outlined,to:staged,expected:metadata)
        if let chapters,let check=PDFDocument(url:staged) {
            var actual:[(String,Int?)]=[]
            func visit(_ parent:PDFOutline) {for i in 0..<parent.numberOfChildren {if let node=parent.child(at:i) {actual.append((node.label ?? "",node.destination?.page.map {check.index(for:$0)}));visit(node)}}}
            if let root=check.outlineRoot {visit(root)}
            guard actual.count == chapters.count,zip(actual,chapters).allSatisfy({$0.0.0 == $0.1.title && $0.0.1 == map[$0.1.pageIndex]}) else {throw ReaderFailure("PDF书签回读校验失败，未提交输出。")}
        }
        guard Darwin.rename(staged.path,url.path) == 0 else {throw ReaderFailure("PDF信息与书签提交失败。")}
    }
}
