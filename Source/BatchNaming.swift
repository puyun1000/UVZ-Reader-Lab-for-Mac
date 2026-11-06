import AppKit
import CryptoKit
import PDFKit

struct NamingEvidence: Codable, Equatable {
    let field: String
    let value: String
    let source: String
    let page: Int?
    let inferred: Bool
}
struct NamingPage: Codable {
    let physical: Int
    let file: String
    let role: String
    let text: String
    let textLayer: Bool
}
struct NamingProposal: Encodable {
    var metadata: [String:String]
    let evidence: [NamingEvidence]
    let pages: [NamingPage]
    let notes: [String]
    let originalMetadata: [String:String]
    let fingerprint: String
    let selection: MetadataSelection
    private enum CodingKeys: String, CodingKey {
        case metadata, evidence, pages, notes, originalMetadata, fingerprint
    }
    var candidates: [String] {
        FilenameTemplate.presets.map { (try? FilenameTemplate.render($0,metadata:metadata)) ?? "" }
    }
    var reviewReasons: [String] {
        var reasons = notes
        for key in ["书名","作者","出版社","出版日期","SS号"] where metadata[key,default:""].trimmingCharacters(in:.whitespaces).isEmpty { reasons.append("缺少"+key) }
        if metadata["出版日期",default:""].count == 4 { reasons.append("出版月份未确定") }
        if let date = metadata["出版日期"],!date.isEmpty,date.range(of:"^[12][0-9]{3}(?:\\.(?:0[1-9]|1[0-2]))?$",options:.regularExpression) == nil { reasons.append("出版日期格式待核对") }
        if let ss = metadata["SS号"],!ss.isEmpty,ss.range(of:"^[0-9]{8}$",options:.regularExpression) == nil { reasons.append("SS号格式待核对") }
        for key in selection.uncertain { reasons.append(key+"来源待核对") }
        if let isbn = metadata["ISBN"],!isbn.isEmpty,!CopyrightMetadata.validISBN(isbn.filter { $0.isNumber || $0 == "X" }.uppercased()) { reasons.append("ISBN校验未通过") }
        return Array(Set(reasons)).sorted()
    }
    var suggestedName: String { (try? FilenameTemplate.render(NamingPreferences.pattern(NamingPreferences.automatic,metadata:metadata),metadata:metadata)) ?? "" }
    func fieldStatus(_ key: String) -> String {
        guard !metadata[key,default:""].isEmpty else { return "未确定" }
        if selection.uncertain.contains(key) { return "待核对" }
        if !BatchNaming.equivalent(key,metadata[key,default:""],selection.values[key,default:""]) { return "手工采用" }
        if !originalMetadata[key,default:""].isEmpty && !BatchNaming.equivalent(key,metadata[key]!,originalMetadata[key]!) { return "已自动替换" }
        return evidence.filter { $0.field == key && MetadataResolver.credible($0) && BatchNaming.equivalent(key,$0.value,metadata[key]!) }.count>=2 ? "多来源一致" : "已选取"
    }

}
final class BatchNamingItem {
    let originalURL: URL
    var url: URL
    var proposal: NamingProposal? {
        didSet { reviewReasons = proposal?.reviewReasons ?? [] }
    }
    private(set) var reviewReasons: [String] = []
    var included = false, reviewed = false
    var styleID = NamingPreferences.automatic
    var customName: String?
    var error: String?
    var outcome: String?
    var analysing = false
    init(_ url: URL, styleID: String = NamingPreferences.automatic) { self.originalURL = url; self.url = url; self.styleID = styleID }
    var stem: String { customName ?? proposal.flatMap { try? FilenameTemplate.render(NamingPreferences.pattern(styleID,metadata:$0.metadata),metadata:$0.metadata) } ?? "" }
    var displayName: String { stem + (url.pathExtension.isEmpty || ((try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true) ? "" : "."+url.pathExtension) }
    var status: String {
        if let outcome { return outcome }; if analysing { return "正在分析" }; if let error { return error }
        guard proposal != nil else { return "待分析" }
        return reviewReasons.isEmpty ? "可用建议" : reviewed ? "已人工核对" : "待核对 \(reviewReasons.count) 项"
    }
}
struct BatchNameRequest: Codable {
    let path: String
    let stem: String
    let metadata: [String:String]?
    let fingerprint: String
}
struct BatchNameOutcome: Codable {
    let original: String
    let destination: String?
    let error: String?
}
enum BatchNaming {
    static let bookExtensions = Set(["zip","uvz","pdf","djvu","djv","tif","tiff"])
    static func equivalent(_ field: String,_ a: String,_ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return a == b }
        if field == "出版日期" {
            let x = BookMetadata.date(a), y = BookMetadata.date(b)
            return x == y || (x.count == 4 && y.hasPrefix(x+".")) || (y.count == 4 && x.hasPrefix(y+"."))
        }
        func norm(_ text: String) -> String {
            var raw = text.precomposedStringWithCompatibilityMapping
            if field == "作者" { raw = raw.replacingOccurrences(of:"(?:編著|编著|主編|主编|編校|编校|校注|選編|选编|著|作|編|编|譯|译)(?=[ ;；、,，]|$)",with:"",options:.regularExpression) }
            return PageInspection.normalized(raw)
        }
        return norm(a) == norm(b)
    }
    static func filenameValues(_ url: URL) -> [String:String] {
        let directory = (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true
        var name = directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var values: [String:String] = [:]
        if name.hasPrefix("【"),let end = name.firstIndex(of:"】") {
            values["丛书名"] = String(name[name.index(after:name.startIndex)..<end]); name = String(name[name.index(after:end)...])
        }
        var parts = name.components(separatedBy:"_")
        if let last = parts.last,last.range(of:"^[0-9]{8}$",options:.regularExpression) != nil { values["SS号"] = parts.removeLast() }
        if let last = parts.last,last.range(of:"^[12][0-9]{3}(?:[.年/-](?:0?[1-9]|1[0-2])月?)?$",options:.regularExpression) != nil { values["出版日期"] = BookMetadata.date(parts.removeLast()) }
        if let last = parts.last,last.hasSuffix("出版社") { values["出版社"] = parts.removeLast() }
        if parts.count >= 2, values["出版社"] != nil,values["出版日期"] != nil { values["作者"] = parts.removeLast() }
        if !parts.joined(separator:"_").isEmpty { values["书名"] = parts.joined(separator:"_").trimmingCharacters(in:.whitespaces) }
        return values
    }
    static func discover(_ root: URL, recursive: Bool = false, cancelled: () -> Bool = { false }) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        func visit(_ folder: URL) throws {
            if cancelled() { return }
            let urls = try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isPackageKey],options:[.skipsHiddenFiles]).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if urls.contains(where:{ $0.pathExtension.lowercased() == "pdg" }) { result.append(folder); return }
            for file in urls {
                if cancelled() { return }
                let attributes = try file.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isPackageKey])
                guard attributes.isSymbolicLink != true,!file.lastPathComponent.lowercased().contains(".backup-"),!file.lastPathComponent.lowercased().hasSuffix(".uvzmeta") else { continue }
                if attributes.isDirectory == true {
                    guard attributes.isPackage != true else { continue }
                    // Direct child PDG folders are books even when recursive library search is off.
                    let children = try fm.contentsOfDirectory(at:file,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])
                    if children.contains(where:{$0.pathExtension.lowercased() == "pdg"}) { result.append(file) }
                    else if recursive { try visit(file) }
                } else if bookExtensions.contains(file.pathExtension.lowercased()) { result.append(file) }
                guard result.count <= 20000 else { throw ReaderFailure("文件夹内图书超过20000项，请分批处理。") }
            }
        }
        try visit(root.standardizedFileURL); return result
    }
    /// Stream fingerprints so a library scan retains neither page data nor open books.
    static func fingerprint(_ url: URL, cancelled: () -> Bool = { false }) throws -> String {
        let fm = FileManager.default
        var hash = SHA256()
        func feed(_ text: String) { hash.update(data:Data(text.utf8)); hash.update(data:Data([0])) }
        func file(_ file: URL) throws {
            let attrs = try file.resourceValues(forKeys:[.isSymbolicLinkKey])
            guard attrs.isSymbolicLink != true else { throw ReaderFailure("不处理符号链接图书或信息文件。") }
            let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
            while let data = try handle.read(upToCount:1024*1024),!data.isEmpty {
                if cancelled() { throw ReaderFailure("已停止分析。") }
                hash.update(data:data)
            }
        }
        func folder(_ root: URL) throws {
            guard let enumerator = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]) else { throw ReaderFailure("无法检查信息文件夹。") }
            let files = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
            for item in files {
                let attr = try item.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                guard attr.isSymbolicLink != true else { throw ReaderFailure("不处理包含符号链接的图书文件夹。") }
                if attr.isRegularFile == true { feed(String(item.path.dropFirst(root.path.count))); try file(item) }
            }
        }
        let attributes = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true else { throw ReaderFailure("不处理符号链接图书。") }
        if attributes.isDirectory == true { try folder(url) }
        else {
            try file(url); feed("companion")
            let companion = URL(fileURLWithPath:url.path+".uvzmeta")
            if fm.fileExists(atPath:companion.path) { try folder(companion) }
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func merge(original: [String:String], evidence: [NamingEvidence], pages: [NamingPage] = [], notes: [String] = [], fingerprint: String = "") -> NamingProposal {
        let original = BookMetadata.canonical(original)
        let selection = MetadataResolver.select(original:original,evidence:evidence)
        return NamingProposal(metadata:selection.values,evidence:evidence,pages:pages,notes:notes,originalMetadata:original,fingerprint:fingerprint,selection:selection)
    }
    static func pageValues(_ lines: [PageInspection.EvidenceLine], role: String, anchors: [String:String]) -> ([String:String],Set<String>) {
        let text = TextRecognition.ordered(lines).map(\.text).joined(separator:"\n")
        var labelled = text
        for (old,new) in [("書名","书名"),("叢書名","丛书名"),("出版時間","出版时间"),("頁數","页数"),("總頁數","总页数"),("圖書在版編目","图书在版编目"),("內容提要","内容提要")] { labelled = labelled.replacingOccurrences(of:old,with:new) }
        var values = role.contains("版权页") ? [:] : CopyrightMetadata.extract(labelled), inferred = Set<String>()
        // Cross-check known titles without guessing from small publisher or editorial credits.
        for key in ["书名","丛书名","作者","出版社"] where values[key] == nil {
            if let anchor = anchors[key],!anchor.isEmpty,lines.contains(where:{ line in
                let value = PageInspection.normalized(line.text), known = PageInspection.normalized(anchor)
                if key == "作者" { return role != "版权页" && equivalent(key,line.text,anchor) && !["责任编辑","责任校对","封面设计","版式设计"].contains(where:{value.hasPrefix($0)}) }
                return value == known
            }) { values[key] = anchor }
        }
        if values["作者"] == nil {
            for line in lines.sorted(by:{$0.box.midY > $1.box.midY}) {
                let value = line.text.trimmingCharacters(in:.whitespaces)
                guard !["责任编辑","责任校对","封面设计","版式设计","编辑","出版"].contains(where:{PageInspection.normalized(value).hasPrefix($0)}) else { continue }
                if value.range(of:"^[\\p{Han}A-Za-z· 、，；;（）()]{2,60}(?:编著|主编|编校|选编|校注|編著|主編|編校|選編|著|作|译|譯)$",options:.regularExpression) != nil { values["作者"] = value; inferred.insert("作者"); break }
            }
        }
        if values["书名"] == nil && role != "版权页" {
            let candidates = lines.filter { line in
                let value = line.text.trimmingCharacters(in:.whitespaces)
                return value.count >= 2 && value.count <= 100 && (line.vertical ? line.box.width : line.box.height) >= 0.018 && line.confidence >= 0.1 &&
                    !value.contains("出版社") && !value.contains("出版发行") && !value.contains("ISBN") && !value.hasSuffix("文库") && !value.hasSuffix("丛书") &&
                    value.range(of:"(?:著|主编|编著|译|编校|选编|校注)$",options:.regularExpression) == nil &&
                    !["图书在版编目","版权","定价","责任编辑","CIP"].contains(where:{value.contains($0)})
            }.sorted { ($0.vertical ? $0.box.width : $0.box.height) > ($1.vertical ? $1.box.width : $1.box.height) }
            if let main = candidates.first {
                let titleLines = main.vertical ? TextRecognition.ordered(candidates.filter { $0.vertical && $0.box.width>=main.box.width*0.7 && abs($0.box.midY-main.box.midY)<0.2 }) : candidates.filter { abs($0.box.midX-main.box.midX)<0.18 && $0.box.height>=main.box.height*0.7 && abs($0.box.midY-main.box.midY)<0.18 }.sorted { $0.box.midY>$1.box.midY }
                let title = titleLines.map(\.text).joined(separator:main.vertical ? "" : " ")
                if !title.isEmpty { values["书名"] = title; inferred.insert("书名") }
            }
        }
        // Unlabelled cover/title layouts are suggestions even when they produce plausible fields.
        if role != "版权页" { for key in values.keys where !["ISBN","SS号","DX号"].contains(key) { if !equivalent(key,values[key]!,anchors[key,default:""]) { inferred.insert(key) } } }
        return (values,inferred)
    }
    static func analyse(_ url: URL, ocr: Bool = true, forcePDFOCR: Bool = false, options: RecognitionOptions = .saved, cancelled: () -> Bool = { false }, progress: (String) -> Void = { _ in }) throws -> NamingProposal {
        let before = try fingerprint(url,cancelled:cancelled)
        if cancelled() { throw ReaderFailure("已停止分析。") }
        let source = try NamingSource(url)
        let original = BookMetadata.canonical(source.metadata), nameValues = filenameValues(url)
        var evidence = original.filter { BookMetadata.fields.contains($0.key) && !$0.value.isEmpty }.map { NamingEvidence(field:$0.key,value:$0.value,source:source.book?.usesPDGNumbering == true ? "BookInfo.dat" : "文档信息",page:nil,inferred:false) }
        var notes: [String] = [], pages: [NamingPage] = [], selected: [(Int,String)] = []
        var anchors = original
        for (key,value) in nameValues where anchors[key,default:""].isEmpty { anchors[key] = value }
        if ocr {
            let indices = 0..<source.pageCount
            if let book = source.book, book.usesPDGNumbering {
                for (group,role) in [(0,"封面"),(1,"书名页"),(2,"版权页")] {
                    for index in indices.filter({book.pages[$0].key.group == group}).prefix(group == 2 ? 3 : group == 1 ? 2 : 1) { selected.append((index,role)) }
                }
                if book.pages.filter({$0.key.group == 1}).count > 1 { notes.append("多张书名页，需核对卷册或合订信息") }
            }
            if source.pdf != nil {
                selected = Array(Set(indices.prefix(10)).union(indices.suffix(10))).sorted().map { ($0,"待判定页") }
            } else if selected.isEmpty { selected = Array(indices.prefix(6)).map { ($0,"待判定页") } }
            else if !selected.contains(where:{$0.1 == "版权页"}) {
                for index in indices.prefix(8) where !selected.contains(where:{$0.0 == index}) { selected.append((index,"待判定页")) }
            }
            for (index,declaredRole) in selected {
                if cancelled() { throw ReaderFailure("已停止分析。") }
                do {
                    let page = try autoreleasepool {
                        if !forcePDFOCR, options.layout != "vertical", let native = source.nativeText(at:index) {
                            progress("读取文字层（物理\(index+1)）")
                            return (native, [PageInspection.EvidenceLine](), true)
                        }
                        progress("识别\(declaredRole)（物理\(index+1)）")
                        let lines = try BibliographicOCR.lines(source.image(at:index),options:options)
                        return (TextRecognition.ordered(lines).map(\.text).joined(separator:"\n"),lines,false)
                    }
                    let (text,lines,textLayer) = page
                    let copyrightLike = BibliographicExtraction.isCopyright(text)
                    let otherRole = source.pdf != nil && index >= 3 ? "候选页" : index == 0 ? "封面" : "书名页"
                    let role = declaredRole == "待判定页" ? (copyrightLike ? "版权页" : otherRole) : declaredRole == "版权页" && !copyrightLike ? "待确认版权页" : declaredRole
                    if role == "待确认版权页" { notes.append("标记版权页未识别到版权特征，需查看原图") }
                    if text.isEmpty && role != "候选页" { notes.append("物理\(index+1)页未识别到文字") }
                    pages.append(NamingPage(physical:index+1,file:source.pageName(at:index),role:role,text:text,textLayer:textLayer))
                    if role.contains("版权页") {
                        let analysis = BibliographicExtraction.analyse(text)
                        notes += analysis.notes.map { "物理\(index+1)页："+$0 }
                        for value in analysis.evidence { evidence.append(NamingEvidence(field:value.field,value:value.value,source:value.source,page:index+1,inferred:value.inferred)) }
                    } else if role != "候选页" {
                        let (values,inferred) = pageValues(lines,role:role,anchors:anchors)
                        for (key,value) in values where !value.isEmpty { evidence.append(NamingEvidence(field:key,value:value,source:role,page:index+1,inferred:inferred.contains(key))) }
                    }
                    if role != "候选页", lines.contains(where:{$0.confidence < 0.35}) { notes.append("物理\(index+1)页部分文字识别不清，请核对原图") }
                } catch { notes.append("物理\(index+1)页未能识别："+error.localizedDescription) }
            }
            if !pages.contains(where:{$0.role == "版权页"}) { notes.append("候选页面中未确认版权页") }
        } else { notes.append("本次只读取信息，未进行图像交叉核对") }
        // Copyright extraction precedes layout guesses when filling empty fields.
        let ranking = ["BookInfo.dat":0,"文档信息":0,"CIP著录":1,"出版信息":2,"版权页":2,"书名页":3,"封面":4,"文件名":5]
        evidence += nameValues.map { NamingEvidence(field:$0.key,value:$0.value,source:"文件名",page:nil,inferred:true) }
        evidence = evidence.enumerated().sorted { a,b in
            let x = ranking[a.element.source,default:4], y = ranking[b.element.source,default:4]
            return x != y ? x<y : a.offset<b.offset
        }.map(\.element)
        guard try fingerprint(url,cancelled:cancelled) == before else { throw ReaderFailure("图书在分析期间发生变化，请重新分析。") }
        if cancelled() { throw ReaderFailure("已停止分析。") }
        return merge(original:original,evidence:evidence,pages:pages,notes:notes,fingerprint:before)
    }
    static func destination(_ request: BatchNameRequest) throws -> URL {
        let url = URL(fileURLWithPath:request.path), name = request.stem.trimmingCharacters(in:.whitespacesAndNewlines)
        let directory = (try url.resourceValues(forKeys:[.isDirectoryKey])).isDirectory == true
        let full = name + (directory || url.pathExtension.isEmpty ? "" : "."+url.pathExtension)
        guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains(":"),name.rangeOfCharacter(from:.controlCharacters) == nil,full.utf16.count<=255 else { throw ReaderFailure("候选名称为空、过长或含不允许的字符。") }
        return url.deletingLastPathComponent().appendingPathComponent(full,isDirectory:directory)
    }
    static func pathKey(_ url: URL) -> String { url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }
    static func preflight(_ requests: [BatchNameRequest]) -> [Int:String] {
        var errors: [Int:String] = [:], targets: [String:[Int]] = [:], sources: [String:[Int]] = [:]
        for (index,request) in requests.enumerated() {
            do {
                let source = URL(fileURLWithPath:request.path), destination = try destination(request)
                targets[pathKey(destination),default:[]].append(index); sources[pathKey(source),default:[]].append(index)
                if destination.path != source.path,FileManager.default.fileExists(atPath:destination.path) { throw ReaderFailure("目标名称已存在，请核对重复图书或修改名称。") }
                let companion = URL(fileURLWithPath:destination.path+".uvzmeta")
                if destination.path != source.path,FileManager.default.fileExists(atPath:companion.path) { throw ReaderFailure("目标信息文件夹已存在。") }
            } catch { errors[index] = error.localizedDescription }
        }
        for rows in Array(targets.values)+Array(sources.values) where rows.count>1 { for index in rows { errors[index] = "本批次有重复来源或同名目标，请先处理冲突。" } }
        return errors
    }
    static func apply(_ request: BatchNameRequest, backup: Bool = false, preserveDates: Bool = true) throws -> URL {
        let source = URL(fileURLWithPath:request.path), target = try destination(request)
        let errors = preflight([request]); guard errors.isEmpty else { throw ReaderFailure(errors[0]!) }
        guard try fingerprint(source) == request.fingerprint else { throw ReaderFailure("图书或信息文件已发生变化，请重新分析。") }
        let book = try BookArchive(url:source)
        guard try fingerprint(source) == request.fingerprint else { throw ReaderFailure("图书在准备改名时发生变化，请重新分析。") }
        if book.canRename { return try book.updateInformation(stem:request.stem,metadata:request.metadata,backup:backup,preserveDates:preserveDates) }
        let dates = try FileDateRecord(source), fm = FileManager.default
        if let metadata = request.metadata { var draft = BookEditDraft(book:book); draft.metadata = metadata; _ = try draft.encodedInfo() }
        let oldInfo = try LooseBook.find("bookinfo.dat",in:source)
        let infoData = try oldInfo.map { try Data(contentsOf:$0) }, infoDates = try oldInfo.map(FileDateRecord.init)
        if target.path != source.path { try fm.moveItem(at:source,to:target) }
        do {
            if let metadata = request.metadata {
                let updated = try BookArchive(url:target); var draft = BookEditDraft(book:updated); draft.metadata = metadata
                _ = try updated.saveEdits(draft,backup:backup,preserveDates:preserveDates,writeContents:false)
            }
            if preserveDates { try dates.restore(to:target) }
            return target
        } catch {
            if request.metadata != nil {
                let path = target.appendingPathComponent(oldInfo?.lastPathComponent ?? "BookInfo.dat")
                if let infoData { try? infoData.write(to:path,options:.atomic); try? infoDates?.restore(to:path) }
                else { try? fm.removeItem(at:path) }
            }
            if target.path != source.path { try? fm.moveItem(at:target,to:source) }
            throw error
        }
    }
    static func csv(_ items: [BatchNamingItem]) -> String {
        func quote(_ value: String) -> String { "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
        let headers = ["原路径","规范名称建议","最终名称","状态","核对提示"]+BookMetadata.fields
        var rows = [headers.map(quote).joined(separator:",")]
        for item in items {
            let p = item.proposal
            let values = [item.originalURL.path,p?.suggestedName ?? "",item.displayName,item.status,p?.reviewReasons.joined(separator:"；") ?? ""]+BookMetadata.fields.map { p?.metadata[$0] ?? "" }
            rows.append(values.map(quote).joined(separator:","))
        }
        return "\u{feff}"+rows.joined(separator:"\r\n")+"\r\n"
    }
}

/// Batch naming reads PDF metadata and candidate pages without loading the reader's outline or edit snapshot.
struct NamingSource {
    let url: URL
    let book: BookArchive?
    let pdf: PDFDocument?
    let metadata: [String:String]
    var pageCount: Int { pdf?.pageCount ?? book?.pages.count ?? 0 }

    init(_ url: URL) throws {
        self.url = url
        let isDirectory = try url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true
        if !isDirectory && url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url:url), !document.isLocked else {
                throw ReaderFailure("PDF 无法读取或需要密码。")
            }
            guard (1...100_000).contains(document.pageCount) else { throw ReaderFailure("文档为空或页数超过限制。") }
            pdf = document
            book = nil
            var values = NativeDocumentMetadata.pdfValues(document)
            let companion = URL(fileURLWithPath:url.path+".uvzmeta",isDirectory:true)
            if let info = try LooseBook.find("bookinfo.dat",in:companion) {
                values.merge(readBookInfo(try LooseBook.smallData(info))) { _, legacy in legacy }
            }
            metadata = values
        } else {
            let archive = try BookArchive(url:url)
            book = archive
            pdf = nil
            metadata = archive.metadata
        }
    }

    func pageName(at index: Int) -> String {
        book?.pages[index].name ?? url.lastPathComponent
    }

    func image(at index: Int) throws -> CGImage {
        if let pdf { return try PageDecoder.image(pdf,at:index) }
        return try book!.pageImage(at:index)
    }

    func nativeText(at index: Int) -> String? {
        guard let text = pdf?.page(at:index)?.string?.trimmingCharacters(in:.whitespacesAndNewlines),
              !text.isEmpty, text.utf16.count <= 30_000,
              !text.unicodeScalars.contains(where: { $0.value == 0xfffd || $0.properties.generalCategory == .privateUse ||
                  ($0.properties.generalCategory == .control && !CharacterSet.whitespacesAndNewlines.contains($0)) }) else { return nil }
        if BibliographicExtraction.isCopyright(text) {
            let values = BibliographicExtraction.analyse(text).values
            // Require corroborating bibliographic fields before trusting the text layer alone.
            guard values["ISBN"] != nil, values["出版社"] != nil, values["出版日期"] != nil else { return nil }
        } else {
            // Keep OCR for cover/title layout, sparse text layers and potentially scanned colophons.
            guard index >= 3, text.filter(\.isLetter).count >= 150,
                  text.split(whereSeparator:\.isNewline).count >= 4 else { return nil }
        }
        return text
    }
}
