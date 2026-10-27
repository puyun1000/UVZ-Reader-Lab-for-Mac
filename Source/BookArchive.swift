import Foundation
import CoreFoundation
import PDFKit
import ImageIO
import CryptoKit
import Darwin

@_silgen_name("lab_inflate")
private func inflateRaw(_ source: UnsafePointer<UInt8>, _ count: Int,
                        _ destination: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int32
@_silgen_name("lab_crc32")
private func crc32Bytes(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> UInt32
@_silgen_name("lab_inflate_zlib")
private func inflateZlib(_ source: UnsafePointer<UInt8>, _ count: Int,
                         _ destination: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int
@_silgen_name("lab_inflate_prefix")
private func inflatePrefix(_ source: UnsafePointer<UInt8>, _ count: Int, _ destination: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int

struct ReaderFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct PageKey: Comparable {
    let group: Int
    let number: Int
    let name: String
    static func < (a: Self, b: Self) -> Bool {
        if a.group != b.group { return a.group < b.group }
        if a.number != b.number { return a.number < b.number }
        return a.name < b.name
    }
}

/// Compatibility behavior reconstructed from the reference application's pageKey function.
func pageKey(_ filename: String) -> PageKey {
    let name = (filename as NSString).lastPathComponent.lowercased()
    let stem = (name as NSString).deletingPathExtension
    let first = stem.split(separator: "_").first.map(String.init) ?? ""
    let number = Int(String(first.filter(\.isNumber))) ?? 0
    let prefix = String(stem.prefix(while: { !$0.isNumber }))
    let group: Int
    switch prefix {
    case "cov": group = number < 2 ? 0 : 7
    case "bok": group = 1
    case "leg": group = 2
    case "fow": group = 3
    case "!": group = 4
    case "": group = 5
    case "att": group = 6
    case "bac": group = 7
    default: group = 8
    }
    return PageKey(group: group, number: number, name: name)
}

struct ArchiveEntry {
    let name: String
    let rawName: Data
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let packedSize: Int
    let size: Int
    let offset: Int
    let centralOffset: Int
    let centralLength: Int
}

struct BookPage {
    let entry: Int
    let name: String
    let key: PageKey
    var pdfPage: Int? = nil
    var number: Int { key.number + (pdfPage ?? 0) }
    var label: String {
        let titles = ["封面", "书名", "版权", "前言", "目录", "正文", "附录", "封底", "其他"]
        return "\(titles[key.group]) · \(number)"
    }
}

struct BookChapter {
    let title: String
    let pageIndex: Int
    let level: Int
    let path: String?
}

final class BookArchive {
    let url: URL
    let title: String
    let metadata: [String: String]
    let pages: [BookPage]
    let hasElectronicContents: Bool
    let chapters: [BookChapter]
    let contentsNotice: String?
    private let bytes: Data
    private let entries: [ArchiveEntry]
    private var loose: LooseBook?
    private var archiveFolder = ""
    private var sourceDigest = Data()
    private var archiveComment = Data()
    private let pdfDocuments = NSCache<NSNumber, PDFDocument>()
    private let pdfLock = NSLock()
    private static let maxEntryBytes = 128 * 1024 * 1024

    init(url: URL) throws {
        self.url = url.standardizedFileURL
        if LooseBook.accepts(url) {
            let source = try LooseBook(url: url)
            loose = source; bytes = Data(); entries = []
            pages = source.pages; title = source.title; metadata = source.metadata
            chapters = source.chapters; hasElectronicContents = source.hasContents; contentsNotice = source.notice
            return
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries = try Self.readDirectory(bytes)
        for at in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try bytes.u32(at) == 0x06054b50, at + 22 + Int(try bytes.u16(at + 20)) == bytes.count {
                archiveComment = bytes.subdata(in: at + 22..<bytes.count); break
            }
        }
        let candidates = entries.enumerated().filter {
            $0.element.name.lowercased().hasSuffix(".pdg") &&
            !$0.element.name.split(separator: "/").contains("__MACOSX")
        }
        guard !candidates.isEmpty else { throw ReaderFailure("压缩包中没有 PDG 页面。") }
        guard candidates.count <= 100_000 else { throw ReaderFailure("页面数量超过实验版的限制。") }
        let folders = Set(candidates.map { ($0.element.name as NSString).deletingLastPathComponent })
        guard folders.count == 1 else { throw ReaderFailure("压缩包包含多个 PDG 文件夹，请先选择单本书籍。") }
        let folder = folders.first!
        archiveFolder = folder
        let basePages = candidates.map { BookPage(entry: $0.offset, name: ($0.element.name as NSString).lastPathComponent, key: pageKey($0.element.name)) }.sorted { $0.key < $1.key }
        guard Set(basePages.map { $0.name.lowercased() }).count == basePages.count else {
            throw ReaderFailure("书籍存在重复页面文件名。")
        }
        var pages: [BookPage] = []
        for page in basePages {
            let entry = entries[page.entry]
            let head = try Self.prefix(entry, from: bytes)
            if head.starts(with: Data("%PDF-".utf8)) || (head.count >= 4 && head[0] == 0x48 && head[1] == 0x48 && head[2] != 1 && head[3] == 0x46) {
                let decoded = try PageDecoder.decodedData(Self.read(entry, from: bytes))
                guard let document = PDFDocument(data: decoded), !document.isLocked, document.pageCount > 0 else { throw ReaderFailure("无法读取文本 PDG 的 PDF 页面。") }
                guard document.pageCount <= 100_000 - pages.count else { throw ReaderFailure("书籍总页数超出限制。") }
                for i in 0..<document.pageCount {
                    pages.append(BookPage(entry: page.entry, name: page.name, key: page.key, pdfPage: i))
                }
            } else { pages.append(page) }
            guard pages.count <= 100_000 else { throw ReaderFailure("书籍总页数超出限制。") }
        }
        var metadata: [String: String] = [:]
        if let info = entries.first(where: {
            ($0.name as NSString).lastPathComponent.lowercased() == "bookinfo.dat" &&
            ($0.name as NSString).deletingLastPathComponent == folder
        }) {
            guard info.size <= 2 * 1024 * 1024 else { throw ReaderFailure("书籍信息文件过大。") }
            let raw = try Self.read(info, from: bytes)
            if let text = Self.legacyText(raw) {
                for line in text.components(separatedBy: .newlines) {
                    let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if pair.count == 2 { metadata[String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)] = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
        }
        let contentsEntry = entries.first {
            ($0.name as NSString).lastPathComponent.lowercased() == "bookcontents.dat" &&
            ($0.name as NSString).deletingLastPathComponent == folder
        }
        var chapters: [BookChapter] = [], notice: String?
        if let contentsEntry {
            do {
                guard contentsEntry.size <= 2 * 1024 * 1024 else { throw ReaderFailure("电子目录文件过大。") }
                let parsed = try Self.parseContents(Self.read(contentsEntry, from: bytes), pages: pages)
                chapters = parsed.0
                notice = parsed.1
            } catch { notice = "电子目录未能读取：" + error.localizedDescription }
        }
        self.chapters = chapters
        self.contentsNotice = notice
        self.bytes = bytes
        sourceDigest = Data(SHA256.hash(data: bytes))
        self.entries = entries
        self.pages = pages
        self.metadata = metadata
        self.title = metadata["书名"].flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        self.hasElectronicContents = contentsEntry != nil
        pdfDocuments.countLimit = 4
    }

    func pageData(at index: Int) throws -> Data {
        guard pages.indices.contains(index) else { throw ReaderFailure("页码超出范围。") }
        if let loose { return try loose.pageData(at: index) }
        return try PageDecoder.decodedData(Self.read(entries[pages[index].entry], from: bytes))
    }

    func pageImage(at index: Int) throws -> CGImage {
        guard pages.indices.contains(index) else { throw ReaderFailure("页码超出范围。") }
        if let loose { return try loose.pageImage(at: index) }
        let page = pages[index]
        if let pdfPage = page.pdfPage {
            pdfLock.lock(); defer { pdfLock.unlock() }
            let key = NSNumber(value: page.entry)
            let document: PDFDocument
            if let cached = pdfDocuments.object(forKey: key) { document = cached }
            else {
                guard let parsed = PDFDocument(data: try pageData(at: index)) else { throw ReaderFailure("PDF 无法读取。") }
                document = parsed; pdfDocuments.setObject(parsed, forKey: key)
            }
            return try PageDecoder.image(document, at: pdfPage)
        }
        return try PageDecoder.image(pageData(at: index))
    }

    /// Conversion reads the same decoded payload without applying reading appearance options.
    func exportData(at index: Int) throws -> Data? {
        guard pages.indices.contains(index) else {throw ReaderFailure("页码超出范围。")}
        if let loose { return loose.kind == "pdf" || ["djvu","djv"].contains(loose.kind) ? nil : try loose.pageData(at:index) }
        return try pageData(at:index)
    }
    func exportImage(at index: Int) throws -> CGImage {
        if let loose,["djvu","djv"].contains(loose.kind) { return try DjVuTools.render(url,page:index+1,fullResolution:true) }
        return try pageImage(at:index)
    }
    var exportImageIndex: (Int)->Int { { [self] index in ["tif","tiff"].contains(loose?.kind ?? "") ? index : 0 } }
    var hasExportContentsOverride: Bool {loose?.storedMetadata["bookcontents.dat"] != nil}
    var exportNeedsPDFContext: Bool {url.pathExtension.lowercased() == "pdf" || pages.contains {$0.pdfPage != nil}}
    private static func prefix(_ entry: ArchiveEntry, from data: Data) throws -> Data {
        guard entry.flags & 1 == 0, entry.method == 0 || entry.method == 8 else { return Data() }
        guard entry.size <= maxEntryBytes, entry.packedSize <= maxEntryBytes,
              entry.offset <= data.count - 30, try data.u32(entry.offset) == 0x04034b50 else { throw ReaderFailure("ZIP 页面数据异常。") }
        let start = entry.offset + 30 + Int(try data.u16(entry.offset + 26)) + Int(try data.u16(entry.offset + 28))
        guard start <= data.count, entry.packedSize <= data.count - start else { throw ReaderFailure("ZIP 页面数据越界。") }
        let count = min(140, entry.size)
        if entry.method == 0 { return data.subdata(in: start..<start + min(count, entry.packedSize)) }
        guard count > 0, entry.packedSize > 0 else { return Data() }
        var output = Data(count: count)
        let actual = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                inflatePrefix(src.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self), entry.packedSize, dst.baseAddress!.assumingMemoryBound(to: UInt8.self), count)
            }
        }
        guard actual >= 0 else { throw ReaderFailure("ZIP 页面头部解压失败。") }
        output.count = actual
        return output
    }

    static func legacyText(_ bytes: Data) -> String? {
        if let text = String(data: bytes, encoding: .utf8) { return text }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: bytes, encoding: String.Encoding(rawValue: encoding))
    }

    static func parseContents(_ raw: Data, pages: [BookPage]) throws -> ([BookChapter], String?) {
        let text = try contentsText(raw)
        var result: [BookChapter] = [], ignored = 0
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 5,
                  let number = Int(fields[2].trimmingCharacters(in: .whitespaces)),
                  let type = Int(fields[4].trimmingCharacters(in: .whitespaces)),
                  (0...8).contains(type) else {
                ignored += 1
                continue
            }
            let index: Int
            if type == 0 && number == 0 { index = -1 }
            else if let found = pages.firstIndex(where: { $0.key.group == type - 1 && $0.number == number }) { index = found }
            else { ignored += 1; continue }
            let title = fields[0].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { ignored += 1; continue }
            let path = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let hierarchical = (2...128).contains(path.count) && path.count % 2 == 0 && path.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
            result.append(BookChapter(title: title, pageIndex: index, level: hierarchical ? path.count / 2 - 1 : 0,
                                      path: hierarchical ? path.lowercased() : nil))
        }
        return (result, ignored > 0 ? "已忽略 \(ignored) 条失效目录记录。" : nil)
    }

    static func contentsText(_ raw: Data) throws -> String {
        var textData = raw
        if raw.starts(with: Data("SSCNTS".utf8)) {
            guard raw.count > 40 else { throw ReaderFailure("电子目录压缩头被截断。") }
            let packed = raw.subdata(in: 40..<raw.count)
            var output = Data(count: 2 * 1024 * 1024)
            let capacity = output.count
            let size = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                packed.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    inflateZlib(src.baseAddress!.assumingMemoryBound(to: UInt8.self), packed.count,
                                dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity)
                }
            }
            guard size >= 0, size <= capacity else { throw ReaderFailure("电子目录解压失败或超过 2 MB。") }
            output.count = size
            textData = output
        }
        guard let text = legacyText(textData) else { throw ReaderFailure("无法识别电子目录文字编码。") }
        return text
    }

    private static func readDirectory(_ data: Data) throws -> [ArchiveEntry] {
        guard data.count >= 22 else { throw ReaderFailure("文件过短，不是完整的 ZIP / UVZ。") }
        var eocd: Int?
        for at in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try data.u32(at) == 0x06054b50,
               at + 22 + Int(try data.u16(at + 20)) == data.count { eocd = at; break }
        }
        guard let end = eocd else { throw ReaderFailure("找不到 ZIP 中央目录。") }
        guard try data.u16(end + 4) == 0, try data.u16(end + 6) == 0,
              try data.u16(end + 8) == data.u16(end + 10) else { throw ReaderFailure("实验版暂不支持分卷压缩包。") }
        let count = Int(try data.u16(end + 10))
        let size = Int(try data.u32(end + 12)), start = Int(try data.u32(end + 16))
        guard count != 0xffff, size != 0xffffffff, start != 0xffffffff else { throw ReaderFailure("实验版暂不支持 ZIP64。") }
        guard start <= end, size <= end - start else { throw ReaderFailure("ZIP 中央目录范围异常。") }
        var result: [ArchiveEntry] = [], at = start
        for _ in 0..<count {
            guard at + 46 <= start + size, try data.u32(at) == 0x02014b50 else { throw ReaderFailure("ZIP 目录条目损坏。") }
            let flags = try data.u16(at + 8), method = try data.u16(at + 10)
            let packed = Int(try data.u32(at + 20)), length = Int(try data.u32(at + 24))
            let nameLength = Int(try data.u16(at + 28)), extra = Int(try data.u16(at + 30)), comment = Int(try data.u16(at + 32))
            guard try data.u16(at + 34) == 0 else { throw ReaderFailure("实验版暂不支持分卷条目。") }
            let next = at + 46 + nameLength + extra + comment
            guard next <= start + size else { throw ReaderFailure("ZIP 条目超出目录范围。") }
            let rawName = data.subdata(in: at + 46 ..< at + 46 + nameLength)
            let name: String?
            if flags & 0x800 != 0 { name = String(data: rawName, encoding: .utf8) }
            else { name = legacyText(rawName) }
            guard let name else { throw ReaderFailure("无法识别 ZIP 文件名编码。") }
            let localOffset = Int(try data.u32(at + 42))
            guard packed != 0xffffffff, length != 0xffffffff, localOffset != 0xffffffff else { throw ReaderFailure("实验版暂不支持 ZIP64 条目。") }
            result.append(ArchiveEntry(name: name, rawName: rawName, flags: flags, method: method, crc: try data.u32(at + 16), packedSize: packed, size: length, offset: localOffset, centralOffset: at, centralLength: next - at))
            at = next
        }
        guard at == start + size else { throw ReaderFailure("ZIP 目录含有未识别数据。") }
        return result
    }

    private static func read(_ entry: ArchiveEntry, from data: Data) throws -> Data {
        guard entry.flags & 1 == 0 else { throw ReaderFailure("实验版暂不支持带密码的压缩包。") }
        guard entry.method == 0 || entry.method == 8 else { throw ReaderFailure("不支持的 ZIP 压缩方式：\(entry.method)。") }
        guard entry.size <= maxEntryBytes, entry.packedSize <= maxEntryBytes else { throw ReaderFailure("单个页面超出 128 MB 限制。") }
        let at = entry.offset
        guard at <= data.count - 30, try data.u32(at) == 0x04034b50,
              try data.u16(at + 6) == entry.flags, try data.u16(at + 8) == entry.method else { throw ReaderFailure("ZIP 页面头部与目录不一致。") }
        let nameLength = Int(try data.u16(at + 26)), extra = Int(try data.u16(at + 28))
        let start = at + 30 + nameLength + extra
        guard start <= data.count, entry.packedSize <= data.count - start else { throw ReaderFailure("ZIP 页面数据越界。") }
        guard data.subdata(in: at + 30 ..< at + 30 + nameLength) == entry.rawName else { throw ReaderFailure("ZIP 页面文件名不一致。") }
        let packed = data.subdata(in: start ..< start + entry.packedSize)
        let output: Data
        if entry.method == 0 {
            guard packed.count == entry.size else { throw ReaderFailure("ZIP 页面长度不一致。") }
            output = packed
        } else if entry.size == 0 {
            output = Data()
        } else {
            var unpacked = Data(count: entry.size)
            let result = unpacked.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                packed.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int32 in
                    guard let src = source.baseAddress, let dst = destination.baseAddress else { return -1 }
                    return inflateRaw(src.assumingMemoryBound(to: UInt8.self), packed.count, dst.assumingMemoryBound(to: UInt8.self), entry.size)
                }
            }
            guard result == 0 else { throw ReaderFailure("ZIP 页面解压失败或长度不符。") }
            output = unpacked
        }
        let crc: UInt32 = output.isEmpty ? 0 : output.withUnsafeBytes { crc32Bytes($0.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count) }
        guard crc == entry.crc else { throw ReaderFailure("页面 CRC 校验失败，文件可能损坏。") }
        return output
    }
}

