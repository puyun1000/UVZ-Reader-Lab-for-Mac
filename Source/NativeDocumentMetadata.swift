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
    static func write(_ values: [String:String],from source: URL,to target: URL) throws {
        let encoded = try JSONEncoder().encode(values)
        if source.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url:source),!pdf.isLocked else { throw ReaderFailure("PDF无法读取或尚未解锁。") }
            guard !pdf.isEncrypted else { throw ReaderFailure("加密PDF暂不支持直接改写信息；请先用原软件另存为未加密副本。") }
            var attributes = pdf.documentAttributes ?? [:]
            for (field,name) in mapping { attributes[PDFDocumentAttribute(rawValue:name)] = values[field] ?? "" }
            attributes[PDFDocumentAttribute(rawValue:key)] = String(decoding:encoded,as:UTF8.self)
            pdf.documentAttributes = attributes
            guard pdf.write(to:target),let check = PDFDocument(url:target),check.pageCount == pdf.pageCount,pdfValues(check) == values else { throw ReaderFailure("PDF图书信息回读校验失败，未替换原文件。") }
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
