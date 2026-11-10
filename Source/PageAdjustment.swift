import AppKit
import Darwin
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct PageAdjustment: Codable {
    var rotation = 0
    var left = 0.0
    var right = 0.0
    var top = 0.0
    var bottom = 0.0
    var automaticContrast = false
    var brightness = 0.0
    var contrast = 1.0
    var gamma = 1.0

    var crops: Bool { left != 0 || right != 0 || top != 0 || bottom != 0 }
    var tone: PageDisplayOptions {
        PageDisplayOptions(automatic: automaticContrast, brightness: brightness, contrast: contrast, gamma: gamma)
    }
    var active: Bool { rotation != 0 || crops || tone.active }

    func validate() throws {
        guard (0...3).contains(rotation),
              [left, right, top, bottom].allSatisfy({ (0...0.49).contains($0) }),
              (-0.5...0.5).contains(brightness), (0.25...3).contains(contrast), (0.25...4).contains(gamma) else {
            throw ReaderFailure("调整参数无效。裁边百分比须在 0 至 49 之间。")
        }
    }

    func image(_ original: CGImage) throws -> CGImage {
        let width = original.width, height = original.height
        let x = Int(Double(width) * left), y = Int(Double(height) * top)
        let crop = CGRect(x: x, y: y, width: width - x - Int(Double(width) * right),
                          height: height - y - Int(Double(height) * bottom))
        guard let cropped = crops ? original.cropping(to: crop) : original else { throw ReaderFailure("页面裁剪失败。") }
        let adjusted = try PageDisplayFilters.render(cropped, options: tone)
        return try PageImageFactory.prepare(adjusted, rotation: rotation, crop: 0, invert: false)
    }

    static func pages(_ text: String, count: Int) throws -> IndexSet {
        let parts = text.replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .components(separatedBy: ",")
        var result = IndexSet()
        for part in parts {
            let ends = part.components(separatedBy: "-").map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard (1...2).contains(ends.count), let first = ends.first ?? nil, let last = ends.last ?? nil,
                  first > 0, first <= last, last <= count else {
                throw ReaderFailure("页码范围无效。可输入 1,3-7，页码须在 1 至 \(count) 之间。")
            }
            result.insert(integersIn: (first - 1)..<last)
        }
        return result
    }
}

enum PageAdjustmentWriter {
    private static let formats: Set<String> = ["uvz", "zip", "pdf", "djvu", "djv"]

    static func supports(_ book: BookArchive) -> Bool {
        let ext = book.url.pathExtension.lowercased()
        return !book.isPDZ && formats.contains(ext) && (!["uvz", "zip"].contains(ext) || book.isZip)
    }

    static func save(from source: URL, to target: URL, pages: IndexSet, edit: PageAdjustment,
                     expectedFingerprint: String? = nil, cancelled: () -> Bool = { false },
                     progress: (Int) -> Void = { _ in }) throws {
        try edit.validate()
        guard edit.active, !pages.isEmpty else { throw ReaderFailure("请选择页面，并至少调整一项。") }
        let fm = FileManager.default
        let ext = source.pathExtension.lowercased()
        guard formats.contains(ext), target.pathExtension.lowercased() == ext else { throw ReaderFailure("副本须保留原书格式。") }
        let companion = target.path + ".uvzmeta"
        guard !fm.fileExists(atPath: target.path), !fm.fileExists(atPath: companion) else {
            throw ReaderFailure("文件名或同名信息目录已存在，请选择新的名称。")
        }
        let fingerprint = try BatchNaming.fingerprint(source, cancelled: cancelled)
        guard expectedFingerprint == nil || expectedFingerprint == fingerprint else {
            throw ReaderFailure("图书或信息文件已变化，请重新打开再调整。")
        }
        let book = try BookArchive(url: source)
        guard supports(book), let last = pages.last, last < book.pages.count else { throw ReaderFailure("图书格式或选页范围有误。") }

        let scratch = target.deletingLastPathComponent().appendingPathComponent(".uvz-adjust-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        var stage = scratch.appendingPathComponent("result." + ext)
        func checkpoint() throws { if cancelled() { throw ReaderFailure("已取消页面调整。") } }

        switch ext {
        case "uvz", "zip":
            let groups = Dictionary(grouping: pages, by: { book.pages[$0].entry })
            var replacements: [Int:URL] = [:]
            var done = 0
            for (entry, indices) in groups.sorted(by: { $0.value[0] < $1.value[0] }) {
                try checkpoint()
                try autoreleasepool {
                    let output = scratch.appendingPathComponent("entry-\(entry).pdg")
                    if book.pages[indices[0]].pdfPage != nil {
                        guard let pdf = PDFDocument(data: try book.pageData(at: indices[0])) else { throw ReaderFailure("无法打开待调整的文本 PDG。") }
                        let selected = IndexSet(indices.compactMap { book.pages[$0].pdfPage })
                        try writePDF(pdf, selected: selected, edit: edit, to: output, checkpoint: checkpoint) { progress(done + $0) }
                    } else {
                        let original = try book.pageData(at: indices[0])
                        let image = try edit.image(PageDecoder.image(original))
                        var properties: [CFString:Any] = [:]
                        if let source = CGImageSourceCreateWithData(original as CFData, nil),
                           let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any] {
                            let orientation = info[kCGImagePropertyOrientation] as? Int ?? 1
                            let swapped = (5...8).contains(orientation) != (edit.rotation % 2 == 1)
                            properties[kCGImagePropertyDPIWidth] = info[swapped ? kCGImagePropertyDPIHeight : kCGImagePropertyDPIWidth]
                            properties[kCGImagePropertyDPIHeight] = info[swapped ? kCGImagePropertyDPIWidth : kCGImagePropertyDPIHeight]
                        }
                        guard let encoder = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                            throw ReaderFailure("无法创建调整后的图像。")
                        }
                        CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
                        guard CGImageDestinationFinalize(encoder) else { throw ReaderFailure("无法写入调整后的图像。") }
                    }
                    replacements[entry] = output
                }
                done += indices.count
                progress(done)
            }
            try checkpoint()
            try book.writeAdjustedArchive(replacements, to: stage, checkpoint: checkpoint)
        case "pdf":
            guard let pdf = PDFDocument(url: source), !pdf.isEncrypted else {
                throw ReaderFailure("加密 PDF 请先在原阅读器中另存可编辑副本。")
            }
            try writePDF(pdf, selected: pages, edit: edit, to: stage, checkpoint: checkpoint, progress: progress)
        default:
            try writeDjVu(book, selected: pages, edit: edit, to: stage, scratch: scratch, checkpoint: checkpoint, progress: progress)
        }

