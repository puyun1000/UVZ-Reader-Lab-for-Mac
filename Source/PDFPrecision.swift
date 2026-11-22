import CoreGraphics
import Foundation
import PDFKit

/// Sample the actual drawing operations so a page-sized image has a finite
/// source resolution even when annotations or invisible glyphs sit above it.
enum PDFPrecision: String, Codable {
    case vector = "矢量精度"
    case raster = "图像页"
    case mixed = "混合页面 · 待核对"
    case uncertain = "精度待核对"

    struct Result: Codable {
        let kind: PDFPrecision
        let samplePages: [Int]
        let rasterPages: [Int]
        let estimatedImageDPI: Int?

        var detail: String {
            let pages = samplePages.map(String.init).joined(separator: "、")
            let images = rasterPages.map(String.init).joined(separator: "、")
            let resolution = estimatedImageDPI.map { " · 整页图约 \($0) dpi" } ?? ""
            return kind.rawValue + (pages.isEmpty ? "" : " · 核对物理页 " + pages) +
                (images.isEmpty ? "" : " · 图像页 " + images) + resolution
        }
    }

    static func inspect(_ document: PDFDocument, cancelled: () -> Bool = { false }) -> Result {
        let count = document.pageCount
        // Long books have cover/title matter and back matter. Sample the interior
        // across the book rather than use the bibliographic OCR pages.
        let start = count >= 12 ? max(3, count / 12) : 0
        let end = max(start, count - 1 - (count >= 12 ? max(2, count / 12) : 0))
        let indices = Set((0..<9).map { start + (end - start) * $0 / 8 }).sorted()
        var visited: [Int] = [], raster: [Int] = [], resolutions: [Int] = []
        var scalable = 0, unknown = false
        for i in indices {
            if cancelled() { unknown = true; break }
            guard let page = document.page(at: i)?.pageRef else { unknown = true; continue }
            let metrics = Measurements(page.getBoxRect(.cropBox))
            let stream = CGPDFContentStreamCreateWithPage(page)
            metrics.scan(stream)
            CGPDFContentStreamRelease(stream)
            visited.append(i + 1)
            if metrics.imageCoverage >= 0.52 {
                raster.append(i + 1)
                if let dpi = metrics.dpi { resolutions.append(dpi) }
            } else if metrics.complete, metrics.visibleText >= 3 || metrics.paintedPaths >= 18 {
                scalable += 1
            } else if !metrics.complete || metrics.visibleText > 0 || metrics.paintedPaths > 0 || metrics.imageCoverage > 0 {
                unknown = true
            }
        }
        let kind: PDFPrecision
        if !raster.isEmpty && scalable > 0 { kind = .mixed }
        else if !raster.isEmpty { kind = .raster }
        else if !unknown, scalable >= min(3, count), scalable > 0 { kind = .vector }
        else { kind = .uncertain }
        return Result(kind: kind, samplePages: visited, rasterPages: raster, estimatedImageDPI: resolutions.min())
    }

    private final class Measurements {
        struct State {
            var transform = CGAffineTransform.identity
            var textMode = 0
        }
        let page: CGRect
        var graphics = State(), stack: [State] = []
        var visibleText = 0, paintedPaths = 0, imageCoverage: CGFloat = 0
        var dpi: Int?
        var complete = true
        var activeForms = Set<CGPDFStreamRef>()
        var remainingForms = 128

        init(_ page: CGRect) { self.page = page.standardized }

