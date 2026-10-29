import AppKit
import ImageIO
import PDFKit

@_silgen_name("lab_pdg_decode")
private func decodeNativePDG(_ input: UnsafePointer<UInt8>, _ size: Int, _ output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ length: UnsafeMutablePointer<Int>, _ error: UnsafeMutablePointer<CChar>, _ capacity: Int) -> Int32
@_silgen_name("lab_pdg_free") private func freeNativePDG(_ bytes: UnsafeMutableRawPointer)
@_silgen_name("lab_inflate_zlib")
private func decodeZlib(_ input: UnsafePointer<UInt8>, _ size: Int, _ output: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int

enum PageDecoder {
    // ImageIO can repair an incomplete JPEG and still report a complete frame.
    // Walk marker boundaries so an EXIF thumbnail's EOI cannot mask a cut main scan.
    private static func completeJPEG(_ data:Data)->Bool {
        var at=2,entropy=false,scanned=false
        while at<data.count {
            if entropy,data[at] != 0xff {at+=1;continue}
            guard data[at]==0xff else {return false}
            while at<data.count,data[at]==0xff {at+=1}
            guard at<data.count else {return false}
            let marker=data[at];at+=1
            if marker==0 {if entropy {continue};return false}
            if (0xd0...0xd7).contains(marker) {if entropy {continue};return false}
            if marker==0xd9 {return scanned}
            if marker==1 {continue}
            guard marker != 0xd8,at+2<=data.count else {return false}
            let length=Int(data[at])*256+Int(data[at+1])
            guard length>=2,length<=data.count-at else {return false}
            at+=length
            if marker==0xda {entropy=true;scanned=true}
            else if marker != 0xdc {entropy=false}
        }
        return false
    }
    static func decodedData(_ data: Data) throws -> Data {
        guard data.starts(with: [0x48, 0x48]) else { return data }
        guard data.count >= 3 else { throw ReaderFailure("PDG 头部被截断。") }
        if data[2] != 1 {
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
        }
        var output: UnsafeMutablePointer<UInt8>?, length = 0
        var message = [CChar](repeating: 0, count: 512)
        let result = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            decodeNativePDG(src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, &output, &length, &message, message.count)
        }
        guard result == 0, let output else { throw ReaderFailure(String(cString: message)) }
        defer { freeNativePDG(UnsafeMutableRawPointer(output)) }
        let decoded=Data(bytes:output,count:length)
        // A standard DjVu renamed .pdg is not a SuperStar container. Only the
        // V2 container establishes provenance; bilevel and compound layers stay standard.
        if data[2]==2,let properties=DjVuPageProperties.singlePage(decoded),properties.isPhoto {
            let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("uvz-photo-"+UUID().uuidString+".djvu")
            defer {try? FileManager.default.removeItem(at:temporary)}
            try decoded.write(to:temporary)
            let image=try DjVuTools.render(temporary,page:1,superstarPhoto:properties)
            let png=NSMutableData()
            guard let destination=CGImageDestinationCreateWithData(png,"public.png" as CFString,1,nil) else {throw ReaderFailure("照片页图像编码失败。")}
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyDPIWidth:Double(properties.dpi),kCGImagePropertyDPIHeight:Double(properties.dpi)] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {throw ReaderFailure("照片页图像编码失败。")}
            return png as Data
        }
        return decoded
    }

    static func image(_ data: Data, pdfPage: Int? = nil, applyOrientation:Bool = true) throws -> CGImage {
        if data.starts(with:Data("AT&TFORM".utf8)) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("uvz-page-"+UUID().uuidString+".djvu")
            defer { try? FileManager.default.removeItem(at:url) }
            try data.write(to:url)
            return try DjVuTools.render(url,page:(pdfPage ?? 0)+1,fullResolution:true)
        }
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let document = PDFDocument(data: data) else { throw ReaderFailure("PDF 无法读取。") }
            return try image(document, at: pdfPage ?? 0)
        }
        let frame = pdfPage ?? 0
        if data.starts(with:[0xff,0xd8]), !completeJPEG(data) {throw ReaderFailure("JPEG 页面数据被截断或标记不完整。")}
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), frame >= 0, frame < CGImageSourceGetCount(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 60_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, frame, [kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw ReaderFailure("页面图像无法读取或尺寸超出限制。") }
        guard CGImageSourceGetStatusAtIndex(source,frame) == .statusComplete else {throw ReaderFailure("页面图像不完整或解码失败。")}
        let orientation=properties[kCGImagePropertyOrientation] as? Int ?? 1
        if applyOrientation,(2...8).contains(orientation) {
            guard let transformed=CGImageSourceCreateThumbnailAtIndex(source,frame,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(width,height)] as CFDictionary) else {throw ReaderFailure("页面方向标记无法应用。")}
            return transformed
        }
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
