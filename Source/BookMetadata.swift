import AppKit
import Vision

/// Canonical bibliographic fields; unknown BookInfo keys always survive editing.
enum BookMetadata {
    static let fields = ["ISBN", "书名", "作者", "丛书名", "出版社", "出版日期", "页数", "SS号", "DX号", "摘要"]
    static let aliases = ["書名":"书名", "叢書名":"丛书名", "出版年月":"出版日期", "頁數":"页数", "總頁數":"页数", "內容簡介":"摘要", "年份": "出版日期", "出版时间": "出版日期", "丛书": "丛书名", "总页数": "页数", "内容提要": "摘要", "内容简介": "摘要", "ISBN号": "ISBN", "DXID": "DX号", "SSID": "SS号"]
    static func canonical(_ input: [String: String]) -> [String: String] {
        var output = input
        for (old, key) in aliases.sorted(by: { $0.key < $1.key }) where output[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let value = input[old] { output[key] = value }
        }
        for key in aliases.keys { output.removeValue(forKey: key) }
        if let value = output["出版日期"] { output["出版日期"] = date(value) }
        return output
    }
    static func date(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = captures("^([12][0-9]{3})[年./－-]\\s*(0?[1-9]|1[0-2])(?:月|[./-][0-9]{1,2}日?)?$", text).first,
           let month = Int(match[1]) { return "\(match[0])." + String(format: "%02d", month) }
        return text
    }
    static func captures(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
        }
    }
    /// Fills only truly empty fields. Values already supplied by the user are authoritative.
    static func filling(_ original: [String: String], with candidates: [String: String]) -> [String: String] {
        var result = canonical(original)
        for (key, value) in candidates where result[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.isEmpty { result[key] = value }
        return result
    }
    static func rows(_ metadata: [String: String], title: String) -> [(String, String)] {
        let values = canonical(metadata)
        return fields.map { ($0, values[$0] ?? "") } + values.keys.filter { !fields.contains($0) }.sorted().map { ($0, values[$0]!) }
    }
}

enum FilenameTemplate {
    static let presets = ["{书名}_{作者}_{出版社}_{出版日期}_{SS号}", "【{丛书名}】{书名}_{作者}_{出版社}_{出版日期}_{SS号}"]
    static func render(_ template: String, metadata: [String: String]) throws -> String {
        let regex = try NSRegularExpression(pattern: "\\{([^{}]+)\\}")
        let source = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: source.length))
        guard !template.isEmpty, template.count <= 2000 else { throw ReaderFailure("请填写命名格式（最多 2000 字符）。") }
        var result = template
        for match in matches.reversed() {
            let key = source.substring(with: match.range(at: 1))
            guard BookMetadata.fields.contains(key) || key == "年份" else { throw ReaderFailure("未知命名字段：{\(key)}。请使用下方列出的字段。") }
            let value = key == "年份" ? String(metadata["出版日期", default: ""].prefix(4)) : metadata[key, default: ""]
            result = (result as NSString).replacingCharacters(in: match.range, with: FilenameDraft.clean(value))
        }
        guard !result.contains("{"), !result.contains("}") else { throw ReaderFailure("命名格式中的花括号未配对。") }
        // Omit empty optional fields and their common separators without stripping literal words.
        for pair in ["【】", "[]", "（）", "()"] { result = result.replacingOccurrences(of: pair, with: "") }
        result = result.replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_ \t"))
        guard !result.isEmpty, !result.contains("/"), !result.contains(":"), result.rangeOfCharacter(from: .controlCharacters) == nil else { throw ReaderFailure("生成的文件名为空或包含非法字符，请修改格式。") }
        return result
    }
}

struct MetadataRecognition {
    var values: [String: String]
    var text: String
    var pages: [Int]
    var evidence: [NamingEvidence] = []
    var notes: [String] = []
}