        func scan(_ content: CGPDFContentStreamRef) {
            guard let table = CGPDFOperatorTableCreate() else { complete = false; return }
            defer { CGPDFOperatorTableRelease(table) }
            CGPDFOperatorTableSetCallback(table, "q") { _, info in
                guard let info else { return }
                let m = Unmanaged<Measurements>.fromOpaque(info).takeUnretainedValue()
                if m.stack.count < 256 { m.stack.append(m.graphics) } else { m.complete = false }
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in
                guard let info else { return }
                let m = Unmanaged<Measurements>.fromOpaque(info).takeUnretainedValue()
                if let state = m.stack.popLast() { m.graphics = state } else { m.complete = false }
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                guard let info else { return }
                let m = Unmanaged<Measurements>.fromOpaque(info).takeUnretainedValue()
                var values = [CGPDFReal](repeating: 0, count: 6)
                for index in values.indices.reversed() {
                    guard CGPDFScannerPopNumber(scanner, &values[index]), values[index].isFinite else { m.complete = false; return }
                }
                let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
                m.graphics.transform = matrix.concatenating(m.graphics.transform)
            }
            CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
                guard let info else { return }
                let m = Unmanaged<Measurements>.fromOpaque(info).takeUnretainedValue()
                var mode: CGPDFInteger = 0
                if CGPDFScannerPopInteger(scanner, &mode) { m.graphics.textMode = mode }
            }
            let text: CGPDFOperatorCallback = { _, info in
                guard let info else { return }
                let m = Unmanaged<Measurements>.fromOpaque(info).takeUnretainedValue()
                if m.graphics.textMode != 3 && m.graphics.textMode != 7 { m.visibleText += 1 }
            }
            for op in ["Tj", "TJ", "'", "\""] { CGPDFOperatorTableSetCallback(table, op, text) }
            let paint: CGPDFOperatorCallback = { _, info in
                guard let info else { return }
                Unmanaged<Measurements>.fromOpaque(info).takeUnretainedValue().paintedPaths += 1
            }
            for op in ["S","s","f","F","f*","B","B*","b","b*","sh"] { CGPDFOperatorTableSetCallback(table, op, paint) }
            CGPDFOperatorTableSetCallback(table, "BI") { _, info in
                guard let info else { return }
                Unmanaged<Measurements>.fromOpaque(info).takeUnretainedValue().recordImage(nil)
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                guard let info else { return }
                Unmanaged<Measurements>.fromOpaque(info).takeUnretainedValue().drawObject(scanner)
            }
            let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            if !CGPDFScannerScan(scanner) { complete = false }
        }

        func recordImage(_ dictionary: CGPDFDictionaryRef?) {
            let t = graphics.transform
            let painted = CGRect(x: 0, y: 0, width: 1, height: 1).applying(t).intersection(page)
            guard !painted.isNull, page.width > 0, page.height > 0 else { return }
            let coverage = painted.width * painted.height / (page.width * page.height)
            // Disjoint image strips can encode one full scan.
            imageCoverage = min(1, imageCoverage + coverage)
            guard coverage >= 0.1, let dictionary else { return }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            let width = hypot(t.a, t.b), height = hypot(t.c, t.d)
            if CGPDFDictionaryGetInteger(dictionary, "Width", &w),
               CGPDFDictionaryGetInteger(dictionary, "Height", &h), width > 0, height > 0 {
                let estimate = min(CGFloat(w) * 72 / width, CGFloat(h) * 72 / height)
                if estimate.isFinite, estimate >= 1, estimate < 1_000_000 {
                    dpi = min(dpi ?? Int(estimate), Int(estimate))
                }
            }
        }

        func drawObject(_ scanner: CGPDFScannerRef) {
            var name: UnsafePointer<CChar>?
            let parent = CGPDFScannerGetContentStream(scanner)
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { complete = false; return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { complete = false; return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { complete = false; return }
            switch String(cString: subtype) {
            case "Image": recordImage(dictionary)
            case "Form":
                guard remainingForms > 0, activeForms.count < 12, activeForms.insert(stream).inserted else { complete = false; return }
                remainingForms -= 1
                let saved = graphics, savedStack = stack
                defer { graphics = saved; stack = savedStack; activeForms.remove(stream) }
                var matrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in v.indices {
                        guard CGPDFArrayGetNumber(matrix, i, &v[i]), v[i].isFinite else { complete = false; return }
                    }
                    graphics.transform = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(graphics.transform)
                }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                let child = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
                stack = []
                scan(child)
                CGPDFContentStreamRelease(child)
            default: complete = false
            }
        }
    }
}

enum VectorFilename {
    static let marker = "【印前矢量】"

    static func hasMarker(_ stem: String) -> Bool { stem.hasSuffix(marker) }

    static func render(_ value: String, marked: Bool) -> String {
        var stem = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while hasMarker(stem) {
            stem = String(stem.dropLast(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return marked && !stem.isEmpty ? stem + marker : stem
    }
}