private extension Data {
    func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ReaderFailure("文件数据被截断。") }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ReaderFailure("文件数据被截断。") }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}

struct BookEditDraft: Codable {
    struct Chapter: Codable, Equatable { var title: String; var page: Int; var level: Int; var unresolvedTarget: String? = nil }
    var chapters: [Chapter]
    var metadata: [String: String]
    init(book: BookArchive) {
        chapters = book.chapters.map { Chapter(title: $0.title, page: $0.pageIndex + 1, level: $0.level) }
        metadata = book.metadata
    }
    func validated(for book: BookArchive) throws -> [BookChapter] {
        guard chapters.count <= 50_000 else { throw ReaderFailure("目录项不能超过 50000 条。") }
        var previous = -1, counters = [Int](repeating: 0, count: 33)
        return try chapters.map { row in
            guard row.unresolvedTarget == nil else { throw ReaderFailure("目录中仍有未匹配的页号：" + (row.unresolvedTarget ?? "") + "，请修正后保存。") }
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !title.contains("|"), !title.contains("\n"), !title.contains("\r"), title.count <= 1000 else { throw ReaderFailure("目录名称不能为空，也不能包含竖线或换行。") }
            guard (0...book.pages.count).contains(row.page), row.level >= 0, row.level <= 32, row.level <= previous + 1 else { throw ReaderFailure("目录页码须在文档范围内；首项层级为 1，相邻项最多加深一级。") }
            counters[row.level] += 1
            guard counters[row.level] <= 255 else { throw ReaderFailure("同一级的兄弟目录不能超过 255 项。") }
            if row.level < 32 { for i in row.level+1...32 { counters[i] = 0 } }
            previous = row.level
            let path = counters.prefix(row.level + 1).map { String(format: "%02x", $0) }.joined()
            return BookChapter(title: title, pageIndex: row.page - 1, level: row.level, path: path)
        }
    }
    func encodedInfo() throws -> Data {
        for (key, value) in metadata {
            guard !key.trimmingCharacters(in: .whitespaces).isEmpty, !key.contains("="), !key.contains("\n"), !key.contains("\r"), !value.contains("\n"), !value.contains("\r") else { throw ReaderFailure("书籍信息每项一行，字段名不能包含等号。") }
        }
        let data = Data(metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\r\n" }.joined().utf8)
        guard data.count <= 2 * 1024 * 1024 else { throw ReaderFailure("书籍信息超过 2 MB。") }
        return data
    }
}

extension BookArchive {
    var editingLocation: String {
        if storesNativeInformation {return "文档内的目录书签和图书信息"}
        if let loose { return loose.metadataDirectory.path + "/Bookcontents.dat、BookInfo.dat" }
        return "压缩包内的 " + (archiveFolder.isEmpty ? "" : archiveFolder + "/") + "Bookcontents.dat、BookInfo.dat"
    }
    var isZip: Bool { loose == nil }
    var usesPDGNumbering: Bool { loose == nil || loose?.kind == "folder" || loose?.kind == "pdg" }
    /// Saves both DAT files as one ZIP replacement, retaining compressed page bytes unchanged.
    @discardableResult func saveEdits(_ draft: BookEditDraft, backup: Bool = false, preserveDates: Bool = true, writeContents: Bool = true, writeInfo: Bool = true) throws -> [URL] {
        if storesNativeInformation,let loose {
            if !writeContents && !writeInfo {return []}
            let chapters=writeContents ? try draft.validated(for:self) : nil
            if writeInfo {_ = try draft.encodedInfo()}
            return try saveNativeInformation(writeInfo ? draft.metadata : metadata,to:url,source:loose,backup:backup,preserveDates:preserveDates,contents:chapters).backups
        }
        let sourceDates = try FileDateRecord(url)
        let chapters = writeContents ? try draft.validated(for: self) : []
        let info = writeInfo ? try draft.encodedInfo() : Data()
        var lines: [String] = []
        for chapter in chapters {
            if chapter.pageIndex < 0 { lines.append("\(chapter.title)|\(chapter.path!)|0|0|0\r\n"); continue }
            let page = pages[chapter.pageIndex]
            guard page.key.group < 8,
                  pages.firstIndex(where: { $0.key.group == page.key.group && $0.number == page.number }) == chapter.pageIndex else {
                throw ReaderFailure("该页无法唯一表示为 DAT 页码，请选择具有唯一页号的页面。")
            }
            lines.append("\(chapter.title)|\(chapter.path!)|\(page.number)|0|\(page.key.group + 1)\r\n")
        }
        let contents = Data(lines.joined().utf8)
        guard contents.count <= 2 * 1024 * 1024 else { throw ReaderFailure("目录文件超过 2 MB。") }
        if let loose {
            let folder = loose.metadataDirectory
            for name in ["bookcontents.dat", "bookinfo.dat"] {
                let current = try LooseBook.find(name, in: folder).map { try LooseBook.smallData($0) }
                guard current == loose.storedMetadata[name] else { throw ReaderFailure("DAT 文件已被其他程序修改，请重新打开再编辑。") }
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let allTargets = [try LooseBook.find("bookcontents.dat", in: folder) ?? folder.appendingPathComponent("Bookcontents.dat"),
                              try LooseBook.find("bookinfo.dat", in: folder) ?? folder.appendingPathComponent("BookInfo.dat")]
            let changes = zip(allTargets, [contents, info]).enumerated().filter { $0.offset == 0 ? writeContents : writeInfo }.map(\.element)
            let targets = changes.map(\.0)
            let dates = try Dictionary(uniqueKeysWithValues: targets.filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0, try FileDateRecord($0)) })
            var backups: [URL] = [], originals: [URL: Data] = [:], written: [URL] = []
            for target in targets where FileManager.default.fileExists(atPath: target.path) {
                originals[target] = try Data(contentsOf: target)
                if backup { let copy = Self.backupURL(target); try FileManager.default.copyItem(at: target, to: copy); backups.append(copy) }
            }
            do {
                for (target, value) in changes {
                    try value.write(to: target, options: .atomic); written.append(target)
                    if preserveDates { try dates[target]?.restore(to: target) }
                }
                if preserveDates { try sourceDates.restore(to: url) }
            } catch {
                for target in written { if let old = originals[target] { try? old.write(to: target, options: .atomic) } else { try? FileManager.default.removeItem(at: target) } }
                throw error
            }
            return backups
        }
        guard Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))) == sourceDigest else { throw ReaderFailure("压缩包已被其他程序修改，请重新打开再编辑。") }
        let prefix = archiveFolder.isEmpty ? "" : archiveFolder + "/"
        let changes = zip([prefix + "Bookcontents.dat", prefix + "BookInfo.dat"], [contents, info]).enumerated().filter { $0.offset == 0 ? writeContents : writeInfo }.map(\.element)
        let output = try rewrittenArchive(replacements:Dictionary(uniqueKeysWithValues:changes))
        var backups: [URL] = []
        if backup { let copy = Self.backupURL(url); try FileManager.default.copyItem(at: url, to: copy); backups.append(copy) }
        try output.write(to: url, options: .atomic)
        if preserveDates { try sourceDates.restore(to: url) }
        return backups
    }
    private func rewrittenArchive(replacements: [String:Data], renames: [String:String] = [:]) throws -> Data {
        let names = Array(replacements.keys)
        var output = Data(), central = Data(), count = 0
        func append(_ name: String, method: UInt16, packed: Data, size: Int, crc: UInt32) throws {
            let utf8 = Data(name.utf8)
            guard utf8.count < 65536, packed.count <= Int(UInt32.max), size <= Int(UInt32.max), output.count < Int(UInt32.max) else { throw ReaderFailure("编辑后需要 ZIP64，暂不能保存。") }
            let offset = UInt32(output.count)
            output.put32(0x04034b50); output.put16(20); output.put16(0x0800); output.put16(method)
            output.put16(0); output.put16(0); output.put32(crc); output.put32(UInt32(packed.count)); output.put32(UInt32(size))
            output.put16(UInt16(utf8.count)); output.put16(0); output.append(utf8); output.append(packed)
            central.put32(0x02014b50); central.put16(20); central.put16(20); central.put16(0x0800); central.put16(method)
            central.put16(0); central.put16(0); central.put32(crc); central.put32(UInt32(packed.count)); central.put32(UInt32(size))
            central.put16(UInt16(utf8.count)); central.put16(0); central.put16(0); central.put16(0); central.put16(0); central.put32(name.hasSuffix("/") ? 16 : 0); central.put32(offset); central.append(utf8)
            count += 1
        }
        for entry in entries where !names.contains(where: { $0.lowercased() == entry.name.lowercased() }) {
            _ = try Self.read(entry, from: bytes) // Verify every original member before creating a replacement.
            let start = entry.offset + 30 + Int(try bytes.u16(entry.offset + 26)) + Int(try bytes.u16(entry.offset + 28))
            var end = start + entry.packedSize
            if entry.flags & 8 != 0 {
                let signature = try bytes.u32(end) == 0x08074b50
                let descriptor = end + (signature ? 4 : 0)
                guard try bytes.u32(descriptor) == entry.crc, try bytes.u32(descriptor + 4) == UInt32(entry.packedSize), try bytes.u32(descriptor + 8) == UInt32(entry.size) else { throw ReaderFailure("ZIP 数据描述符异常，未保存修改。") }
                end = descriptor + 12
            }
            guard end <= bytes.count, output.count < Int(UInt32.max) else { throw ReaderFailure("ZIP 条目范围或大小异常。") }
            var record = bytes.subdata(in: entry.centralOffset..<entry.centralOffset + entry.centralLength)
            let offset = UInt32(output.count)
            for i in 0..<4 { record[42 + i] = UInt8(truncatingIfNeeded: offset >> (i * 8)) }
            if let renamed = renames[entry.name], renamed != entry.name {
                let name = Data(renamed.utf8)
                guard name.count < 65536 else { throw ReaderFailure("页面文件名过长。") }
                func cleanExtra(_ extra: Data) throws -> Data {
                    var result = Data(), at = 0
                    while at < extra.count {
                        guard at + 4 <= extra.count else { throw ReaderFailure("ZIP 扩展字段被截断。") }
                        let kind = try extra.u16(at), size = Int(try extra.u16(at+2))
                        guard size <= extra.count - at - 4 else { throw ReaderFailure("ZIP 扩展字段被截断。") }
                        if kind != 0x7075 { result.append(extra.subdata(in: at..<at+4+size)) }
                        at += 4 + size
                    }
                    return result
                }
                let localName = Int(try bytes.u16(entry.offset+26)), localExtra = Int(try bytes.u16(entry.offset+28))
                let extra = try cleanExtra(bytes.subdata(in: entry.offset+30+localName..<entry.offset+30+localName+localExtra))
                var header = bytes.subdata(in: entry.offset..<entry.offset+30)
                func set16(_ data: inout Data, _ at: Int, _ value: UInt16) { data[at] = UInt8(truncatingIfNeeded:value); data[at+1] = UInt8(truncatingIfNeeded:value >> 8) }
                set16(&header,6,entry.flags | 0x0800); set16(&header,26,UInt16(name.count)); set16(&header,28,UInt16(extra.count))
                output.append(header); output.append(name); output.append(extra); output.append(bytes.subdata(in:start..<end))
                let oldName = Int(try record.u16(28)), oldExtra = Int(try record.u16(30)), oldComment = Int(try record.u16(32))
                let centralExtra = try cleanExtra(record.subdata(in:46+oldName..<46+oldName+oldExtra))
                let comment = record.subdata(in:46+oldName+oldExtra..<46+oldName+oldExtra+oldComment)
                record = record.subdata(in:0..<46)
                set16(&record,8,entry.flags | 0x0800); set16(&record,28,UInt16(name.count)); set16(&record,30,UInt16(centralExtra.count))
                record.append(name); record.append(centralExtra); record.append(comment); central.append(record)
            } else { output.append(bytes.subdata(in: entry.offset..<end)); central.append(record) }
            count += 1
        }
        for name in names {
            let data = replacements[name]!
            let crc: UInt32 = data.isEmpty ? 0 : data.withUnsafeBytes { crc32Bytes($0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count) }
            try append(name, method: 0, packed: data, size: data.count, crc: crc)
        }
        guard count < 65535, output.count < Int(UInt32.max), central.count < Int(UInt32.max) else { throw ReaderFailure("编辑后需要 ZIP64，暂不能保存。") }
        let offset = output.count; output.append(central)
        output.put32(0x06054b50); output.put16(0); output.put16(0); output.put16(UInt16(count)); output.put16(UInt16(count)); output.put32(UInt32(central.count)); output.put32(UInt32(offset)); output.put16(UInt16(archiveComment.count)); output.append(archiveComment)
        return output
    }
    static func backupURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path + ".backup-" + UUID().uuidString.prefix(8))
    }
    func renameDestination(stem: String) throws -> URL {
        guard canRename else { throw ReaderFailure("文件夹请在访达中重命名；此处可保存书籍信息。") }
        let name = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else { throw ReaderFailure("文件名不能为空，也不能包含斜线或冒号。") }
        guard (name + "." + url.pathExtension).utf16.count <= 255 else { throw ReaderFailure("文件名过长，请精简书名或减少组合字段。") }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name + "." + url.pathExtension)
        guard destination != url else { return url }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ReaderFailure("目标文件已存在，请使用其他名称。") }
        if loose != nil {
            let sidecar = URL(fileURLWithPath: destination.path + ".uvzmeta")
            guard !FileManager.default.fileExists(atPath: sidecar.path) else { throw ReaderFailure("目标名称的书籍信息文件夹已存在，请使用其他名称。") }
        }
        return destination
    }
    var canRename: Bool { loose?.kind != "folder" }
    func renamedURL(stem: String, preserveDates: Bool = true) throws -> URL {
        let destination = try renameDestination(stem: stem)
        if destination != url {
            let fm = FileManager.default, dates = try FileDateRecord(url)
            let oldSidecar = URL(fileURLWithPath: url.path + ".uvzmeta"), newSidecar = URL(fileURLWithPath: destination.path + ".uvzmeta")
            var movedSidecar = false
            try fm.moveItem(at: url, to: destination)
            do {
                if loose != nil, fm.fileExists(atPath: oldSidecar.path) { try fm.moveItem(at: oldSidecar, to: newSidecar); movedSidecar = true }
                if preserveDates { try dates.restore(to: destination) }
                else { try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path) }
            } catch {
                if movedSidecar { try? fm.moveItem(at: newSidecar, to: oldSidecar) }
                try? fm.moveItem(at: destination, to: url)
                throw error
            }
        }
        return destination
    }
    private func saveNativeInformation(_ metadata: [String:String],to destination: URL,source: LooseBook,backup: Bool,preserveDates: Bool,contents: [BookChapter]? = nil) throws -> (url:URL,backups:[URL]) {
        let fm = FileManager.default, dates = try FileDateRecord(url)
        func unchanged() throws {
            guard Data(SHA256.hash(data:try Data(contentsOf:url,options:.mappedIfSafe))) == source.nativeDigest else { throw ReaderFailure("文档已被其他程序修改，请重新打开再保存。") }
            for name in ["bookcontents.dat","bookinfo.dat"] {
                guard try LooseBook.find(name,in:source.metadataDirectory).map(LooseBook.smallData) == source.storedMetadata[name] else {throw ReaderFailure("目录或图书信息已被其他程序修改，请重新打开。")}
            }
        }
        try unchanged()
        let migratedContents=contents ?? (source.storedMetadata["bookcontents.dat"] != nil && contentsNotice == nil ? chapters : nil)
        let stage = url.deletingLastPathComponent().appendingPathComponent(".uvz-info-"+UUID().uuidString+"."+url.pathExtension)
        defer { try? fm.removeItem(at:stage) }
        try NativeDocumentMetadata.write(metadata,from:url,to:stage,contents:migratedContents)
        let permissions = try fm.attributesOfItem(atPath:url.path)[.posixPermissions]
        if let permissions { try fm.setAttributes([.posixPermissions:permissions],ofItemAtPath:stage.path) }
        if preserveDates { try dates.restore(to:stage) }
        try unchanged()
        var backups:[URL]=[]
        if backup {let copy=Self.backupURL(url);try fm.copyItem(at:url,to:copy);backups.append(copy)}
        let oldFolder = source.metadataDirectory,newFolder = URL(fileURLWithPath:destination.path+".uvzmeta",isDirectory:true)
        let oldInfo = try LooseBook.find("bookinfo.dat",in:oldFolder)
        let oldContents=migratedContents == nil ? nil : try LooseBook.find("bookcontents.dat",in:oldFolder)
        let retired=[oldInfo,oldContents].compactMap {$0}
        if backup { for file in retired {let copy=Self.backupURL(file);try fm.copyItem(at:file,to:copy);backups.append(copy)} }
        let remaining = (try? fm.contentsOfDirectory(at:oldFolder,includingPropertiesForKeys:nil))?.filter {!retired.contains($0) && $0.lastPathComponent != ".DS_Store"} ?? []
        var movedFolder = false
        if destination != url,!remaining.isEmpty,fm.fileExists(atPath:oldFolder.path) {
            try fm.moveItem(at:oldFolder,to:newFolder); movedFolder = true
        }
        do {
            if destination == url {
                guard Darwin.rename(stage.path,url.path) == 0 else { throw ReaderFailure("无法替换文档："+String(cString:strerror(errno))) }
            } else {
                try fm.moveItem(at:stage,to:destination)
                do { try fm.removeItem(at:url) } catch { try? fm.removeItem(at:destination); throw error }
            }
        } catch { if movedFolder { try? fm.moveItem(at:newFolder,to:oldFolder) }; throw error }
        // Only retire DAT files whose contents were embedded and verified above.
        for file in retired {try? fm.removeItem(at:movedFolder ? newFolder.appendingPathComponent(file.lastPathComponent) : file)}
        if remaining.isEmpty,fm.fileExists(atPath:oldFolder.path) { try? fm.removeItem(at:oldFolder) }
        return (destination,backups.map {movedFolder && $0.deletingLastPathComponent() == oldFolder ? newFolder.appendingPathComponent($0.lastPathComponent) : $0})
    }
    /// Preflight both names, move companion metadata together, then save metadata only.
    func updateInformation(stem: String, metadata: [String: String]?, backup: Bool = false, preserveDates: Bool = true) throws -> URL {
        let destination = canRename ? try renameDestination(stem: stem) : url
        if let metadata { var draft = BookEditDraft(book: self); draft.metadata = metadata; _ = try draft.encodedInfo() }
        // Check the original snapshot before reopening under a new name. Reopening first
        // would otherwise accept external changes made while the information sheet was open.
        if metadata != nil {
            if let loose {
                for name in ["bookcontents.dat", "bookinfo.dat"] {
                    let current = try LooseBook.find(name, in: loose.metadataDirectory).map { try LooseBook.smallData($0) }
                    guard current == loose.storedMetadata[name] else { throw ReaderFailure("DAT 文件已被其他程序修改，请重新打开再编辑。") }
                }
            } else {
                guard Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))) == sourceDigest else { throw ReaderFailure("压缩包已被其他程序修改，请重新打开再编辑。") }
            }
        }
        if storesNativeInformation,let metadata,let loose {
            return try saveNativeInformation(metadata,to:destination,source:loose,backup:backup,preserveDates:preserveDates).url
        }
        let originalDates = try FileDateRecord(url)
        let moved = canRename ? try renamedURL(stem: stem, preserveDates: preserveDates) : url
        do {
            if let metadata {
                let source = moved == url ? self : try BookArchive(url: moved)
                var draft = BookEditDraft(book: source); draft.metadata = metadata
                try source.saveEdits(draft, backup: backup, preserveDates: preserveDates, writeContents: false)
            }
            if preserveDates { try originalDates.restore(to: moved) }
            else if metadata != nil { try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: moved.path) }
            return destination
        } catch {
            if moved != url {
                let companion = URL(fileURLWithPath: moved.path + ".uvzmeta")
                if loose != nil, FileManager.default.fileExists(atPath: companion.path) { try? FileManager.default.moveItem(at: companion, to: URL(fileURLWithPath: url.path + ".uvzmeta")) }
                try? FileManager.default.moveItem(at: moved, to: url)
            }
            throw error
        }
    }
}