/// Local OCR with conservative, evidence-based extraction. No model/network dependency.
enum CopyrightMetadata {
    static func extract(_ text: String) -> [String: String] {
        BibliographicExtraction.analyse(text).values
    }
    static func validISBN(_ value: String) -> Bool {
        let values = value.map { $0 == "X" ? 10 : $0.wholeNumberValue ?? -1 }
        if values.count == 13, values.allSatisfy({ (0...9).contains($0) }) { return values.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) } % 10 == 0 }
        if values.count == 10, values.dropLast().allSatisfy({ (0...9).contains($0) }), (0...10).contains(values[9]) { return values.enumerated().reduce(0) { $0 + $1.element * (10 - $1.offset) } % 11 == 0 }
        return false
    }
    static func recognize(_ image: CGImage) throws -> String {
        try TextRecognition.lines(image).map(\.text).joined(separator:"\n")
    }
    static func candidates(_ book: BookArchive, currentPage: Int? = nil) -> [Int] {
        if let currentPage { return [min(book.pages.count - 1, max(0, currentPage))] }
        if book.url.pathExtension.lowercased() == "pdf" {
            return Array(Set(book.pages.indices.prefix(10)).union(book.pages.indices.suffix(10))).sorted()
        }
        let copyright = book.pages.indices.filter { book.pages[$0].key.group == 2 }
        if !copyright.isEmpty { return Array(copyright.prefix(4)) }
        return Array(0..<min(6, book.pages.count))
    }
    static func recognize(book: BookArchive, currentPage: Int? = nil, cached: [Int: String] = [:], options: RecognitionOptions = .saved) throws -> MetadataRecognition {
        var pages = candidates(book, currentPage: currentPage)
        if currentPage == nil {
            for group in [0,1] { if let index = book.pages.firstIndex(where:{$0.key.group == group}),!pages.contains(index) { pages.append(index) } }
        }
        var text = "", evidence: [NamingEvidence] = [], notes: [String] = [], visited: [Int] = []
        for page in pages {
            let image = try autoreleasepool { try book.pageImage(at:page) }
            let lines = try BibliographicOCR.lines(image,options:options)
            if lines.contains(where:{$0.confidence<0.35}) { notes.append("物理第\(page+1)页部分文字识别不清，请核对原图") }
            let fresh = lines.map(\.text).joined(separator:"\n")
            let recognized = fresh.isEmpty ? cached[page] ?? "" : fresh
            let role = book.usesPDGNumbering ? (book.pages[page].key.group == 0 ? "封面" : book.pages[page].key.group == 1 ? "书名页" : "版权页") : BibliographicExtraction.isCopyright(recognized) ? "版权页" : page == 0 ? "封面" : "书名页"
            visited.append(page+1); text += "—— \(role) · 物理第 \(page+1) 页 ——\n"+recognized+"\n"
            if role == "版权页" || currentPage != nil {
                let analysis = BibliographicExtraction.analyse(recognized)
                notes += analysis.notes
                evidence += analysis.evidence.map { NamingEvidence(field:$0.field,value:$0.value,source:$0.source,page:page+1,inferred:$0.inferred) }
            } else {
                let (values,inferred) = BatchNaming.pageValues(lines,role:role,anchors:book.metadata)
                evidence += values.map { NamingEvidence(field:$0.key,value:$0.value,source:role,page:page+1,inferred:inferred.contains($0.key)) }
            }
        }
        let ranking = ["CIP著录":0,"出版信息":1,"书名页":2,"封面":3]
        evidence = evidence.enumerated().sorted { a,b in
            let x = ranking[a.element.source,default:4],y = ranking[b.element.source,default:4]
            return x != y ? x<y : a.offset<b.offset
        }.map(\.element)
        let proposal = BatchNaming.merge(original:[:],evidence:evidence,notes:notes)
        for key in BookMetadata.fields where evidence.contains(where:{$0.field == key && !BatchNaming.equivalent(key,$0.value,proposal.metadata[key,default:""])}) { notes.append(key+"的来源信息有差异，请逐项核对") }
        let original = BookMetadata.canonical(book.metadata)
        for key in BookMetadata.fields where !original[key,default:""].isEmpty && !proposal.metadata[key,default:""].isEmpty && !BatchNaming.equivalent(key,original[key]!,proposal.metadata[key]!) { notes.append(key+"与原有图书信息不同，已参与自动比对") }
        let stored = original.filter { BookMetadata.fields.contains($0.key) && !$0.value.isEmpty }.map { NamingEvidence(field:$0.key,value:$0.value,source:book.usesPDGNumbering ? "BookInfo.dat" : "文档信息",page:nil,inferred:false) }
        return MetadataRecognition(values:MetadataResolver.select(original:original,evidence:stored+evidence).values,text:text,pages:visited,evidence:stored+evidence,notes:Array(Set(notes)).sorted())
    }
}
