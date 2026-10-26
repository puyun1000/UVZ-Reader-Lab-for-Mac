import Foundation
import PDFKit
import CryptoKit
import Darwin

/// Native metadata only. Temporary files are removed before the operation returns.
enum NativeDocumentMetadata {
    static let key = "UVZReaderLabMetadata"
    static let mapping = ["书名":"Title", "作者":"Author", "出版社":"Publisher", "出版日期":"PublicationDate", "丛书名":"Series", "ISBN":"ISBN", "SS号":"SSID", "DX号":"DXID", "页数":"PageCount", "摘要":"Subject"]
    static func decode(_ text: String) -> [String:String]? { try? JSONDecoder().decode([String:String].self,from:Data(text.utf8)) }
    static func pdfValues(_ document: PDFDocument) -> [String:String] {
        let attributes = document.documentAttributes ?? [:]
        var values = (attributes[PDFDocumentAttribute(rawValue:key)] as? String).flatMap(decode) ?? [:]
        // A standard property edited by another PDF application takes precedence over our extended snapshot.
        for (field,name) in mapping {
            if let value = attributes[PDFDocumentAttribute(rawValue:name)] as? String,!value.isEmpty || values[field] != nil { values[field] = value }
        }
        return values
    }
    static func djvuRaw(_ url: URL) throws -> [String:String] {
        let text = String(decoding:try DjVuTools.run("djvused",["-u","-e","select; print-meta",url.path]),as:UTF8.self)
        var values: [String:String] = [:]
        for line in text.components(separatedBy:.newlines) {
            guard let tab = line.firstIndex(of:"\t") else { continue }
            let name = String(line[..<tab]), quoted = String(line[line.index(after:tab)...])
            // djvused -u uses C escapes for control characters and UTF-8 for all other values.
            guard let value = decodeCString(quoted) else { throw ReaderFailure("DjVu原有信息含无法解析的转义，未覆盖原文件。") }
            values[name] = value
        }
        return values
    }
    private static func decodeCString(_ text: String) -> String? {
        let bytes = Array(text.utf8); guard bytes.first == 34,bytes.last == 34 else { return nil }
        var out: [UInt8] = [],i = 1
        while i<bytes.count-1 {
            let c = bytes[i]; i += 1
            if c != 92 { out.append(c); continue }
            guard i<bytes.count-1 else { return nil };let escaped = bytes[i]; i += 1
            if (48...55).contains(escaped) {
                var value = Int(escaped-48),n = 1
                while n<3,i<bytes.count-1,(48...55).contains(bytes[i]) { value = value*8+Int(bytes[i]-48);i += 1;n += 1 }
                guard value<256 else { return nil };out.append(UInt8(value))
            } else {
                let escapes: [UInt8:UInt8] = [110:10,114:13,116:9,98:8,102:12,118:11,97:7,92:92,34:34,47:47]
                guard let value = escapes[escaped] else { return nil };out.append(value)
            }
        }
        return String(bytes:out,encoding:.utf8)
    }
    static func djvuValues(_ url: URL) throws -> [String:String] {
        let raw = try djvuRaw(url)
        var values: [String:String] = [:]
        if let encoded = raw[key],let data = Data(base64Encoded:encoded),let custom = try? JSONDecoder().decode([String:String].self,from:data) { values = custom }
        for (field,name) in mapping {
            if let value = raw[name.lowercased()] ?? raw[name],!value.isEmpty || values[field] != nil { values[field] = value }
        }
        return values
    }
    static func quote(_ text: String) -> String { String(decoding:try! JSONEncoder().encode(text),as:UTF8.self) }
    static func savePDF(_ pdf: PDFDocument,attributes: [AnyHashable:Any],from source: URL,to target: URL,expected: [String:String]?) throws {
        pdf.documentAttributes = attributes
        let pageCount = pdf.pageCount
        guard pdf.write(to:target) else { throw ReaderFailure("PDF图书信息写入失败，未替换原文件。") }
        func valid() -> Bool {
            guard let check = PDFDocument(url:target),check.pageCount == pageCount else { return false }
            return expected.map { pdfValues(check) == $0 } ?? true
        }
        if valid() { return }
        // Missing Info dictionaries can make PDFKit silently discard new values.
        // Append only metadata to the original bytes instead of recompressing pages.
        try PDFInformationRevision.write(attributes,source:source,target:target)
        guard valid() else { throw ReaderFailure("PDF图书信息回读校验失败，未替换原文件。") }
    }

