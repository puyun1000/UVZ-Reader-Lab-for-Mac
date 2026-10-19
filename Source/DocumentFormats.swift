import AppKit
import PDFKit
import ImageIO

let supportedBookExtensions = ["zip", "uvz", "pdg", "pdf", "djvu", "djv", "tif", "tiff"]
func acceptsBookURL(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return supportedBookExtensions.contains(url.pathExtension.lowercased()) ||
        (FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue)
}
func readBookInfo(_ data: Data) -> [String: String] {
    var result: [String: String] = [:]
    for line in (BookArchive.legacyText(data) ?? "").components(separatedBy: .newlines) {
        let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if fields.count == 2 { result[String(fields[0]).trimmingCharacters(in: .whitespaces)] = String(fields[1]).trimmingCharacters(in: .whitespaces) }
    }
    return result
}

final class LooseBook {
    let url: URL
    let pages: [BookPage]
    let metadata: [String: String]
    let chapters: [BookChapter]
    let title: String
    let notice: String?
    let hasContents: Bool
    let kind: String
    let metadataDirectory: URL
    private let files: [URL]
    private let data: Data
    private let pdf: PDFDocument?
    private let lock = NSLock()
    let storedMetadata: [String: Data]
    static func accepts(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return !["zip", "uvz"].contains(url.pathExtension.lowercased()) ||
            (FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue)
    }
    init(url: URL) throws {
        self.url = url
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { throw ReaderFailure("文件不存在。") }
        kind = directory.boolValue ? "folder" : url.pathExtension.lowercased()
        guard kind == "folder" || supportedBookExtensions.contains(kind) else { throw ReaderFailure("不支持这种文件格式。") }
        metadataDirectory = kind == "folder" ? url : URL(fileURLWithPath: url.path + ".uvzmeta", isDirectory: true)
        var pages: [BookPage] = [], nativeChapters: [BookChapter] = [], info: [String: String] = [:]
        var nativeHasContents = false
        if kind == "folder" || kind == "pdg" {
            files = kind == "folder" ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "pdg" }.sorted { pageKey($0.lastPathComponent) < pageKey($1.lastPathComponent) } : [url]
            guard !files.isEmpty, files.count <= 100_000 else { throw ReaderFailure("该文件夹没有 PDG 页面，或页数过多。") }
            data = Data(); pdf = nil
            for (entry, file) in files.enumerated() {
                let key = pageKey(file.lastPathComponent)
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let head = try handle.read(upToCount: 140) ?? Data()
                if head.starts(with: Data("%PDF-".utf8)) || (head.count > 3 && head[0] == 0x48 && head[1] == 0x48 && head[3] == 0x46) {
                    let decoded = try PageDecoder.decodedData(Data(contentsOf: file, options: .mappedIfSafe))
                    guard let document = PDFDocument(data: decoded), !document.isLocked, document.pageCount > 0,
                          document.pageCount <= 100_000 - pages.count else { throw ReaderFailure("文本 PDG 的 PDF 无法读取。") }
                    for i in 0..<document.pageCount { pages.append(BookPage(entry: entry, name: file.lastPathComponent, key: key, pdfPage: i)) }
                } else { pages.append(BookPage(entry: entry, name: file.lastPathComponent, key: key)) }
            }
        } else {
            files = []; data = try Data(contentsOf: url, options: .mappedIfSafe)
            let count: Int
            if kind == "pdf" {
                guard let document = PDFDocument(data: data), !document.isLocked else { throw ReaderFailure("PDF 无法读取或需要密码。") }
                pdf = document; count = document.pageCount
                if let attributes = document.documentAttributes {
                    info["书名"] = attributes[PDFDocumentAttribute.titleAttribute] as? String
                    info["作者"] = attributes[PDFDocumentAttribute.authorAttribute] as? String
                }
                func visit(_ node: PDFOutline, level: Int) {
                    guard level < 64, nativeChapters.count < 100_000 else { return }
                    for i in 0..<node.numberOfChildren {
                        guard let child = node.child(at: i) else { continue }
                        let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                        if let page = destination?.page, let label = child.label, !label.isEmpty {
                            let index = document.index(for: page)
                            if index < count { nativeChapters.append(BookChapter(title: label, pageIndex: index, level: level, path: nil)) }
                        }
                        visit(child, level: level + 1)
                    }
                }
                if let root = document.outlineRoot { nativeHasContents = true; visit(root, level: 0) }
            } else if ["djvu", "djv"].contains(kind) {
                pdf = nil
                let result = try DjVuTools.inspect(url)
                count = result.0; nativeChapters = result.1; nativeHasContents = !nativeChapters.isEmpty
            } else {
                pdf = nil
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(source) as String?, type == "public.tiff" else { throw ReaderFailure("TIFF 无法读取。") }
                count = CGImageSourceGetCount(source)
            }
            guard count > 0, count <= 100_000 else { throw ReaderFailure("文档为空或页数超过限制。") }
            for i in 0..<count {
                pages.append(BookPage(entry: 0, name: url.lastPathComponent, key: PageKey(group: 5, number: i + 1, name: url.lastPathComponent), pdfPage: nil))
            }
        }
        guard pages.count <= 100_000, Set(files.map { $0.lastPathComponent.lowercased() }).count == files.count else { throw ReaderFailure("页面数超限或存在重名 PDG。") }
        self.pages = pages
        var snapshot: [String: Data] = [:]
        for name in ["bookcontents.dat", "bookinfo.dat"] {
            if let file = try Self.find(name, in: metadataDirectory) { snapshot[name] = try Self.smallData(file) }
        }
        storedMetadata = snapshot
        let contents = try Self.find("bookcontents.dat", in: metadataDirectory)
        if let infoURL = try Self.find("bookinfo.dat", in: metadataDirectory) {
            let raw = try Self.smallData(infoURL); info.merge(readBookInfo(raw)) { _, new in new }
        }
        metadata = info; title = info["书名"].flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        if let contents {
            do { let parsed = try BookArchive.parseContents(Self.smallData(contents), pages: pages); chapters = parsed.0; notice = parsed.1 }
            catch { chapters = []; notice = "电子目录未能读取：" + error.localizedDescription }
        } else { chapters = nativeChapters; notice = nil }
        hasContents = contents != nil || nativeHasContents
    }
    static func find(_ name: String, in folder: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.lowercased() == name }
    }
    static func smallData(_ url: URL) throws -> Data {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else { throw ReaderFailure("DAT 文件超过 2 MB。") }
        return try Data(contentsOf: url)
    }
    func pageData(at index: Int) throws -> Data {
        if files.isEmpty { return data }
        let file = files[pages[index].entry]
        guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 128 * 1024 * 1024 else { throw ReaderFailure("PDG 页面超过 128 MB。") }
        return try PageDecoder.decodedData(Data(contentsOf: file, options: .mappedIfSafe))
    }
    func pageImage(at index: Int) throws -> CGImage {
        if let pdf { lock.lock(); defer { lock.unlock() }; return try PageDecoder.image(pdf, at: index) }
        if ["djvu", "djv"].contains(kind) { return try DjVuTools.render(url, page: index + 1) }
        return try PageDecoder.image(pageData(at: index), pdfPage: files.isEmpty ? index : pages[index].pdfPage)
    }
}