struct FileDateRecord {
    private let attributes: [FileAttributeKey: Any]
    init(_ url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        attributes = values.filter { $0.key == .creationDate || $0.key == .modificationDate }
    }
    func restore(to url: URL) throws { try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path) }
}

private extension Data {
    mutating func put16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func put32(_ value: UInt32) { put16(UInt16(truncatingIfNeeded: value)); put16(UInt16(truncatingIfNeeded: value >> 16)) }
}

struct PageCorrection: Codable, Equatable {
    let page: Int // One-based physical position in the original snapshot.
    let group: Int
    let number: Int
}
struct PageCorrectionPlan {
    let changes: [PageCorrection]
    let renames: [String:String]
    let keys: [PageKey]
    init(book: BookArchive, changes: [PageCorrection]) throws {
        guard book.canCorrectPages, !changes.isEmpty else { throw ReaderFailure("请选择 ZIP／UVZ 或 PDG 文件夹中的页面。") }
        guard Set(changes.map(\.page)).count == changes.count else { throw ReaderFailure("同一页面不能重复设置。") }
        let prefixes = ["cov","bok","leg","fow","!","","att","bac"]
        var renames: [String:String] = [:], keys = book.pages.map { PageKey(group:$0.key.group,number:$0.number,name:$0.key.name) }
        for change in changes {
            guard book.pages.indices.contains(change.page-1), prefixes.indices.contains(change.group), (0...999999).contains(change.number) else { throw ReaderFailure("页面类型或页号无效；页号须在 0—999999 之间。") }
            let page = book.pages[change.page-1]
            guard page.pdfPage == nil else { throw ReaderFailure("多页文本 PDG 暂不支持逐页改编码；请使用独立扫描页面。") }
            let width = change.group == 5 || change.group == 4 ? 6 : 3
            let name = prefixes[change.group] + String(format:"%0*d",width,change.number) + ".pdg"
            let key = pageKey(name)
            guard key.group == change.group else { throw ReaderFailure("封面使用 0 或 1；其他封面请选封底类型。") }
            renames[page.name] = name; keys[change.page-1] = key
        }
        let names = book.pages.map { renames[$0.name] ?? $0.name }
        guard Set(names.map { $0.lowercased() }).count == Set(book.pages.map { $0.name.lowercased() }).count else { throw ReaderFailure("修改后页面文件名重名，未保存。请调整目标页号，或同时调整冲突页面。") }
        let counts = keys.reduce(into:[String:Int]()) { $0["\($1.group):\($1.number)",default:0] += 1 }
        for change in changes {
            let key = keys[change.page-1]
            guard counts["\(key.group):\(key.number)"] == 1 else { throw ReaderFailure("修改后类型内页号重复，未保存。") }
        }
        self.changes = changes; self.renames = renames; self.keys = keys
    }
    func indexMap(from old: BookArchive, to new: BookArchive) throws -> [Int:Int] {
        let lookup = Dictionary(uniqueKeysWithValues: new.pages.indices.map { (new.pages[$0].name.lowercased()+":\(new.pages[$0].pdfPage ?? -1)",$0) })
        return try Dictionary(uniqueKeysWithValues:old.pages.indices.map { index in
            let page = old.pages[index], name = renames[page.name] ?? page.name
            guard let mapped = lookup[name.lowercased()+":\(page.pdfPage ?? -1)"] else { throw ReaderFailure("保存后的页面映射不完整。") }
            return (index,mapped)
        })
    }
}
extension BookArchive {
    var canCorrectPages: Bool { loose == nil || loose?.kind == "folder" }
    func contentsData() throws -> Data? {
        if let loose { return loose.storedMetadata["bookcontents.dat"] }
        return try entries.first { ($0.name as NSString).lastPathComponent.lowercased() == "bookcontents.dat" && ($0.name as NSString).deletingLastPathComponent == archiveFolder }.map { try Self.read($0,from:bytes) }
    }
    private func correctedContents(_ plan: PageCorrectionPlan) throws -> Data? {
        guard let data = try contentsData() else { return nil }
        let text = try Self.contentsText(data)
        var firstKeys: [String:PageKey] = [:]
        for index in pages.indices {
            let old = pages[index], id = "\(old.key.group):\(old.number)"
            if firstKeys[id] == nil { firstKeys[id] = plan.keys[index] }
        }
        var changed = false
        let lines = text.components(separatedBy:"\n").map { line -> String in
            let cr = line.hasSuffix("\r"), value = cr ? String(line.dropLast()) : line
            var fields = value.components(separatedBy:"|")
            guard fields.count >= 5, let number = Int(fields[2].trimmingCharacters(in:.whitespaces)), let type = Int(fields[4].trimmingCharacters(in:.whitespaces)), type > 0,
                  let key = firstKeys["\(type-1):\(number)"], key.group != type-1 || key.number != number else { return line }
            fields[2] = String(key.number); fields[4] = String(key.group+1); changed = true
            return fields.joined(separator:"|") + (cr ? "\r" : "")
        }
        return changed ? Data(lines.joined(separator:"\n").utf8) : nil
    }
    /// Rename page members, keep image payloads, and retarget existing DAT records as one save.
    func correctPages(_ changes: [PageCorrection], backup: Bool = false, preserveDates: Bool = true) throws -> [URL] {
        let plan = try PageCorrectionPlan(book:self,changes:changes), sourceDates = try FileDateRecord(url)
        let fm = FileManager.default, contents = try correctedContents(plan)
        if let loose {
            for name in ["bookcontents.dat","bookinfo.dat"] {
                let current = try LooseBook.find(name,in:url).map { try LooseBook.smallData($0) }
                guard current == loose.storedMetadata[name] else { throw ReaderFailure("图书信息或目录已被其他程序修改，请重新打开。") }
            }
            func snapshot() throws -> [String:Data] {
                guard let files = fm.enumerator(at:url,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else { throw ReaderFailure("无法校验原图书文件夹。") }
                var result: [String:Data] = [:]
                for case let file as URL in files {
                    let attributes = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                    let relative = String(file.path.dropFirst(url.path.count))
                    if attributes.isSymbolicLink == true { result[relative] = Data(try fm.destinationOfSymbolicLink(atPath:file.path).utf8) }
                    else if attributes.isRegularFile == true { result[relative] = Data(SHA256.hash(data:try Data(contentsOf:file,options:.mappedIfSafe))) }
                }
                return result
            }
            let before = try snapshot(), stage = url.deletingLastPathComponent().appendingPathComponent(".uvz-page-stage-"+UUID().uuidString)
            let rollback = backup ? Self.backupURL(url) : url.deletingLastPathComponent().appendingPathComponent(".uvz-page-original-"+UUID().uuidString)
            defer { try? fm.removeItem(at:stage) }
            try fm.copyItem(at:url,to:stage)
            var temporary: [(URL,URL)] = []
            for (old,new) in plan.renames where old != new {
                let target = stage.appendingPathComponent(new), temp = stage.appendingPathComponent(".uvz-page-"+UUID().uuidString)
                guard !fm.fileExists(atPath:target.path) || plan.renames.keys.contains(where: { $0.lowercased() == new.lowercased() }) else { throw ReaderFailure("目标页面文件已存在。") }
                try fm.moveItem(at:stage.appendingPathComponent(old),to:temp); temporary.append((temp,target))
            }
            for (temp,target) in temporary { try fm.moveItem(at:temp,to:target) }
            if let contents, let file = try LooseBook.find("bookcontents.dat",in:stage) {
                let dates = try FileDateRecord(file); try contents.write(to:file,options:.atomic); if preserveDates { try dates.restore(to:file) }
            }
            let verified = try BookArchive(url:stage); _ = try plan.indexMap(from:self,to:verified)
            guard try snapshot() == before else { throw ReaderFailure("页面在保存期间发生变化，未应用修改。") }
            try fm.moveItem(at:url,to:rollback)
            do {
                try fm.moveItem(at:stage,to:url)
                if preserveDates { try sourceDates.restore(to:url) }
            } catch {
                if fm.fileExists(atPath:url.path) { try? fm.moveItem(at:url,to:stage) }
                try? fm.moveItem(at:rollback,to:url); throw error
            }
            if !backup { try? fm.removeItem(at:rollback) }
            return backup ? [rollback] : []
        }
        let prefix = archiveFolder.isEmpty ? "" : archiveFolder+"/"
        let renames = Dictionary(uniqueKeysWithValues:plan.renames.map { (prefix+$0.key,prefix+$0.value) })
        let allNames = entries.map { (renames[$0.name] ?? $0.name).lowercased() }
        guard Set(allNames).count == allNames.count else { throw ReaderFailure("目标页面与压缩包已有文件重名，未保存。") }
        guard Data(SHA256.hash(data:try Data(contentsOf:url,options:.mappedIfSafe))) == sourceDigest else { throw ReaderFailure("图书已被其他程序修改，请重新打开。") }
        var replacements: [String:Data] = [:]
        if let contents, let entry = entries.first(where: { $0.name.lowercased() == (prefix+"Bookcontents.dat").lowercased() }) { replacements[entry.name] = contents }
        let output = try rewrittenArchive(replacements:replacements,renames:renames)
        let stage = url.deletingLastPathComponent().appendingPathComponent(".uvz-page-"+UUID().uuidString+".uvz")
        defer { try? fm.removeItem(at:stage) }; try output.write(to:stage,options:.atomic)
        let verified = try BookArchive(url:stage); _ = try plan.indexMap(from:self,to:verified)
        guard Data(SHA256.hash(data:try Data(contentsOf:url,options:.mappedIfSafe))) == sourceDigest else { throw ReaderFailure("图书在保存期间发生变化，未应用修改。") }
        var backups: [URL] = []
        if backup { let copy = Self.backupURL(url); try fm.copyItem(at:url,to:copy); backups.append(copy) }
        try output.write(to:url,options:.atomic)
        if preserveDates { try sourceDates.restore(to:url) }
        return backups
    }
}