    static func write(_ values: [String:String],from source: URL,to target: URL) throws {
        let encoded = try JSONEncoder().encode(values)
        if source.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url:source),!pdf.isLocked else { throw ReaderFailure("PDF无法读取或尚未解锁。") }
            guard !pdf.isEncrypted else { throw ReaderFailure("加密PDF暂不支持直接改写信息；请先用原软件另存为未加密副本。") }
            var attributes = pdf.documentAttributes ?? [:]
            for (field,name) in mapping { attributes[PDFDocumentAttribute(rawValue:name)] = values[field] ?? "" }
            attributes[PDFDocumentAttribute(rawValue:key)] = String(decoding:encoded,as:UTF8.self)
            try savePDF(pdf,attributes:attributes,from:source,to:target,expected:values)
        } else {
            var raw = try djvuRaw(source)
            for (field,name) in mapping { raw.removeValue(forKey:name); raw[name.lowercased()] = values[field] ?? "" }
            raw[key] = encoded.base64EncodedString()
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("uvz-info-"+UUID().uuidString+".dsed")
            defer { try? FileManager.default.removeItem(at:script) }
            let entries = raw.sorted {$0.key<$1.key}.map { $0.key+"\t"+quote($0.value) }.joined(separator:"\n")
            try ("select; set-meta\n"+entries+"\n.\nsave-bundled "+quote(target.path)+"\n").write(to:script,atomically:true,encoding:.utf8)
            _ = try DjVuTools.run("djvused",["-u","-f",script.path,source.path],limit:120)
            guard try DjVuTools.inspect(source).0 == DjVuTools.inspect(target).0,try djvuValues(target) == values else { throw ReaderFailure("DjVu图书信息回读校验失败，未替换原文件。") }
        }
    }
}

extension BookArchive {
    var storesNativeInformation: Bool { ["pdf","djvu","djv"].contains(url.pathExtension.lowercased()) }
}