/// DjVuLibre runs as a bundled command-line program, isolated from the reader process.
enum DjVuTools {
    static func run(_ tool: String, _ args: [String], limit: TimeInterval = 35) throws -> Data {
        let process = Process()
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + tool)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ReaderFailure("缺少 DjVu 解码组件，请使用完整应用包。") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let out = temp.appendingPathComponent("output"), err = temp.appendingPathComponent("error")
        FileManager.default.createFile(atPath: out.path, contents: nil); FileManager.default.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out), errors = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? errors.close() }
        process.executableURL = executable; process.arguments = args; process.standardOutput = output; process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(limit)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning { process.terminate(); throw ReaderFailure("DjVu 解码超时。") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReaderFailure("DjVu 无法读取：" + String((String(data: try Data(contentsOf: err), encoding: .utf8) ?? "文件损坏").prefix(500))) }
        return try Data(contentsOf: out)
    }
    static func inspect(_ url: URL) throws -> (Int, [BookChapter]) {
        let raw = try run("djvused", ["-u", "-e", "n; print-outline", url.path])
        let text = String(data: raw, encoding: .utf8) ?? ""
        guard let first = text.split(separator: "\n").first, let count = Int(first.trimmingCharacters(in: .whitespaces)), count > 0, count <= 100_000 else { throw ReaderFailure("DjVu 页数无法读取。") }
        return (count, parseOutline(String(text.drop(while: { $0 != "\n" })), count: count))
    }
    static func parseOutline(_ text: String, count: Int) -> [BookChapter] {
        // djvused emits (bookmarks ("title" "#1" ("child" "#2"))). Only local destinations are accepted.
        var result: [BookChapter] = [], depth = 0, strings: [Int: [String]] = [:]
        let chars = Array(text); var i = 0
        while i < chars.count && result.count < 100_000 {
            let c = chars[i]; i += 1
            if c == "(" { depth += 1; strings[depth] = [] }
            else if c == ")" { strings[depth] = nil; depth = max(0, depth - 1) }
            else if c == "\"" {
                var value = ""
                while i < chars.count {
                    let x = chars[i]; i += 1
                    if x == "\"" { break }
                    if x == "\\", i < chars.count {
                        let escaped = chars[i]; i += 1
                        if escaped == "n" { value.append("\n") } else if escaped == "t" { value.append("\t") }
                        else if ("0"..."7").contains(String(escaped)) {
                            var octal = String(escaped)
                            for _ in 0..<2 where i < chars.count && ("0"..."7").contains(String(chars[i])) { octal.append(chars[i]); i += 1 }
                            if let number = UInt32(octal, radix: 8), let scalar = UnicodeScalar(number) { value.unicodeScalars.append(scalar) }
                        } else { value.append(escaped) }
                    } else { value.append(x) }
                }
                strings[depth, default: []].append(value)
                if let values = strings[depth], values.count == 2, values[1].hasPrefix("#"), let page = Int(values[1].dropFirst()), (1...count).contains(page) {
                    result.append(BookChapter(title: values[0], pageIndex: page - 1, level: min(63, max(0, depth - 2)), path: nil))
                }
            }
        }
        return result
    }
    static func render(_ url: URL, page: Int) throws -> CGImage {
        let data = try run("ddjvu", ["-format=ppm", "-page=\(page)", "-size=4000x4000", url.path])
        var at = 0
        func token() -> String? {
            while at < data.count {
                if data[at] == 35 { while at < data.count && data[at] != 10 { at += 1 } }
                else if data[at] <= 32 { at += 1 } else { break }
            }
            let start = at; while at < data.count && data[at] > 32 { at += 1 }
            return String(data: data.subdata(in: start..<at), encoding: .ascii)
        }
        guard token() == "P6", let w = token().flatMap(Int.init), let h = token().flatMap(Int.init), token() == "255",
              w > 0, h > 0, w <= 4000, h <= 4000, at < data.count else { throw ReaderFailure("DjVu 图像输出异常。") }
        if data[at] == 13 && at + 1 < data.count && data[at + 1] == 10 { at += 2 } else { at += 1 }
        guard data.count - at == w * h * 3, let provider = CGDataProvider(data: data.subdata(in: at..<data.count) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ReaderFailure("DjVu 图像数据不完整。") }
        return image
    }
}