        try checkpoint()
        var checked = try BookArchive(url: stage)
        func equalContents(_ first: [BookChapter], _ second: [BookChapter]) -> Bool {
            first.count == second.count && zip(first, second).allSatisfy {
                $0.title == $1.title && $0.pageIndex == $1.pageIndex && $0.level == $1.level
            }
        }
        if book.storesNativeInformation, checked.metadata != book.metadata || !equalContents(checked.chapters, book.chapters) {
            let repaired = scratch.appendingPathComponent("verified." + ext)
            let outline = equalContents(checked.chapters, book.chapters) ? nil : book.chapters
            try NativeDocumentMetadata.write(book.metadata, from: stage, to: repaired, contents: outline)
            stage = repaired
            checked = try BookArchive(url: stage)
        }
        guard checked.pages.count == book.pages.count, checked.metadata == book.metadata,
              equalContents(checked.chapters, book.chapters),
              zip(checked.pages, book.pages).allSatisfy({ $0.key.group == $1.key.group && $0.number == $1.number }) else {
            throw ReaderFailure("副本的页数、页序、目录或图书信息核验未通过。")
        }
        guard try BatchNaming.fingerprint(source, cancelled: cancelled) == fingerprint else {
            throw ReaderFailure("图书在保存期间发生变化。")
        }
        try checkpoint()
        guard !fm.fileExists(atPath: companion), Darwin.renamex_np(stage.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ReaderFailure("无法提交副本，请检查路径和重名。")
        }
    }

    private static func writePDF(_ pdf: PDFDocument, selected: IndexSet, edit: PageAdjustment, to target: URL,
                                 checkpoint: () throws -> Void, progress: (Int) -> Void) throws {
        guard !pdf.isLocked, !pdf.isEncrypted else { throw ReaderFailure("PDF 无法编辑或需要密码。") }
        // Record destinations before replacing pages. Geometry-only edits retain the original page objects.
        var links: [(Int, (PDFDestination) -> Void)] = []
        func record(_ destination: PDFDestination?, assign: @escaping (PDFDestination) -> Void) {
            if let page = destination?.page {
                let index = pdf.index(for: page)
                if index != NSNotFound, selected.contains(index) { links.append((index, assign)) }
            }
        }
        if edit.tone.active {
            func visit(_ node: PDFOutline, depth: Int) {
                guard depth < 64 else { return }
                record(node.destination ?? (node.action as? PDFActionGoTo)?.destination) { node.destination = $0 }
                for index in 0..<node.numberOfChildren {
                    if let child = node.child(at: index) { visit(child, depth: depth + 1) }
                }
            }
            if let root = pdf.outlineRoot { visit(root, depth: 0) }
            for index in 0..<pdf.pageCount where !selected.contains(index) {
                for annotation in pdf.page(at: index)?.annotations ?? [] {
                    record(annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination) { annotation.destination = $0 }
                }
            }
        }
        for (done, index) in selected.enumerated() {
            try checkpoint()
            try autoreleasepool {
                guard let page = pdf.page(at: index) else { throw ReaderFailure("PDF 第 \(index + 1) 页无法读取。") }
                let size = page.orientedCropSize
                let visible = CGRect(x: size.width * edit.left, y: size.height * edit.bottom,
                                     width: size.width * (1 - edit.left - edit.right),
                                     height: size.height * (1 - edit.top - edit.bottom))
                if edit.tone.active {
                    let image = try edit.image(PageDecoder.image(pdf, at: index))
                    let dimensions = edit.rotation % 2 == 0 ? visible.size : CGSize(width: visible.height, height: visible.width)
                    let box = CGRect(origin: .zero, size: dimensions)
                    guard let replacement = PDFPage(image: NSImage(cgImage: image, size: dimensions),
                                                    options: [.mediaBox: NSValue(rect: box), .upscaleIfSmaller: true, .compressionQuality: 1]) else {
                        throw ReaderFailure("无法写入 PDF 第 \(index + 1) 页。")
                    }
                    pdf.removePage(at: index)
                    pdf.insert(replacement, at: index)
                } else {
                    if edit.crops {
                        let transform = page.transform(for: .cropBox)
                        page.setBounds(visible.applying(transform.inverted()), for: .cropBox)
                    }
                    page.rotation = (page.rotation + edit.rotation * 90) % 360
                }
            }
            progress(done + 1)
        }
        for (index, assign) in links {
            if let page = pdf.page(at: index) {
                assign(PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).height)))
            }
        }
        try checkpoint()
        guard pdf.write(to: target), let check = PDFDocument(url: target), check.pageCount == pdf.pageCount else {
            throw ReaderFailure("PDF 副本无法回读。")
        }
    }

    private static func writeDjVu(_ book: BookArchive, selected: IndexSet, edit: PageAdjustment,
                                  to target: URL, scratch: URL, checkpoint: () throws -> Void, progress: (Int) -> Void) throws {
        let fm = FileManager.default
        let script = scratch.appendingPathComponent("edit.dsed")
        if !edit.crops && !edit.tone.active {
            let commands = selected.map { "select \($0 + 1); set-rotation -\(edit.rotation)\n" }.joined()
            try (commands + "save-bundled " + NativeDocumentMetadata.quote(target.path) + "\n").write(to: script, atomically: true, encoding: .utf8)
            _ = try DjVuTools.run("djvused", ["-u", "-f", script.path, book.url.path], limit: 120)
            progress(selected.count)
            return
        }
        for (done, index) in selected.enumerated() {
            try checkpoint()
            try autoreleasepool {
                let image = try edit.image(book.exportImage(at: index))
                let ppm = scratch.appendingPathComponent("page.ppm")
                let output = scratch.appendingPathComponent("page-\(index + 1).djvu")
                let dpi = Int(try book.exportDPI(at: index) ?? 300)
                try writePPM(image, to: ppm)
                _ = try DjVuTools.run("c44", ["-slice", "97", "-dpi", String(dpi), ppm.path, output.path], limit: 120)
            }
            progress(done + 1)
        }
        try checkpoint()
        let normalized = scratch.appendingPathComponent("input.djvu")
        try ("save-bundled " + NativeDocumentMetadata.quote(normalized.path) + "\n").write(to: script, atomically: true, encoding: .utf8)
        _ = try DjVuTools.run("djvused", ["-u", "-f", script.path, book.url.path], limit: 120)
        let input = try FileHandle(forReadingFrom: normalized)
        defer { try? input.close() }
        let header = try input.read(upToCount: 16) ?? Data()
        if book.pages.count == 1, header.suffix(4) == Data("DJVU".utf8) {
            try fm.copyItem(at: scratch.appendingPathComponent("page-1.djvu"), to: target)
        } else {
            _ = try DjVuTools.run("lab-djvu-replace", [normalized.path, scratch.path, target.path], limit: 120)
        }
        // A single-page document may carry book metadata in the replaced page itself.
        let metadata = try NativeDocumentMetadata.djvuRaw(book.url)
        if try NativeDocumentMetadata.djvuRaw(target) != metadata {
            let entries = metadata.sorted { $0.key < $1.key }.map { $0.key + "\t" + NativeDocumentMetadata.quote($0.value) }.joined(separator: "\n")
            try ("select; set-meta\n" + entries + "\n.\nsave\n").write(to: script, atomically: true, encoding: .utf8)
            _ = try DjVuTools.run("djvused", ["-u", "-f", script.path, target.path], limit: 120)
            guard try NativeDocumentMetadata.djvuRaw(target) == metadata else { throw ReaderFailure("DjVu 图书信息核验失败。") }
        }
    }

    private static func writePPM(_ image: CGImage, to output: URL) throws {
        let width = image.width, height = image.height
        guard let rgb = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixels = rgb.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ReaderFailure("DjVu 页面无法转为编码所需的颜色格式。")
        }
        rgb.setFillColor(gray: 1, alpha: 1)
        rgb.fill(CGRect(x: 0, y: 0, width: width, height: height))
        rgb.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        try Data("P6\n\(width) \(height)\n255\n".utf8).write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var row = Data(count: width * 3)
        for y in 0..<height {
            row.withUnsafeMutableBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    bytes[x * 3] = pixels[index]
                    bytes[x * 3 + 1] = pixels[index + 1]
                    bytes[x * 3 + 2] = pixels[index + 2]
                }
            }
            try handle.write(contentsOf: row)
        }
    }
}
