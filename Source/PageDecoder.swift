import AppKit
import ImageIO
import PDFKit

@_silgen_name("lab_pdg_decode")
private func decodeNativePDG(_ input: UnsafePointer<UInt8>, _ size: Int, _ output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ length: UnsafeMutablePointer<Int>, _ error: UnsafeMutablePointer<CChar>, _ capacity: Int) -> Int32
@_silgen_name("lab_pdg_free") private func freeNativePDG(_ bytes: UnsafeMutableRawPointer)
@_silgen_name("lab_inflate_zlib")
private func decodeZlib(_ input: UnsafePointer<UInt8>, _ size: Int, _ output: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int

enum PageDecoder {
    static func decodedData(_ data: Data) throws -> Data {
        guard data.starts(with: [0x48, 0x48]) else { return data }
        guard data.count >= 140 else { throw ReaderFailure("PDG 头部被截断。") }
        if data[3] == 0x46 {
            guard data[2] == 2, data[15] == 0, data[56] == 0 else { throw ReaderFailure("暂不支持这种文本 PDG 编码。") }
            func integer(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) } }
            let offset = integer(24), length = integer(28)
            guard offset >= 140, offset <= data.count, length > 0, length <= data.count - offset else { throw ReaderFailure("文本 PDG 数据范围异常。") }
            let packed = data.subdata(in: offset..<offset + length)
            let decoded: Data
            if packed.starts(with: Data("%PDF-".utf8)) { decoded = packed }
            else {
                var found: Data?
                for capacity in [1, 2, 4, 8, 16, 32, 64, 128].map({ $0 * 1024 * 1024 }) {
                    var output = Data(count: capacity)
                    let count = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                        packed.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                            decodeZlib(src.baseAddress!.assumingMemoryBound(to: UInt8.self), packed.count, dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity)
                        }
                    }
                    if count >= 0 { output.count = count; found = output; break }
                }
                guard let found else { throw ReaderFailure("文本 PDG 解压失败或超过 128 MB。") }
                decoded = found
            }
            guard let start = decoded.range(of: Data("%PDF-".utf8))?.lowerBound else { throw ReaderFailure("文本 PDG 中没有有效 PDF。") }
            return decoded.subdata(in: start..<decoded.count)
        }
        var output: UnsafeMutablePointer<UInt8>?, length = 0
        var message = [CChar](repeating: 0, count: 512)
        let result = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            decodeNativePDG(src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, &output, &length, &message, message.count)
        }
        guard result == 0, let output else { throw ReaderFailure(String(cString: message)) }
        defer { freeNativePDG(UnsafeMutableRawPointer(output)) }
        return Data(bytes: output, count: length)
    }

    static func image(_ data: Data, pdfPage: Int? = nil) throws -> CGImage {
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let document = PDFDocument(data: data) else { throw ReaderFailure("PDF 无法读取。") }
            return try image(document, at: pdfPage ?? 0)
        }
        let frame = pdfPage ?? 0
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), frame >= 0, frame < CGImageSourceGetCount(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 60_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, frame, nil) else { throw ReaderFailure("页面图像无法读取或尺寸超出限制。") }
        return image
    }

    static func image(_ document: PDFDocument, at index: Int) throws -> CGImage {
        guard !document.isLocked, let page = document.page(at: index) else { throw ReaderFailure("PDF 页面不存在或无法读取。") }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, bounds.width < 30_000, bounds.height < 30_000 else { throw ReaderFailure("PDF 页面尺寸异常。") }
        let scale = min(2.0, 4000 / max(bounds.width, bounds.height))
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReaderFailure("PDF 页面渲染失败。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw ReaderFailure("PDF 页面渲染失败。") }
        return image
    }
}