/// A metadata-only incremental PDF revision. The original byte stream is retained
/// verbatim, including all page images, catalog objects, annotations and outlines.
/// Handles both classic xref tables and xref-stream trailers, including /Prev.
private enum PDFInformationRevision {
    struct Scanner {
        let data: Data
        var at: Int
        mutating func space() {
            while at<data.count {
                if [UInt8(0),9,10,12,13,32].contains(data[at]) { at += 1 }
                else if data[at] == 37 { while at<data.count && data[at] != 10 && data[at] != 13 { at += 1 } }
                else { break }
            }
        }
        mutating func token() -> String {
            space();let start=at
            while at<data.count && ![UInt8(0),9,10,12,13,32,40,41,60,62,91,93,123,125,47,37].contains(data[at]) { at += 1 }
            return String(decoding:data[start..<at],as:UTF8.self)
        }
        mutating func value(_ depth: Int = 0) throws -> Range<Int> {
            space();let start=at
            guard depth<64,at<data.count else { throw ReaderFailure("PDF信息结构不完整。") }
            let c=data[at];at += 1
            if c==40 {
                var nesting=1
                while at<data.count && nesting>0 {
                    let b=data[at];at += 1
                    if b==92 { if at<data.count { at += 1 } }
                    else if b==40 { nesting += 1 } else if b==41 { nesting -= 1 }
                }
                guard nesting==0 else { throw ReaderFailure("PDF信息字符串被截断。") }
            } else if c==60 {
                if at<data.count && data[at]==60 {
                    at += 1
                    while true {
                        space()
                        guard at+1<data.count else { throw ReaderFailure("PDF信息字典被截断。") }
                        if data[at]==62 && data[at+1]==62 { at += 2;break }
                        _ = try value(depth+1)
                    }
                } else {
                    while at<data.count && data[at] != 62 { at += 1 }
                    guard at<data.count else { throw ReaderFailure("PDF十六进制字符串被截断。") };at += 1
                }
            } else if c==91 {
                while true {
                    space();guard at<data.count else { throw ReaderFailure("PDF信息数组被截断。") }
                    if data[at]==93 { at += 1;break };_ = try value(depth+1)
                }
            } else if c==47 {
                _ = token()
            } else {
                at=start;let first=token()
                guard !first.isEmpty else { throw ReaderFailure("PDF信息中存在无效标记。") }
                // Consume an indirect reference as one value, without swallowing
                // the first number of the next dictionary entry or array item.
                let end=at
                if Int(first) != nil {
                    if Int(token()) != nil && token()=="R" { return start..<at }
                    at=end
                }
            }
            return start..<at
        }
        mutating func dictionary() throws -> [String:Range<Int>] {
            space();guard at+1<data.count,data[at]==60,data[at+1]==60 else { throw ReaderFailure("PDF交叉引用字典无法读取。") }
            at += 2;var result:[String:Range<Int>]=[:]
            while true {
                space();guard at+1<data.count else { throw ReaderFailure("PDF尾部字典被截断。") }
                if data[at]==62 && data[at+1]==62 { at += 2;return result }
                guard data[at]==47 else { throw ReaderFailure("PDF尾部字典键无效。") };at += 1
                let name=token();guard !name.isEmpty else { throw ReaderFailure("PDF尾部字典键为空。") }
                result[name]=try value()
            }
        }
    }
    private static func pdfString(_ text: String) -> String {
        "<FEFF"+text.utf16.map { String(format:"%04X",UInt32($0)) }.joined()+">"
    }
    private static func encoded(_ value: Any) throws -> String {
        if let text=value as? String { return pdfString(text) }
        if let date=value as? Date {
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="'D:'yyyyMMddHHmmss'Z'"
            return pdfString(formatter.string(from:date))
        }
        if let array=value as? [Any] { return "["+(try array.map(encoded)).joined(separator:" ")+"]" }
        if let number=value as? NSNumber {
            if CFGetTypeID(number)==CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            guard number.doubleValue.isFinite else { throw ReaderFailure("PDF原有信息包含无效数值。") };return number.stringValue
        }
        throw ReaderFailure("PDF原有信息包含暂不支持的数据类型，未覆盖原文件。")
    }
    static func write(_ attributes: [AnyHashable:Any],source: URL,target: URL) throws {
        let data=try Data(contentsOf:source,options:.mappedIfSafe)
        guard let marker=data.range(of:Data("startxref".utf8),options:.backwards,in:max(0,data.count-65536)..<data.count) else { throw ReaderFailure("PDF缺少有效交叉引用，未覆盖原文件。") }
        var end=Scanner(data:data,at:marker.upperBound)
        guard let last=Int(end.token()),last>=0,last<data.count else { throw ReaderFailure("PDF交叉引用位置无效。") }
        var at=last,seen=Set<Int>(),size=0,root:String?,identifier:Data?,finished=false
        for _ in 0..<64 {
            guard seen.insert(at).inserted,at>=0,at<data.count else { throw ReaderFailure("PDF交叉引用链异常。") }
            var scanner=Scanner(data:data,at:at)
            if scanner.token()=="xref" {
                guard let trailer=data.range(of:Data("trailer".utf8),in:scanner.at..<data.count) else { throw ReaderFailure("PDF缺少尾部字典。") };scanner.at=trailer.upperBound
            } else {
                scanner.at=at
                guard Int(scanner.token()) != nil,Int(scanner.token()) != nil,scanner.token()=="obj" else { throw ReaderFailure("PDF交叉引用流无效。") }
            }
            let entries=try scanner.dictionary()
            func raw(_ key:String) -> String? { entries[key].map {String(decoding:data[$0],as:UTF8.self)} }
            guard entries["Encrypt"] == nil else { throw ReaderFailure("加密PDF不支持直接改写信息。") }
            if let value=raw("Size"),let n=Int(value) { size=max(size,n) }
            if root==nil { root=raw("Root") };if identifier==nil {identifier=entries["ID"].map {Data(data[$0])}}
            guard let previous=raw("Prev") else { finished=true;break }
            guard let previous=Int(previous) else { throw ReaderFailure("PDF交叉引用链位置无效。") };at=previous
        }
        guard finished,let root,size>0,size<1_000_000_000 else { throw ReaderFailure("PDF缺少可用文档根或对象计数。") }
        let parts=root.split(whereSeparator:{$0.isWhitespace})
        guard parts.count==3,let object=Int(parts[0]),object>0,object<size,Int(parts[1]) != nil,parts[2]=="R" else { throw ReaderFailure("PDF文档根引用无效。") }
        var lines:[String]=[]
        for (key,value) in attributes {
            let name=(key.base as? PDFDocumentAttribute)?.rawValue ?? String(describing:key)
            let escaped=name.utf8.map { byte -> String in
                if byte>=33 && byte<=126 && !Array("#/%()<>[]{}".utf8).contains(byte) {return String(UnicodeScalar(byte))}
                return String(format:"#%02X",byte)
            }.joined()
            lines.append("/"+escaped+" "+(try encoded(value)))
        }
        let info="\n\(size) 0 obj\n<<\n"+lines.sorted().joined(separator:"\n")+"\n>>\nendobj\n"
        let offset=data.count+1,xref=data.count+info.utf8.count
        guard offset<10_000_000_000 else { throw ReaderFailure("PDF文件超过本版信息保存限制。") }
        let trailer="xref\n\(size) 1\n"+String(format:"%010lld 00000 n \n",Int64(offset))+"trailer\n<< /Size \(size+1) /Root \(root) /Info \(size) 0 R /Prev \(last)"
        var suffix=Data((info+trailer).utf8)
        if let identifier { suffix.append(Data(" /ID ".utf8));suffix.append(identifier) }
        suffix.append(Data(" >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let handle=try FileHandle(forWritingTo:target);defer {try? handle.close()}
        try handle.truncate(atOffset:0);try handle.write(contentsOf:data);try handle.write(contentsOf:suffix);try handle.synchronize()
    }
}
